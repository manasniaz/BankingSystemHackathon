-- 012: initiate_transfer becomes the single enforced entry point for customer
-- transfers. Before this, execute_transfer() performed NO holder check at all and
-- is_holder_transfer_authorized() was dead code called by nothing, so the minor
-- restriction and the either-or / all-signatures mandate were both unenforced in
-- the database -- the only thing stopping a minor from moving money was a check
-- in an n8n Code node. Authorization now lives next to the money movement.
--
-- NOTE: request_transfer_approval() is redefined again in 017 to also return the
-- short JNT ref code. This file is kept as applied.

CREATE OR REPLACE FUNCTION public.initiate_transfer(
    p_source_account_id uuid, p_destination_account_id uuid, p_amount bigint,
    p_currency text, p_idempotency_key text, p_initiated_by_profile_id uuid,
    p_fraud_assessment_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_source public.accounts%ROWTYPE;
    v_dest public.accounts%ROWTYPE;
    v_total_holders INT;
    v_holder public.account_holders%ROWTYPE;
BEGIN
    IF p_initiated_by_profile_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
            'A transfer must name the profile initiating it.');
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Transfer amount must be positive.');
    END IF;

    IF p_source_account_id = p_destination_account_id THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Source and destination accounts must be different.');
    END IF;

    SELECT * INTO v_source FROM public.accounts WHERE id = p_source_account_id;
    IF v_source.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Source account not found');
    END IF;

    SELECT * INTO v_dest FROM public.accounts WHERE id = p_destination_account_id;
    IF v_dest.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Destination account not found');
    END IF;

    IF v_dest.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error',
            'The destination account is ' || v_dest.status || ' and cannot receive funds.');
    END IF;

    IF v_source.currency <> v_dest.currency THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Cross-currency transfers are not supported (' || v_source.currency ||
            ' to ' || v_dest.currency || ').');
    END IF;

    IF p_currency IS NOT NULL AND p_currency <> v_source.currency THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Requested currency ' || p_currency || ' does not match the source account currency ' ||
            v_source.currency || '.');
    END IF;

    -- The initiator must actually hold the source account.
    SELECT * INTO v_holder FROM public.account_holders
    WHERE account_id = p_source_account_id AND profile_id = p_initiated_by_profile_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error',
            'You are not a holder of the source account.');
    END IF;

    -- A minor holder may view the account but never move money out of it.
    IF NOT public.is_holder_transfer_authorized(p_source_account_id, p_initiated_by_profile_id) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'This account is held by a minor. Only the registered guardian can move money out of it.',
            'requires_guardian', true);
    END IF;

    SELECT COUNT(*) INTO v_total_holders
    FROM public.account_holders WHERE account_id = p_source_account_id;

    -- 'all_signatures' mandate: park the transfer until every holder consents.
    IF v_source.authority_model = 'all_signatures' AND v_total_holders > 1 THEN
        RETURN public.request_transfer_approval(
            p_source_account_id, p_destination_account_id, p_amount, v_source.currency,
            p_idempotency_key, p_fraud_assessment_id, p_initiated_by_profile_id
        );
    END IF;

    RETURN public.execute_transfer(
        p_source_account_id, p_destination_account_id, p_amount, v_source.currency,
        p_idempotency_key, p_initiated_by_profile_id, p_fraud_assessment_id
    );
END;
$$;

ALTER FUNCTION public.initiate_transfer(uuid, uuid, bigint, text, text, uuid, uuid) OWNER TO banking_functions;
REVOKE ALL ON FUNCTION public.initiate_transfer(uuid, uuid, bigint, text, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.initiate_transfer(uuid, uuid, bigint, text, text, uuid, uuid) TO service_role;

-- request_transfer_approval must report the pending state in a shape n8n can act on,
-- and must not silently succeed when co-holders still have to sign.
CREATE OR REPLACE FUNCTION public.request_transfer_approval(
    p_source_account_id uuid, p_destination_account_id uuid, p_amount bigint,
    p_currency text, p_idempotency_key text, p_fraud_assessment_id uuid,
    p_initiated_by_profile_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_action_id UUID;
    v_result JSONB;
    v_pending_emails TEXT[];
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = p_source_account_id AND profile_id = p_initiated_by_profile_id
    ) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'You are not a holder of the source account.');
    END IF;

    INSERT INTO public.joint_account_actions (account_id, action_type, status, requested_by_profile_id, payload)
    VALUES (
        p_source_account_id, 'transfer_approval', 'pending', p_initiated_by_profile_id,
        jsonb_build_object(
            'destination_account_id', p_destination_account_id,
            'amount', p_amount, 'currency', p_currency,
            'idempotency_key', p_idempotency_key,
            'fraud_assessment_id', p_fraud_assessment_id
        )
    ) RETURNING id INTO v_action_id;

    INSERT INTO public.joint_account_consents (joint_action_id, profile_id, consent)
    VALUES (v_action_id, p_initiated_by_profile_id, TRUE);

    PERFORM public.write_audit_log(
        'transfer_approval_requested', 'customer', p_initiated_by_profile_id,
        'joint_account_action', v_action_id,
        jsonb_build_object('account_id', p_source_account_id, 'amount', p_amount,
                           'destination_account_id', p_destination_account_id)
    );

    v_result := public.finalize_joint_action_if_complete(v_action_id);

    SELECT array_agg(p.email) INTO v_pending_emails
    FROM public.account_holders ah
    JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = p_source_account_id
      AND ah.profile_id <> p_initiated_by_profile_id
      AND NOT EXISTS (
          SELECT 1 FROM public.joint_account_consents c
          WHERE c.joint_action_id = v_action_id AND c.profile_id = ah.profile_id AND c.consent
      );

    IF COALESCE((v_result ->> 'requires_additional_signatures')::boolean, false) THEN
        RETURN v_result || jsonb_build_object(
            'success', true, 'executed', false, 'awaiting_signatures', true,
            'joint_action_id', v_action_id,
            'pending_holder_emails', to_jsonb(COALESCE(v_pending_emails, ARRAY[]::TEXT[])),
            'expires_at', (SELECT expires_at FROM public.joint_account_actions WHERE id = v_action_id)
        );
    END IF;

    RETURN v_result || jsonb_build_object('executed', true, 'joint_action_id', v_action_id);
END;
$$;

ALTER FUNCTION public.request_transfer_approval(uuid, uuid, bigint, text, text, uuid, uuid) OWNER TO banking_functions;
REVOKE ALL ON FUNCTION public.request_transfer_approval(uuid, uuid, bigint, text, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_transfer_approval(uuid, uuid, bigint, text, text, uuid, uuid) TO service_role;
