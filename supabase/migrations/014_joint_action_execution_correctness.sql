-- 014: two correctness bugs in the joint-action execution path.
--
-- (a) finalize_joint_action_if_complete() flipped the action to 'approved' BEFORE
--     running the action, and never rolled that back when the action failed. A
--     both-signature transfer that failed (insufficient funds, frozen account,
--     stale fraud assessment) was left looking approved with no money moved and
--     no retry path.
-- (b) A fraud assessment has a 10-minute TTL, but co-holder consent has a 7-day
--     window, so the assessment captured at request time is ALWAYS stale by the
--     time the last signature lands. The consent call now accepts a freshly
--     minted assessment id and rewrites the payload before executing.
--
-- Both found by running the flow end to end against live data rather than by
-- reading the code: (b) surfaced as "Fraud assessment <NULL> does not exist",
-- and (a) as an action sitting at status='approved' with no transaction.

ALTER TABLE public.joint_account_actions
    ADD COLUMN IF NOT EXISTS last_error TEXT;

CREATE OR REPLACE FUNCTION public.finalize_joint_action_if_complete(p_joint_action_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_action public.joint_account_actions%ROWTYPE;
    v_account public.accounts%ROWTYPE;
    v_total_holders INT;
    v_consents_count INT;
    v_required INT;
    v_result JSONB;
    v_ok BOOLEAN;
BEGIN
    SELECT * INTO v_action FROM public.joint_account_actions WHERE id = p_joint_action_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Joint action % not found', p_joint_action_id;
    END IF;

    IF v_action.status <> 'pending' THEN
        RETURN jsonb_build_object('success', true, 'joint_action_id', p_joint_action_id,
                                  'status', v_action.status);
    END IF;

    SELECT * INTO v_account FROM public.accounts WHERE id = v_action.account_id;

    SELECT COUNT(*) INTO v_total_holders FROM public.account_holders WHERE account_id = v_action.account_id;
    SELECT COUNT(*) INTO v_consents_count
    FROM public.joint_account_consents
    WHERE joint_action_id = p_joint_action_id AND consent = TRUE;

    IF v_action.action_type = 'close_account' AND v_account.closure_authority = 'majority' AND v_total_holders >= 3 THEN
        v_required := FLOOR(v_total_holders / 2.0) + 1;
    ELSE
        v_required := v_total_holders;
    END IF;

    IF v_consents_count < v_required THEN
        RETURN jsonb_build_object(
            'success', true, 'joint_action_id', p_joint_action_id, 'status', 'pending',
            'requires_additional_signatures', true,
            'consents_count', v_consents_count, 'required', v_required
        );
    END IF;

    -- Run the action FIRST; only record approval if it actually succeeded.
    IF v_action.action_type = 'close_account' THEN
        BEGIN
            PERFORM public.close_account(v_action.account_id);
            v_result := jsonb_build_object('success', true, 'executed_action', 'close_account');
        EXCEPTION WHEN OTHERS THEN
            v_result := jsonb_build_object('success', false, 'error', SQLERRM,
                                           'executed_action', 'close_account');
        END;

    ELSIF v_action.action_type = 'transfer_approval' THEN
        v_result := public.execute_transfer(
            v_action.account_id,
            (v_action.payload ->> 'destination_account_id')::UUID,
            (v_action.payload ->> 'amount')::BIGINT,
            v_action.payload ->> 'currency',
            v_action.payload ->> 'idempotency_key',
            v_action.requested_by_profile_id,
            (v_action.payload ->> 'fraud_assessment_id')::UUID
        );

    ELSIF v_action.action_type = 'add_holder' THEN
        BEGIN
            v_result := public.add_account_holder(
                v_action.account_id,
                (v_action.payload ->> 'new_profile_id')::UUID,
                COALESCE(v_action.payload ->> 'role', 'joint'),
                v_action.requested_by_profile_id,
                TRUE
            );
        EXCEPTION WHEN OTHERS THEN
            v_result := jsonb_build_object('success', false, 'error', SQLERRM,
                                           'executed_action', 'add_holder');
        END;
    ELSE
        v_result := jsonb_build_object('success', false,
                                       'error', 'Unknown action type ' || v_action.action_type);
    END IF;

    v_ok := COALESCE((v_result ->> 'success')::boolean, false);

    IF v_ok THEN
        UPDATE public.joint_account_actions
        SET status = 'approved', last_error = NULL, updated_at = NOW()
        WHERE id = p_joint_action_id;
    ELSE
        -- Stay pending so the request can be retried once the cause is fixed.
        UPDATE public.joint_account_actions
        SET last_error = v_result ->> 'error', updated_at = NOW()
        WHERE id = p_joint_action_id;
    END IF;

    PERFORM public.write_audit_log(
        CASE WHEN v_ok THEN 'joint_action_finalized' ELSE 'joint_action_execution_failed' END,
        'system', NULL, 'joint_account_action', p_joint_action_id,
        jsonb_build_object('action_type', v_action.action_type, 'consents_count', v_consents_count,
                           'required', v_required, 'error', v_result ->> 'error')
    );

    RETURN v_result || jsonb_build_object(
        'joint_action_id', p_joint_action_id,
        'status', CASE WHEN v_ok THEN 'approved' ELSE 'pending' END,
        'all_signatures_collected', true
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- Let n8n inspect a ref code before deciding whether it needs a fraud assessment.

CREATE OR REPLACE FUNCTION public.get_joint_action_by_ref(p_ref_code TEXT, p_responder_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_action public.joint_account_actions%ROWTYPE;
    v_account public.accounts%ROWTYPE;
    v_profile_id UUID;
BEGIN
    SELECT * INTO v_action FROM public.joint_account_actions
    WHERE ref_code = UPPER(btrim(COALESCE(p_ref_code, '')));
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error',
            'No request found for reference ' || COALESCE(p_ref_code, '(none)') || '.');
    END IF;

    SELECT id INTO v_profile_id FROM public.profiles WHERE lower(email) = lower(btrim(p_responder_email));
    IF v_profile_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = v_action.account_id AND profile_id = v_profile_id
    ) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'You are not a holder of the account this request belongs to.');
    END IF;

    SELECT * INTO v_account FROM public.accounts WHERE id = v_action.account_id;

    RETURN jsonb_build_object(
        'success', true, 'ref_code', v_action.ref_code, 'action_type', v_action.action_type,
        'status', v_action.status, 'account_id', v_action.account_id,
        'account_number', v_account.account_number, 'currency', v_account.currency,
        'payload', v_action.payload, 'expires_at', v_action.expires_at,
        'responder_profile_id', v_profile_id,
        'needs_fraud_assessment', (v_action.action_type = 'transfer_approval' AND v_action.status = 'pending'),
        'amount', (v_action.payload ->> 'amount')::BIGINT,
        'last_error', v_action.last_error
    );
END;
$$;

-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.respond_to_joint_action_by_ref(TEXT, TEXT, BOOLEAN);

CREATE OR REPLACE FUNCTION public.respond_to_joint_action_by_ref(
    p_ref_code TEXT, p_responder_email TEXT, p_accept BOOLEAN,
    p_fraud_assessment_id UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_action public.joint_account_actions%ROWTYPE;
    v_profile_id UUID;
    v_account public.accounts%ROWTYPE;
    v_result JSONB;
    v_pending_emails TEXT[];
BEGIN
    SELECT * INTO v_action FROM public.joint_account_actions
    WHERE ref_code = UPPER(btrim(COALESCE(p_ref_code, ''))) FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error',
            'No pending request found for reference ' || COALESCE(p_ref_code, '(none)') || '.');
    END IF;

    SELECT id INTO v_profile_id FROM public.profiles WHERE lower(email) = lower(btrim(p_responder_email));
    IF v_profile_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
            'We do not recognise your email address as a registered customer.');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = v_action.account_id AND profile_id = v_profile_id
    ) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'You are not a holder of the account this request belongs to.');
    END IF;

    IF v_action.status <> 'pending' THEN
        RETURN jsonb_build_object('success', false, 'already_decided', true,
            'error', 'Request ' || v_action.ref_code || ' was already ' || v_action.status || '.',
            'ref_code', v_action.ref_code, 'status', v_action.status);
    END IF;

    IF v_action.expires_at <= NOW() THEN
        UPDATE public.joint_account_actions SET status = 'expired', updated_at = NOW()
        WHERE id = v_action.id;
        RETURN jsonb_build_object('success', false, 'error',
            'Request ' || v_action.ref_code || ' expired on ' ||
            to_char(v_action.expires_at, 'YYYY-MM-DD') || '.', 'status', 'expired');
    END IF;

    -- Refresh the fraud assessment: the one captured when the transfer was first
    -- requested has a 10-minute TTL and is always stale by the time the last
    -- signature arrives.
    IF p_accept AND v_action.action_type = 'transfer_approval' AND p_fraud_assessment_id IS NOT NULL THEN
        UPDATE public.joint_account_actions
        SET payload = payload || jsonb_build_object('fraud_assessment_id', p_fraud_assessment_id),
            updated_at = NOW()
        WHERE id = v_action.id
        RETURNING * INTO v_action;
    END IF;

    v_result := public.record_joint_consent(v_action.id, v_profile_id, p_accept);

    SELECT * INTO v_account FROM public.accounts WHERE id = v_action.account_id;

    SELECT array_agg(p.email) INTO v_pending_emails
    FROM public.account_holders ah
    JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = v_action.account_id
      AND NOT EXISTS (
          SELECT 1 FROM public.joint_account_consents c
          WHERE c.joint_action_id = v_action.id AND c.profile_id = ah.profile_id AND c.consent
      );

    RETURN v_result || jsonb_build_object(
        'ref_code', v_action.ref_code, 'action_type', v_action.action_type,
        'account_id', v_action.account_id, 'account_number', v_account.account_number,
        'payload', v_action.payload,
        'responder_email', lower(btrim(p_responder_email)),
        'requester_email', (SELECT email FROM public.profiles WHERE id = v_action.requested_by_profile_id),
        'pending_holder_emails', to_jsonb(COALESCE(v_pending_emails, ARRAY[]::TEXT[]))
    );
END;
$$;

ALTER FUNCTION public.finalize_joint_action_if_complete(uuid) OWNER TO banking_functions;
ALTER FUNCTION public.get_joint_action_by_ref(TEXT, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.respond_to_joint_action_by_ref(TEXT, TEXT, BOOLEAN, UUID) OWNER TO banking_functions;
REVOKE ALL ON FUNCTION public.get_joint_action_by_ref(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.respond_to_joint_action_by_ref(TEXT, TEXT, BOOLEAN, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_joint_action_by_ref(TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.respond_to_joint_action_by_ref(TEXT, TEXT, BOOLEAN, UUID) TO service_role;
