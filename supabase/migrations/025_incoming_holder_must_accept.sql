-- 025: the person being ADDED to an account must accept, not just the existing
-- holders. The brief calls out "adding a new holder to an account with existing
-- debt/holds" as an edge case needing a decision, and the decision is: joint
-- liability is not something anyone can be signed up to by other people.
--
-- There is a chicken-and-egg problem that made this non-obvious: consent is
-- recorded in joint_account_consents, and record_joint_consent() verifies the
-- consenter is already a holder of the account -- which the incoming person by
-- definition is not. So their acceptance is tracked on the action payload
-- instead, and finalize refuses to execute add_holder without it.
--
-- Found by testing the add-holder flow end to end against an account carrying a
-- Rs 315,000 loan and asking who, exactly, had agreed to take that on.

CREATE OR REPLACE FUNCTION public.accept_holder_addition(
    p_ref_code TEXT, p_responder_email TEXT, p_accept BOOLEAN
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_action public.joint_account_actions%ROWTYPE;
    v_account public.accounts%ROWTYPE;
    v_invited TEXT;
BEGIN
    SELECT * INTO v_action FROM public.joint_account_actions
    WHERE ref_code = UPPER(btrim(COALESCE(p_ref_code, ''))) FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error',
            'No request found for reference ' || COALESCE(p_ref_code, '(none)') || '.');
    END IF;

    IF v_action.action_type <> 'add_holder' THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Reference ' || v_action.ref_code || ' is not an invitation to join an account.');
    END IF;

    v_invited := lower(COALESCE(v_action.payload ->> 'new_holder_email', ''));
    IF v_invited <> lower(btrim(p_responder_email)) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'This invitation was not addressed to your email address.');
    END IF;

    IF v_action.status <> 'pending' THEN
        RETURN jsonb_build_object('success', false, 'already_decided', true,
            'error', 'Request ' || v_action.ref_code || ' was already ' || v_action.status || '.');
    END IF;

    IF v_action.expires_at <= NOW() THEN
        UPDATE public.joint_account_actions SET status = 'expired', updated_at = NOW()
        WHERE id = v_action.id;
        RETURN jsonb_build_object('success', false, 'status', 'expired',
            'error', 'Request ' || v_action.ref_code || ' has expired.');
    END IF;

    IF NOT p_accept THEN
        UPDATE public.joint_account_actions
        SET status = 'rejected', last_error = 'Declined by the invited holder', updated_at = NOW()
        WHERE id = v_action.id;

        PERFORM public.write_audit_log(
            'holder_addition_declined', 'customer', NULL, 'joint_account_action', v_action.id,
            jsonb_build_object('ref_code', v_action.ref_code, 'declined_by', v_invited));

        SELECT * INTO v_account FROM public.accounts WHERE id = v_action.account_id;
        RETURN jsonb_build_object('success', true, 'accepted', false, 'status', 'rejected',
            'ref_code', v_action.ref_code, 'account_number', v_account.account_number,
            'invited_email', v_invited,
            'requester_email', (SELECT email FROM public.profiles WHERE id = v_action.requested_by_profile_id));
    END IF;

    UPDATE public.joint_account_actions
    SET payload = payload || jsonb_build_object('invitee_accepted', true,
                                                'invitee_accepted_at', NOW()),
        updated_at = NOW()
    WHERE id = v_action.id
    RETURNING * INTO v_action;

    PERFORM public.write_audit_log(
        'holder_addition_accepted', 'customer', NULL, 'joint_account_action', v_action.id,
        jsonb_build_object('ref_code', v_action.ref_code, 'accepted_by', v_invited));

    SELECT * INTO v_account FROM public.accounts WHERE id = v_action.account_id;

    -- Their acceptance may have been the last thing missing.
    RETURN public.finalize_joint_action_if_complete(v_action.id) || jsonb_build_object(
        'accepted', true, 'ref_code', v_action.ref_code,
        'account_number', v_account.account_number, 'invited_email', v_invited,
        'requester_email', (SELECT email FROM public.profiles WHERE id = v_action.requested_by_profile_id));
END;
$$;

-- ---------------------------------------------------------------------------
-- finalize now refuses add_holder until the invited person has accepted.

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
            'consents_count', v_consents_count, 'required', v_required);
    END IF;

    -- Existing holders have all signed, but for an addition the incoming holder
    -- has their own say and it has not arrived yet.
    IF v_action.action_type = 'add_holder'
       AND NOT COALESCE((v_action.payload ->> 'invitee_accepted')::boolean, false) THEN
        RETURN jsonb_build_object(
            'success', true, 'joint_action_id', p_joint_action_id, 'status', 'pending',
            'requires_additional_signatures', true,
            'awaiting_invitee_acceptance', true,
            'invitee_email', v_action.payload ->> 'new_holder_email',
            'consents_count', v_consents_count, 'required', v_required);
    END IF;

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
            (v_action.payload ->> 'fraud_assessment_id')::UUID);

    ELSIF v_action.action_type = 'add_holder' THEN
        BEGIN
            v_result := public.add_account_holder(
                v_action.account_id,
                (v_action.payload ->> 'new_profile_id')::UUID,
                COALESCE(v_action.payload ->> 'role', 'joint'),
                v_action.requested_by_profile_id,
                TRUE);
        EXCEPTION WHEN OTHERS THEN
            v_result := jsonb_build_object('success', false, 'error', SQLERRM,
                                           'executed_action', 'add_holder');
        END;

    ELSIF v_action.action_type = 'remove_holder' THEN
        BEGIN
            v_result := public.remove_account_holder(
                v_action.account_id,
                (v_action.payload ->> 'target_profile_id')::UUID,
                v_action.requested_by_profile_id);
        EXCEPTION WHEN OTHERS THEN
            v_result := jsonb_build_object('success', false, 'error', SQLERRM,
                                           'executed_action', 'remove_holder');
        END;

    ELSIF v_action.action_type = 'set_authority' THEN
        BEGIN
            v_result := public.apply_authority_change(p_joint_action_id);
        EXCEPTION WHEN OTHERS THEN
            v_result := jsonb_build_object('success', false, 'error', SQLERRM,
                                           'executed_action', 'set_authority');
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
        UPDATE public.joint_account_actions
        SET last_error = v_result ->> 'error', updated_at = NOW()
        WHERE id = p_joint_action_id;
    END IF;

    PERFORM public.write_audit_log(
        CASE WHEN v_ok THEN 'joint_action_finalized' ELSE 'joint_action_execution_failed' END,
        'system', NULL, 'joint_account_action', p_joint_action_id,
        jsonb_build_object('action_type', v_action.action_type, 'consents_count', v_consents_count,
                           'required', v_required, 'error', v_result ->> 'error'));

    RETURN v_result || jsonb_build_object(
        'joint_action_id', p_joint_action_id,
        'action_type', v_action.action_type,
        'status', CASE WHEN v_ok THEN 'approved' ELSE 'pending' END,
        'all_signatures_collected', true);
END;
$$;

ALTER FUNCTION public.accept_holder_addition(TEXT, TEXT, BOOLEAN) OWNER TO banking_functions;
ALTER FUNCTION public.finalize_joint_action_if_complete(uuid) OWNER TO banking_functions;
REVOKE ALL ON FUNCTION public.accept_holder_addition(TEXT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.accept_holder_addition(TEXT, TEXT, BOOLEAN) TO service_role;
