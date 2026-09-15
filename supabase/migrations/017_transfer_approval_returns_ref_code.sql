-- 017: the pending-signatures response must carry the short JNT ref code and the
-- human-readable account numbers, otherwise n8n has nothing to put in the email
-- asking the co-holders to sign.

CREATE OR REPLACE FUNCTION public.request_transfer_approval(
    p_source_account_id uuid, p_destination_account_id uuid, p_amount bigint,
    p_currency text, p_idempotency_key text, p_fraud_assessment_id uuid,
    p_initiated_by_profile_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_action public.joint_account_actions%ROWTYPE;
    v_result JSONB;
    v_pending_emails TEXT[];
    v_account public.accounts%ROWTYPE;
    v_dest_number TEXT;
    v_requester_name TEXT;
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
    ) RETURNING * INTO v_action;

    INSERT INTO public.joint_account_consents (joint_action_id, profile_id, consent)
    VALUES (v_action.id, p_initiated_by_profile_id, TRUE);

    PERFORM public.write_audit_log(
        'transfer_approval_requested', 'customer', p_initiated_by_profile_id,
        'joint_account_action', v_action.id,
        jsonb_build_object('account_id', p_source_account_id, 'amount', p_amount,
                           'destination_account_id', p_destination_account_id,
                           'ref_code', v_action.ref_code)
    );

    v_result := public.finalize_joint_action_if_complete(v_action.id);

    SELECT array_agg(p.email) INTO v_pending_emails
    FROM public.account_holders ah
    JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = p_source_account_id
      AND ah.profile_id <> p_initiated_by_profile_id
      AND NOT EXISTS (
          SELECT 1 FROM public.joint_account_consents c
          WHERE c.joint_action_id = v_action.id AND c.profile_id = ah.profile_id AND c.consent
      );

    SELECT * INTO v_account FROM public.accounts WHERE id = p_source_account_id;
    SELECT account_number INTO v_dest_number FROM public.accounts WHERE id = p_destination_account_id;
    SELECT full_name INTO v_requester_name FROM public.profiles WHERE id = p_initiated_by_profile_id;

    IF COALESCE((v_result ->> 'requires_additional_signatures')::boolean, false) THEN
        RETURN v_result || jsonb_build_object(
            'success', true, 'executed', false, 'awaiting_signatures', true,
            'joint_action_id', v_action.id, 'ref_code', v_action.ref_code,
            'source_account_number', v_account.account_number,
            'destination_account_number', v_dest_number,
            'requester_name', v_requester_name,
            'amount', p_amount,
            'pending_holder_emails', to_jsonb(COALESCE(v_pending_emails, ARRAY[]::TEXT[])),
            'expires_at', v_action.expires_at
        );
    END IF;

    RETURN v_result || jsonb_build_object('executed', true,
        'joint_action_id', v_action.id, 'ref_code', v_action.ref_code);
END;
$$;

ALTER FUNCTION public.request_transfer_approval(uuid, uuid, bigint, text, text, uuid, uuid) OWNER TO banking_functions;
REVOKE ALL ON FUNCTION public.request_transfer_approval(uuid, uuid, bigint, text, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_transfer_approval(uuid, uuid, bigint, text, text, uuid, uuid) TO service_role;
