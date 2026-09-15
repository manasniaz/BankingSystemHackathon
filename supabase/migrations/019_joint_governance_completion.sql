-- 019: completes the joint-account governance domain from the capstone brief.
--
-- Closes three items that had the plumbing but no action:
--   #4 mutual consent to REMOVE a joint holder  (no 'remove_holder' action existed)
--   #5 majority vs unanimous for 3+ holders     (closure_authority existed, nothing set it)
--   #8 adding a holder to an account with debt  (holds were checked, debt was not)
--
-- All three ride the existing joint_account_actions / joint_account_consents
-- machinery, so they inherit the JNT- reference code, the email round-trip, the
-- 7-day expiry and the "execute first, only then mark approved" correctness fix
-- from 014 for free.

ALTER TABLE public.joint_account_actions
    DROP CONSTRAINT IF EXISTS joint_account_actions_action_type_check;

ALTER TABLE public.joint_account_actions
    ADD CONSTRAINT joint_account_actions_action_type_check
    CHECK (action_type IN ('close_account', 'transfer_approval', 'add_holder',
                           'remove_holder', 'set_authority'));

-- ---------------------------------------------------------------------------
-- Removing a holder. Mutual consent means EVERY holder signs, including the
-- person being removed -- you cannot be ejected from an account you are liable
-- for without agreeing, and you cannot walk away from one unilaterally either.

CREATE OR REPLACE FUNCTION public.remove_account_holder(
    p_account_id uuid, p_profile_id uuid, p_requested_by_profile_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_remaining INT;
    v_holder public.account_holders%ROWTYPE;
    v_email TEXT;
BEGIN
    SELECT * INTO v_holder FROM public.account_holders
    WHERE account_id = p_account_id AND profile_id = p_profile_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error',
            'That person is not a holder of this account.');
    END IF;

    SELECT COUNT(*) INTO v_remaining
    FROM public.account_holders WHERE account_id = p_account_id;

    -- An account with no holders is unreachable and unownable. Closing the
    -- account is the supported way to end the last relationship, not removal.
    IF v_remaining <= 1 THEN
        RETURN jsonb_build_object('success', false, 'error',
            'This is the only holder on the account. Close the account instead of removing them.');
    END IF;

    -- A guardian cannot be removed while the minor is still a minor, or the
    -- minor would be left holding an account they are not permitted to operate.
    IF v_holder.holder_type = 'guardian' AND EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = p_account_id AND holder_type = 'minor'
    ) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'The guardian cannot be removed while a minor still holds this account.');
    END IF;

    DELETE FROM public.account_holders
    WHERE account_id = p_account_id AND profile_id = p_profile_id;

    SELECT email INTO v_email FROM public.profiles WHERE id = p_profile_id;

    PERFORM public.write_audit_log(
        'holder_removed', 'customer', p_requested_by_profile_id, 'account', p_account_id,
        jsonb_build_object('removed_profile_id', p_profile_id, 'removed_email', v_email,
                           'holders_remaining', v_remaining - 1)
    );

    RETURN jsonb_build_object('success', true, 'account_id', p_account_id,
        'removed_profile_id', p_profile_id, 'removed_email', v_email,
        'holders_remaining', v_remaining - 1);
END;
$$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.request_holder_removal(
    p_account_id uuid, p_requested_by_profile_id uuid, p_target_email TEXT
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_account public.accounts%ROWTYPE;
    v_target_id UUID;
    v_target_holder public.account_holders%ROWTYPE;
    v_action public.joint_account_actions%ROWTYPE;
    v_existing public.joint_account_actions%ROWTYPE;
    v_holder_emails TEXT[];
    v_holder_count INT;
    v_active_loans INT;
    v_active_holds INT;
BEGIN
    SELECT * INTO v_account FROM public.accounts WHERE id = p_account_id;
    IF v_account.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Account not found.');
    END IF;

    IF v_account.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Account ' || v_account.account_number || ' is ' || v_account.status ||
            ' and its holders cannot be changed.');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.account_holders
                   WHERE account_id = p_account_id AND profile_id = p_requested_by_profile_id) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'You are not a holder of that account.');
    END IF;

    SELECT id INTO v_target_id FROM public.profiles WHERE lower(email) = lower(btrim(p_target_email));
    IF v_target_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
            'We do not recognise ' || p_target_email || ' as a customer.');
    END IF;

    SELECT * INTO v_target_holder FROM public.account_holders
    WHERE account_id = p_account_id AND profile_id = v_target_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error',
            p_target_email || ' is not a holder of account ' || v_account.account_number || '.');
    END IF;

    SELECT COUNT(*) INTO v_holder_count FROM public.account_holders WHERE account_id = p_account_id;
    IF v_holder_count <= 1 THEN
        RETURN jsonb_build_object('success', false, 'error',
            'You are the only holder of this account. Ask us to close it instead.');
    END IF;

    -- Debt attaches to the account; you cannot reduce the set of people
    -- answerable for it while it is outstanding.
    SELECT COUNT(*) INTO v_active_loans FROM public.loans
    WHERE account_id = p_account_id AND status IN ('active', 'pending_review');
    IF v_active_loans > 0 THEN
        RETURN jsonb_build_object('success', false, 'has_loan', true, 'error',
            'Account ' || v_account.account_number || ' has an outstanding loan. ' ||
            'No holder can be removed until it is repaid.');
    END IF;

    SELECT COUNT(*) INTO v_active_holds FROM public.account_holds
    WHERE account_id = p_account_id AND status = 'active';
    IF v_active_holds > 0 THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Account ' || v_account.account_number || ' has an active hold. ' ||
            'No holder can be removed until it is released.');
    END IF;

    SELECT * INTO v_existing FROM public.joint_account_actions
    WHERE account_id = p_account_id AND action_type = 'remove_holder'
      AND status = 'pending' AND expires_at > NOW()
      AND (payload ->> 'target_profile_id')::UUID = v_target_id
    LIMIT 1;

    SELECT array_agg(p.email ORDER BY p.email) INTO v_holder_emails
    FROM public.account_holders ah JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = p_account_id;

    IF v_existing.id IS NOT NULL THEN
        RETURN jsonb_build_object('success', true, 'reused', true,
            'ref_code', v_existing.ref_code, 'joint_action_id', v_existing.id,
            'account_number', v_account.account_number,
            'target_email', lower(btrim(p_target_email)),
            'holder_emails', to_jsonb(COALESCE(v_holder_emails, ARRAY[]::TEXT[])),
            'holder_count', v_holder_count, 'expires_at', v_existing.expires_at);
    END IF;

    INSERT INTO public.joint_account_actions
        (account_id, action_type, status, requested_by_profile_id, payload)
    VALUES (p_account_id, 'remove_holder', 'pending', p_requested_by_profile_id,
            jsonb_build_object('target_profile_id', v_target_id,
                               'target_email', lower(btrim(p_target_email))))
    RETURNING * INTO v_action;

    PERFORM public.write_audit_log(
        'holder_removal_requested', 'customer', p_requested_by_profile_id,
        'joint_account_action', v_action.id,
        jsonb_build_object('account_id', p_account_id, 'target_profile_id', v_target_id,
                           'ref_code', v_action.ref_code)
    );

    RETURN jsonb_build_object('success', true, 'reused', false,
        'ref_code', v_action.ref_code, 'joint_action_id', v_action.id,
        'account_number', v_account.account_number,
        'account_id', p_account_id,
        'target_email', lower(btrim(p_target_email)),
        'requester_email', (SELECT email FROM public.profiles WHERE id = p_requested_by_profile_id),
        'holder_emails', to_jsonb(COALESCE(v_holder_emails, ARRAY[]::TEXT[])),
        'holder_count', v_holder_count, 'expires_at', v_action.expires_at);
END;
$$;

-- ---------------------------------------------------------------------------
-- Adding a holder, with the debt/holds disclosure the brief asks for.

CREATE OR REPLACE FUNCTION public.request_holder_addition(
    p_account_id uuid, p_requested_by_profile_id uuid, p_new_holder_email TEXT
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_account public.accounts%ROWTYPE;
    v_new_id UUID;
    v_action public.joint_account_actions%ROWTYPE;
    v_existing public.joint_account_actions%ROWTYPE;
    v_holder_emails TEXT[];
    v_holder_count INT;
    v_active_holds INT;
    v_outstanding BIGINT := 0;
    v_encumbrances TEXT[] := ARRAY[]::TEXT[];
BEGIN
    SELECT * INTO v_account FROM public.accounts WHERE id = p_account_id;
    IF v_account.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Account not found.');
    END IF;

    IF v_account.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Account ' || v_account.account_number || ' is ' || v_account.status ||
            ' and its holders cannot be changed.');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.account_holders
                   WHERE account_id = p_account_id AND profile_id = p_requested_by_profile_id) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'You are not a holder of that account.');
    END IF;

    SELECT id INTO v_new_id FROM public.profiles WHERE lower(email) = lower(btrim(p_new_holder_email));
    IF v_new_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'needs_customer', true, 'error',
            p_new_holder_email || ' is not a Digital Bank customer yet. They need an account ' ||
            'with us before they can be added to yours.');
    END IF;

    IF EXISTS (SELECT 1 FROM public.account_holders
               WHERE account_id = p_account_id AND profile_id = v_new_id) THEN
        RETURN jsonb_build_object('success', false, 'error',
            p_new_holder_email || ' already holds this account.');
    END IF;

    -- The brief asks specifically about joining an account that carries debt or
    -- holds. We do not refuse it -- that is the holders' decision -- but the
    -- encumbrance must be disclosed to everyone asked to approve, including the
    -- person being added, rather than quietly inherited.
    SELECT COUNT(*) INTO v_active_holds FROM public.account_holds
    WHERE account_id = p_account_id AND status = 'active';
    IF v_active_holds > 0 THEN
        v_encumbrances := v_encumbrances || (v_active_holds || ' active hold(s) on the account');
    END IF;

    SELECT COALESCE(SUM(outstanding_balance), 0) INTO v_outstanding
    FROM public.loans WHERE account_id = p_account_id AND status = 'active';
    IF v_outstanding > 0 THEN
        v_encumbrances := v_encumbrances ||
            ('an outstanding loan balance of Rs ' || to_char(v_outstanding / 100.0, 'FM999,999,999.00'));
    END IF;

    SELECT COALESCE(SUM(amount_outstanding), 0) INTO v_outstanding
    FROM public.account_debts WHERE account_id = p_account_id AND status = 'outstanding';
    IF v_outstanding > 0 THEN
        v_encumbrances := v_encumbrances ||
            ('an unpaid debt of Rs ' || to_char(v_outstanding / 100.0, 'FM999,999,999.00'));
    END IF;

    SELECT array_agg(p.email ORDER BY p.email), COUNT(*)
    INTO v_holder_emails, v_holder_count
    FROM public.account_holders ah JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = p_account_id;

    SELECT * INTO v_existing FROM public.joint_account_actions
    WHERE account_id = p_account_id AND action_type = 'add_holder'
      AND status = 'pending' AND expires_at > NOW()
      AND (payload ->> 'new_profile_id')::UUID = v_new_id
    LIMIT 1;

    IF v_existing.id IS NOT NULL THEN
        RETURN jsonb_build_object('success', true, 'reused', true,
            'ref_code', v_existing.ref_code, 'joint_action_id', v_existing.id,
            'account_number', v_account.account_number,
            'new_holder_email', lower(btrim(p_new_holder_email)),
            'holder_emails', to_jsonb(COALESCE(v_holder_emails, ARRAY[]::TEXT[])),
            'holder_count', v_holder_count,
            'encumbrances', to_jsonb(v_encumbrances),
            'expires_at', v_existing.expires_at);
    END IF;

    INSERT INTO public.joint_account_actions
        (account_id, action_type, status, requested_by_profile_id, payload)
    VALUES (p_account_id, 'add_holder', 'pending', p_requested_by_profile_id,
            jsonb_build_object('new_profile_id', v_new_id, 'role', 'joint',
                               'new_holder_email', lower(btrim(p_new_holder_email)),
                               'encumbrances', to_jsonb(v_encumbrances)))
    RETURNING * INTO v_action;

    PERFORM public.write_audit_log(
        'holder_addition_requested', 'customer', p_requested_by_profile_id,
        'joint_account_action', v_action.id,
        jsonb_build_object('account_id', p_account_id, 'new_profile_id', v_new_id,
                           'ref_code', v_action.ref_code,
                           'encumbrances', to_jsonb(v_encumbrances))
    );

    RETURN jsonb_build_object('success', true, 'reused', false,
        'ref_code', v_action.ref_code, 'joint_action_id', v_action.id,
        'account_number', v_account.account_number, 'account_id', p_account_id,
        'new_holder_email', lower(btrim(p_new_holder_email)),
        'requester_email', (SELECT email FROM public.profiles WHERE id = p_requested_by_profile_id),
        'holder_emails', to_jsonb(COALESCE(v_holder_emails, ARRAY[]::TEXT[])),
        'holder_count', v_holder_count,
        'encumbrances', to_jsonb(v_encumbrances),
        'expires_at', v_action.expires_at);
END;
$$;

-- ---------------------------------------------------------------------------
-- Changing the mandate after opening: either-or vs all-signatures for transfers,
-- and unanimous vs majority for closure on accounts with 3+ holders.

CREATE OR REPLACE FUNCTION public.request_authority_change(
    p_account_id uuid, p_requested_by_profile_id uuid,
    p_authority_model TEXT DEFAULT NULL, p_closure_authority TEXT DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_account public.accounts%ROWTYPE;
    v_action public.joint_account_actions%ROWTYPE;
    v_holder_emails TEXT[];
    v_holder_count INT;
BEGIN
    IF p_authority_model IS NULL AND p_closure_authority IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Tell us which setting to change.');
    END IF;

    IF p_authority_model IS NOT NULL AND p_authority_model NOT IN ('either_or','all_signatures') THEN
        RETURN jsonb_build_object('success', false, 'error',
            'The transfer mandate must be either_or or all_signatures.');
    END IF;

    IF p_closure_authority IS NOT NULL AND p_closure_authority NOT IN ('unanimous','majority') THEN
        RETURN jsonb_build_object('success', false, 'error',
            'The closure rule must be unanimous or majority.');
    END IF;

    SELECT * INTO v_account FROM public.accounts WHERE id = p_account_id;
    IF v_account.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Account not found.');
    END IF;

    IF v_account.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Account ' || v_account.account_number || ' is ' || v_account.status || '.');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.account_holders
                   WHERE account_id = p_account_id AND profile_id = p_requested_by_profile_id) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'You are not a holder of that account.');
    END IF;

    SELECT array_agg(p.email ORDER BY p.email), COUNT(*)
    INTO v_holder_emails, v_holder_count
    FROM public.account_holders ah JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = p_account_id;

    IF v_holder_count < 2 THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Account ' || v_account.account_number || ' has a single holder, so there is no ' ||
            'mandate to configure.');
    END IF;

    -- Majority closure only means anything with three or more holders; on two
    -- it is arithmetically identical to unanimous and would just be misleading.
    IF p_closure_authority = 'majority' AND v_holder_count < 3 THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Majority closure needs at least three holders. With two, a majority is both of you, ' ||
            'which is what unanimous already means.');
    END IF;

    INSERT INTO public.joint_account_actions
        (account_id, action_type, status, requested_by_profile_id, payload)
    VALUES (p_account_id, 'set_authority', 'pending', p_requested_by_profile_id,
            jsonb_build_object('authority_model', p_authority_model,
                               'closure_authority', p_closure_authority))
    RETURNING * INTO v_action;

    PERFORM public.write_audit_log(
        'authority_change_requested', 'customer', p_requested_by_profile_id,
        'joint_account_action', v_action.id,
        jsonb_build_object('account_id', p_account_id, 'ref_code', v_action.ref_code,
                           'authority_model', p_authority_model,
                           'closure_authority', p_closure_authority)
    );

    RETURN jsonb_build_object('success', true,
        'ref_code', v_action.ref_code, 'joint_action_id', v_action.id,
        'account_number', v_account.account_number, 'account_id', p_account_id,
        'current_authority_model', v_account.authority_model,
        'current_closure_authority', v_account.closure_authority,
        'new_authority_model', p_authority_model,
        'new_closure_authority', p_closure_authority,
        'requester_email', (SELECT email FROM public.profiles WHERE id = p_requested_by_profile_id),
        'holder_emails', to_jsonb(COALESCE(v_holder_emails, ARRAY[]::TEXT[])),
        'holder_count', v_holder_count, 'expires_at', v_action.expires_at);
END;
$$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.apply_authority_change(p_joint_action_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_action public.joint_account_actions%ROWTYPE;
    v_account public.accounts%ROWTYPE;
BEGIN
    SELECT * INTO v_action FROM public.joint_account_actions WHERE id = p_joint_action_id;

    UPDATE public.accounts
    SET authority_model  = COALESCE(NULLIF(v_action.payload ->> 'authority_model', ''), authority_model),
        closure_authority = COALESCE(NULLIF(v_action.payload ->> 'closure_authority', ''), closure_authority),
        updated_at = NOW()
    WHERE id = v_action.account_id
    RETURNING * INTO v_account;

    PERFORM public.write_audit_log(
        'authority_changed', 'system', NULL, 'account', v_account.id,
        jsonb_build_object('authority_model', v_account.authority_model,
                           'closure_authority', v_account.closure_authority)
    );

    RETURN jsonb_build_object('success', true, 'account_id', v_account.id,
        'authority_model', v_account.authority_model,
        'closure_authority', v_account.closure_authority);
END;
$$;

ALTER FUNCTION public.remove_account_holder(uuid, uuid, uuid) OWNER TO banking_functions;
ALTER FUNCTION public.request_holder_removal(uuid, uuid, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.request_holder_addition(uuid, uuid, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.request_authority_change(uuid, uuid, TEXT, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.apply_authority_change(uuid) OWNER TO banking_functions;

REVOKE ALL ON FUNCTION public.remove_account_holder(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_holder_removal(uuid, uuid, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_holder_addition(uuid, uuid, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_authority_change(uuid, uuid, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.apply_authority_change(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.request_holder_removal(uuid, uuid, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.request_holder_addition(uuid, uuid, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.request_authority_change(uuid, uuid, TEXT, TEXT) TO service_role;
