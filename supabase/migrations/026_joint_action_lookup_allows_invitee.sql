-- 026: get_joint_action_by_ref() refused anyone who is not already a holder of
-- the account. That is right for every action except add_holder, where the
-- person who most needs to answer -- the one being invited to join -- is by
-- definition not a holder yet. Their reply would have been rejected with "you
-- are not a holder of the account this request belongs to", which is both wrong
-- and confusing.
--
-- The lookup now recognises the invitee and flags them, so the caller can route
-- them to accept_holder_addition() instead of record_joint_consent().

CREATE OR REPLACE FUNCTION public.get_joint_action_by_ref(p_ref_code TEXT, p_responder_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_action public.joint_account_actions%ROWTYPE;
    v_account public.accounts%ROWTYPE;
    v_profile_id UUID;
    v_is_holder BOOLEAN := FALSE;
    v_is_invitee BOOLEAN := FALSE;
    v_email TEXT := lower(btrim(COALESCE(p_responder_email, '')));
BEGIN
    SELECT * INTO v_action FROM public.joint_account_actions
    WHERE ref_code = UPPER(btrim(COALESCE(p_ref_code, '')));
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error',
            'No request found for reference ' || COALESCE(p_ref_code, '(none)') || '.');
    END IF;

    SELECT id INTO v_profile_id FROM public.profiles WHERE lower(email) = v_email;

    IF v_profile_id IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1 FROM public.account_holders
            WHERE account_id = v_action.account_id AND profile_id = v_profile_id
        ) INTO v_is_holder;
    END IF;

    v_is_invitee := v_action.action_type = 'add_holder'
                    AND lower(COALESCE(v_action.payload ->> 'new_holder_email', '')) = v_email;

    IF NOT v_is_holder AND NOT v_is_invitee THEN
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
        'is_holder', v_is_holder,
        -- When true the caller must use accept_holder_addition(), because this
        -- person cannot have a consent row until they are actually a holder.
        'is_invitee', v_is_invitee AND NOT v_is_holder,
        'needs_fraud_assessment', (v_action.action_type = 'transfer_approval' AND v_action.status = 'pending'),
        'amount', (v_action.payload ->> 'amount')::BIGINT,
        'last_error', v_action.last_error
    );
END;
$$;

ALTER FUNCTION public.get_joint_action_by_ref(TEXT, TEXT) OWNER TO banking_functions;
REVOKE ALL ON FUNCTION public.get_joint_action_by_ref(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_joint_action_by_ref(TEXT, TEXT) TO service_role;
