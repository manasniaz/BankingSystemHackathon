-- 018: closing an account by email.
--
-- Two changes:
--
-- (a) request_joint_closure() used to insert the requester's own consent
--     automatically. On a single-holder account that meant required = 1 and
--     consents = 1, so the account closed INSTANTLY on the strength of one
--     unverified sentence in an email ("delete my account"). Closure is
--     irreversible, so the auto-consent is removed: every holder, the requester
--     included, must now explicitly confirm by replying APPROVE to the emailed
--     JNT- reference code. This reuses the joint-action machinery wholesale --
--     respond_to_joint_action_by_ref() and finalize_joint_action_if_complete()
--     already handle action_type 'close_account' -- and gives a single-holder
--     customer a real "are you sure" step for free.
--
-- (b) request_account_closure() is the customer-facing entry point. It runs the
--     blocking checks UP FRONT and returns a plain-language reason, instead of
--     creating a pending request that is doomed to fail at execution time and
--     leaves the customer waiting on a confirmation that can never succeed.

CREATE OR REPLACE FUNCTION public.request_joint_closure(
    p_account_id uuid, p_requested_by_profile_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_action public.joint_account_actions%ROWTYPE;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = p_account_id AND profile_id = p_requested_by_profile_id
    ) THEN
        RAISE EXCEPTION 'Profile % is not an account holder of %', p_requested_by_profile_id, p_account_id;
    END IF;

    INSERT INTO public.joint_account_actions
        (account_id, action_type, status, requested_by_profile_id, expires_at)
    VALUES (p_account_id, 'close_account', 'pending', p_requested_by_profile_id, NOW() + INTERVAL '7 days')
    RETURNING * INTO v_action;

    -- Deliberately NO consent row for the requester. Closing an account is
    -- irreversible, so the person who asked for it confirms the same way
    -- everyone else does: by replying to the reference code we email them.

    PERFORM public.write_audit_log(
        'joint_closure_requested', 'customer', p_requested_by_profile_id,
        'joint_account_action', v_action.id,
        jsonb_build_object('account_id', p_account_id, 'ref_code', v_action.ref_code)
    );

    RETURN jsonb_build_object(
        'success', true, 'joint_action_id', v_action.id, 'ref_code', v_action.ref_code,
        'status', 'pending', 'expires_at', v_action.expires_at
    );
END;
$$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.request_account_closure(
    p_profile_id uuid, p_account_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_account public.accounts%ROWTYPE;
    v_existing public.joint_account_actions%ROWTYPE;
    v_requested jsonb;
    v_holder_emails TEXT[];
    v_holder_count INT;
    v_active_holds INT;
    v_active_orders INT;
    v_active_loans INT;
    v_requester_email TEXT;
BEGIN
    SELECT * INTO v_account FROM public.accounts WHERE id = p_account_id;
    IF v_account.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Account not found.');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = p_account_id AND profile_id = p_profile_id
    ) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'You are not a holder of that account, so you cannot ask us to close it.');
    END IF;

    IF v_account.status = 'closed' THEN
        RETURN jsonb_build_object('success', false, 'already_closed', true, 'error',
            'Account ' || v_account.account_number || ' is already closed.');
    END IF;

    IF v_account.status = 'frozen' THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Account ' || v_account.account_number || ' is currently frozen and under review. ' ||
            'It cannot be closed until that review is resolved.');
    END IF;

    -- Money first: we never close an account that still holds a balance, because
    -- closing it would strand the funds.
    IF v_account.balance <> 0 THEN
        RETURN jsonb_build_object('success', false, 'has_balance', true,
            'balance', v_account.balance,
            'account_number', v_account.account_number,
            'error', 'Account ' || v_account.account_number || ' still holds Rs ' ||
                     to_char(v_account.balance / 100.0, 'FM999,999,999.00') ||
                     '. Please transfer the full balance to another account first, ' ||
                     'then ask us to close it.');
    END IF;

    SELECT COUNT(*) INTO v_active_holds
    FROM public.account_holds WHERE account_id = p_account_id AND status = 'active';
    IF v_active_holds > 0 THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Account ' || v_account.account_number || ' has an active hold on it and cannot be ' ||
            'closed until that is released by our team.');
    END IF;

    SELECT COUNT(*) INTO v_active_orders
    FROM public.standing_orders WHERE source_account_id = p_account_id AND status = 'active';
    IF v_active_orders > 0 THEN
        RETURN jsonb_build_object('success', false, 'has_standing_orders', true,
            'standing_order_count', v_active_orders,
            'error', 'Account ' || v_account.account_number || ' has ' || v_active_orders ||
                     ' active standing order(s) paying out of it. Those must be cancelled ' ||
                     'before the account can be closed.');
    END IF;

    -- An outstanding loan is a debt to the bank; the account it was disbursed
    -- into and is repaid from cannot simply disappear.
    SELECT COUNT(*) INTO v_active_loans
    FROM public.loans WHERE account_id = p_account_id AND status IN ('active', 'pending_review');
    IF v_active_loans > 0 THEN
        RETURN jsonb_build_object('success', false, 'has_loan', true,
            'error', 'Account ' || v_account.account_number || ' has a loan that is still ' ||
                     'outstanding or awaiting a decision. The loan must be settled before ' ||
                     'the account can be closed.');
    END IF;

    SELECT array_agg(p.email ORDER BY p.email), COUNT(*)
    INTO v_holder_emails, v_holder_count
    FROM public.account_holders ah
    JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = p_account_id;

    SELECT email INTO v_requester_email FROM public.profiles WHERE id = p_profile_id;

    -- Don't stack duplicate closure requests for the same account.
    SELECT * INTO v_existing FROM public.joint_account_actions
    WHERE account_id = p_account_id AND action_type = 'close_account'
      AND status = 'pending' AND expires_at > NOW()
    LIMIT 1;

    IF v_existing.id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', true, 'reused', true,
            'ref_code', v_existing.ref_code, 'joint_action_id', v_existing.id,
            'account_number', v_account.account_number, 'account_id', p_account_id,
            'holder_emails', to_jsonb(COALESCE(v_holder_emails, ARRAY[]::TEXT[])),
            'holder_count', v_holder_count,
            'requester_email', v_requester_email,
            'expires_at', v_existing.expires_at
        );
    END IF;

    v_requested := public.request_joint_closure(p_account_id, p_profile_id);

    RETURN v_requested || jsonb_build_object(
        'reused', false,
        'account_number', v_account.account_number,
        'account_id', p_account_id,
        'account_type', v_account.account_type,
        'holder_emails', to_jsonb(COALESCE(v_holder_emails, ARRAY[]::TEXT[])),
        'holder_count', v_holder_count,
        'requester_email', v_requester_email
    );
END;
$$;

ALTER FUNCTION public.request_joint_closure(uuid, uuid) OWNER TO banking_functions;
ALTER FUNCTION public.request_account_closure(uuid, uuid) OWNER TO banking_functions;
REVOKE ALL ON FUNCTION public.request_joint_closure(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_account_closure(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_joint_closure(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.request_account_closure(uuid, uuid) TO service_role;
