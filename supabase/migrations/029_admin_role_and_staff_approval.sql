-- 029_admin_role_and_staff_approval.sql
--
-- Migration 028 let anyone with the pass phrase become an operator instantly,
-- and let any operator credit any account. Those two together mean the phrase
-- alone is enough to pay yourself: learn it, enrol, credit, done. Splitting
-- the role is what closes that.
--
--   * Only an ADMIN can credit an account. Operators can decide loans, resolve
--     disputes, answer approvals -- everything except creating money.
--   * The pass phrase no longer enrols anyone. It raises a request that an
--     admin has to approve, so the phrase is a way of asking, not a way in.
--   * An admin can remove an operator, and a removed address is an ordinary
--     member of the public again: it can open an account, or ask to rejoin.
--
-- The phrase leaking is now an annoyance rather than a theft.

-- ---------------------------------------------------------------------------
-- 1. Who is an admin
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_bank_admin(p_email TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.bank_staff
        WHERE lower(email) = lower(trim(COALESCE(p_email, '')))
          AND is_active AND role = 'admin'
    );
$$;

ALTER TABLE public.ops_approvals DROP CONSTRAINT IF EXISTS ops_approvals_request_type_check;
ALTER TABLE public.ops_approvals ADD CONSTRAINT ops_approvals_request_type_check
    CHECK (request_type IN ('loan', 'support_draft', 'minor_account', 'fraud_hold_release',
                            'transfer_reversal', 'remove_holder', 'dispute', 'staff_enrolment'));

CREATE OR REPLACE FUNCTION public.staff_check(p_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_inbox TEXT;
    v_admin TEXT;
    v_count INT;
BEGIN
    SELECT email INTO v_inbox FROM public.bank_staff
    WHERE is_active ORDER BY created_at LIMIT 1;

    SELECT email INTO v_admin FROM public.bank_staff
    WHERE is_active AND role = 'admin' ORDER BY created_at LIMIT 1;

    SELECT COUNT(*) INTO v_count FROM public.bank_staff WHERE is_active;

    RETURN jsonb_build_object(
        'is_staff', public.is_bank_staff(p_email),
        'is_admin', public.is_bank_admin(p_email),
        'ops_inbox', v_inbox,
        'admin_inbox', v_admin,
        'staff_count', v_count
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Creating money is an admin power
-- ---------------------------------------------------------------------------
-- Everything else an operator does moves money that already exists, or decides
-- something a customer asked for. A credit conjures a balance out of the
-- treasury, and that is the one action worth keeping to a single pair of hands.

CREATE OR REPLACE FUNCTION public.operator_credit_account(
    p_operator_email TEXT,
    p_target TEXT,
    p_amount BIGINT,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_resolved JSONB;
    v_account public.accounts%ROWTYPE;
    v_treasury public.accounts%ROWTYPE;
    v_txn_id UUID;
    v_holder_email TEXT;
    v_admin TEXT;
BEGIN
    IF NOT public.is_bank_admin(p_operator_email) THEN
        SELECT email INTO v_admin FROM public.bank_staff
        WHERE is_active AND role = 'admin' ORDER BY created_at LIMIT 1;

        RETURN jsonb_build_object('success', false, 'requires_admin', true,
            'admin_email', v_admin,
            'error', CASE WHEN public.is_bank_staff(p_operator_email)
                THEN 'Crediting an account is reserved to the bank administrator. '
                  || 'Every other operations command is available to you; this one '
                  || 'creates money out of the treasury, so it stays with one person. '
                  || 'Ask ' || COALESCE(v_admin, 'the administrator') || ' to issue it.'
                ELSE 'Only the bank administrator can credit an account.' END);
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error',
            'State a positive amount to credit.');
    END IF;

    v_resolved := public.resolve_destination_account(p_target);
    IF NOT (v_resolved->>'found')::boolean THEN
        RETURN jsonb_build_object('success', false,
            'error', 'Could not identify the account to credit (' ||
                     COALESCE(v_resolved->>'reason', 'unknown') || ').',
            'lookup', p_target, 'detail', v_resolved);
    END IF;

    SELECT * INTO v_account FROM public.accounts
    WHERE id = (v_resolved->>'account_id')::uuid;

    IF v_account.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Account ' || v_account.account_number || ' is ' || v_account.status ||
            ' and cannot receive a credit.');
    END IF;

    SELECT * INTO v_treasury FROM public.accounts WHERE account_number = 'TREASURY-MAIN';
    IF v_treasury.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Treasury account not found.');
    END IF;

    v_txn_id := public.process_money_movement(
        v_treasury.id, v_account.id, p_amount, v_account.currency,
        'Bank credit' || CASE WHEN p_reason IS NULL OR trim(p_reason) = ''
                              THEN '' ELSE ': ' || trim(p_reason) END,
        NULL
    );

    SELECT p.email INTO v_holder_email
    FROM public.account_holders ah
    JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = v_account.id
    ORDER BY ah.created_at LIMIT 1;

    PERFORM public.write_audit_log(
        'operator_credit', 'admin', NULL, 'account', v_account.id,
        jsonb_build_object('operator_email', p_operator_email, 'amount', p_amount,
                           'reason', p_reason, 'transaction_id', v_txn_id,
                           'account_number', v_account.account_number));

    RETURN jsonb_build_object(
        'success', true, 'transaction_id', v_txn_id, 'account_id', v_account.id,
        'account_number', v_account.account_number, 'holder_email', v_holder_email,
        'amount', p_amount,
        'new_balance', (SELECT balance FROM public.accounts WHERE id = v_account.id),
        'reason', p_reason);
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. The pass phrase asks; the admin decides
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enrol_bank_staff(p_email TEXT, p_phrase TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_email TEXT := lower(trim(COALESCE(p_email, '')));
    v_failures INT;
    v_hash TEXT;
    v_ok BOOLEAN;
    v_admins TEXT[];
    v_existing public.ops_approvals%ROWTYPE;
    v_created JSONB;
    v_ref TEXT;
BEGIN
    IF v_email = '' OR v_email NOT LIKE '%@%' THEN
        RETURN jsonb_build_object('success', false, 'error', 'No sender address.');
    END IF;

    IF public.is_bank_staff(v_email) THEN
        RETURN jsonb_build_object('success', false, 'already_staff', true,
            'error', 'That address is already on the operations team.');
    END IF;

    SELECT COUNT(*) INTO v_failures
    FROM public.staff_enrolment_attempts
    WHERE lower(email) = v_email AND NOT succeeded
      AND attempted_at > NOW() - INTERVAL '1 hour';

    IF v_failures >= 5 THEN
        INSERT INTO public.staff_enrolment_attempts (email, succeeded, reason)
        VALUES (v_email, FALSE, 'rate_limited');
        PERFORM public.write_audit_log(
            'staff_enrolment_rate_limited', 'system', NULL, 'bank_staff', NULL,
            jsonb_build_object('email', v_email, 'failures_in_last_hour', v_failures));
        RETURN jsonb_build_object('success', false, 'rate_limited', true,
            'error', 'Too many attempts from this address. Try again in an hour.');
    END IF;

    IF EXISTS (SELECT 1 FROM public.profiles WHERE lower(email) = v_email) THEN
        INSERT INTO public.staff_enrolment_attempts (email, succeeded, reason)
        VALUES (v_email, FALSE, 'is_customer');
        PERFORM public.write_audit_log(
            'staff_enrolment_refused_customer', 'system', NULL, 'bank_staff', NULL,
            jsonb_build_object('email', v_email));
        RETURN jsonb_build_object('success', false, 'is_customer', true,
            'error', 'That address is registered as a customer of this bank. '
                  || 'A customer cannot also be an operator, because an operator '
                  || 'can act on any account. Use an address that holds no accounts here.');
    END IF;

    SELECT phrase_hash INTO v_hash FROM public.staff_passphrase WHERE id;
    IF v_hash IS NULL THEN
        RETURN jsonb_build_object('success', false, 'not_configured', true,
            'error', 'Operations enrolment is not configured.');
    END IF;

    v_ok := (extensions.crypt(COALESCE(p_phrase, ''), v_hash) = v_hash);

    INSERT INTO public.staff_enrolment_attempts (email, succeeded, reason)
    VALUES (v_email, v_ok, CASE WHEN v_ok THEN 'requested' ELSE 'wrong_phrase' END);

    IF NOT v_ok THEN
        PERFORM public.write_audit_log(
            'staff_enrolment_failed', 'system', NULL, 'bank_staff', NULL,
            jsonb_build_object('email', v_email, 'attempt', v_failures + 1, 'of_allowed', 5));
        RETURN jsonb_build_object('success', false, 'wrong_phrase', true,
            'attempts_remaining', 5 - (v_failures + 1),
            'error', 'That is not the operations pass phrase.');
    END IF;

    SELECT array_agg(email ORDER BY created_at) INTO v_admins
    FROM public.bank_staff WHERE is_active AND role = 'admin';

    IF v_admins IS NULL OR array_length(v_admins, 1) IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
            'There is no administrator to approve operations access.');
    END IF;

    -- Don't stack requests: sending the phrase twice should not put two
    -- decisions in front of the admin for the same person.
    SELECT * INTO v_existing FROM public.ops_approvals
    WHERE request_type = 'staff_enrolment' AND status = 'pending'
      AND lower(payload ->> 'email') = v_email AND expires_at > NOW()
    LIMIT 1;

    IF v_existing.id IS NOT NULL THEN
        RETURN jsonb_build_object('success', true, 'pending', true, 'reused', true,
            'email', v_email, 'ref_code', v_existing.ref_code,
            'admin_emails', to_jsonb(v_admins));
    END IF;

    v_created := public.create_ops_approval(
        'staff_enrolment', NULL,
        'Operations access requested by ' || v_email,
        v_email || ' sent the correct operations pass phrase and is asking to join '
                 || 'the operations team. Approving grants them every operations '
                 || 'command except crediting an account, which stays with the '
                 || 'administrator. They hold no customer account here.',
        jsonb_build_object('email', v_email),
        v_email);

    v_ref := v_created ->> 'ref_code';

    PERFORM public.write_audit_log(
        'staff_enrolment_requested', 'system', NULL, 'bank_staff', NULL,
        jsonb_build_object('email', v_email, 'ref_code', v_ref));

    RETURN jsonb_build_object('success', true, 'pending', true, 'reused', false,
        'email', v_email, 'ref_code', v_ref, 'admin_emails', to_jsonb(v_admins));
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Removing an operator
-- ---------------------------------------------------------------------------
-- Deactivation rather than deletion: the audit trail still points at a row, and
-- `is_bank_staff` only counts active ones, so the address is immediately an
-- ordinary member of the public -- free to open an account, or to ask to rejoin.

CREATE OR REPLACE FUNCTION public.remove_bank_staff(
    p_admin_email TEXT,
    p_target_email TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_target TEXT := lower(trim(COALESCE(p_target_email, '')));
    v_row public.bank_staff%ROWTYPE;
    v_admins TEXT[];
BEGIN
    IF NOT public.is_bank_admin(p_admin_email) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Only the bank administrator can remove an operator.');
    END IF;

    SELECT * INTO v_row FROM public.bank_staff WHERE lower(email) = v_target AND is_active;
    IF v_row.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
            COALESCE(NULLIF(v_target, ''), '(no address)') ||
            ' is not currently on the operations team.');
    END IF;

    -- An admin removing an admin, themselves included, can leave the bank with
    -- nobody able to approve anything or to undo the removal.
    IF v_row.role = 'admin' THEN
        RETURN jsonb_build_object('success', false, 'error',
            'That address is an administrator and cannot be removed this way.');
    END IF;

    UPDATE public.bank_staff SET is_active = FALSE WHERE id = v_row.id;

    -- Their old failed guesses should not count against them if they reapply.
    DELETE FROM public.staff_enrolment_attempts WHERE lower(email) = v_target;

    -- A request still sitting in the queue for someone just removed is noise.
    UPDATE public.ops_approvals
    SET status = 'cancelled', decision_note = 'Operator removed by the administrator',
        decided_at = NOW(), updated_at = NOW()
    WHERE request_type = 'staff_enrolment' AND status = 'pending'
      AND lower(payload ->> 'email') = v_target;

    SELECT array_agg(email ORDER BY created_at) INTO v_admins
    FROM public.bank_staff WHERE is_active;

    PERFORM public.write_audit_log(
        'staff_removed', 'admin', NULL, 'bank_staff', v_row.id,
        jsonb_build_object('email', v_target, 'removed_by', lower(trim(p_admin_email))));

    RETURN jsonb_build_object('success', true, 'email', v_target,
        'removed_by', lower(trim(p_admin_email)),
        'remaining_staff', to_jsonb(COALESCE(v_admins, ARRAY[]::TEXT[])));
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Approvals: who is allowed to decide one
-- ---------------------------------------------------------------------------
-- This function previously trusted whatever address was handed to it. The
-- routing layer only ever gave it an operator's, but the routing layer is the
-- part most likely to be edited by mistake, so the rule belongs here too.

CREATE OR REPLACE FUNCTION public.resolve_ops_approval(
    p_ref_code TEXT, p_decision TEXT, p_decided_by_email TEXT, p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_req public.ops_approvals%ROWTYPE;
    v_decision TEXT;
    v_result JSONB := '{}'::jsonb;
    v_draft public.support_case_drafts%ROWTYPE;
    v_case public.support_cases%ROWTYPE;
    v_customer_email TEXT;
    v_joiner TEXT;
BEGIN
    IF NOT public.is_bank_staff(p_decided_by_email) THEN
        RETURN jsonb_build_object('success', false, 'not_authorised', true,
            'error', 'Only the operations team can decide an approval request.');
    END IF;

    v_decision := LOWER(btrim(COALESCE(p_decision, '')));
    IF v_decision NOT IN ('approve','approved','reject','rejected','deny','denied') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Decision must be APPROVE or REJECT.');
    END IF;
    v_decision := CASE WHEN v_decision IN ('approve','approved') THEN 'approve' ELSE 'reject' END;

    SELECT * INTO v_req FROM public.ops_approvals
    WHERE ref_code = UPPER(btrim(p_ref_code)) FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error',
            'No approval request found for reference ' || COALESCE(p_ref_code, '(none)'));
    END IF;

    IF v_req.status <> 'pending' THEN
        RETURN jsonb_build_object('success', false, 'already_decided', true,
            'error', 'Request ' || v_req.ref_code || ' was already ' || v_req.status || '.',
            'ref_code', v_req.ref_code, 'status', v_req.status, 'request_type', v_req.request_type);
    END IF;

    IF v_req.expires_at <= NOW() THEN
        UPDATE public.ops_approvals SET status = 'expired', updated_at = NOW() WHERE id = v_req.id;
        RETURN jsonb_build_object('success', false, 'error',
            'Request ' || v_req.ref_code || ' expired on ' || to_char(v_req.expires_at, 'YYYY-MM-DD') || '.',
            'ref_code', v_req.ref_code, 'status', 'expired');
    END IF;

    -- Who joins the operations team is the administrator's decision alone.
    -- Otherwise an operator could approve the next operator, and the pass
    -- phrase would be self-propagating.
    IF v_req.request_type = 'staff_enrolment'
       AND NOT public.is_bank_admin(p_decided_by_email) THEN
        RETURN jsonb_build_object('success', false, 'not_authorised', true,
            'ref_code', v_req.ref_code, 'request_type', v_req.request_type,
            'error', 'Only the bank administrator can decide who joins the operations team.');
    END IF;

    IF v_req.request_type = 'loan' THEN
        IF v_decision = 'approve' THEN
            v_result := public.approve_loan(v_req.target_id, NULL);
        ELSE
            v_result := public.reject_loan(v_req.target_id, NULL,
                COALESCE(NULLIF(btrim(p_note), ''), 'Declined by the credit review team.'));
        END IF;
        SELECT p.email INTO v_customer_email
        FROM public.loans l JOIN public.profiles p ON p.id = l.profile_id
        WHERE l.id = v_req.target_id;

    ELSIF v_req.request_type = 'staff_enrolment' THEN
        v_joiner := lower(v_req.payload ->> 'email');
        IF v_decision = 'approve' THEN
            IF EXISTS (SELECT 1 FROM public.profiles WHERE lower(email) = v_joiner) THEN
                -- They opened an account while the request was queued.
                v_result := jsonb_build_object('success', false,
                    'error', v_joiner || ' has opened a customer account since asking, '
                          || 'so they can no longer be an operator.');
            ELSE
                INSERT INTO public.bank_staff (email, role, note)
                VALUES (v_joiner, 'ops', 'Approved by the administrator after sending the pass phrase')
                ON CONFLICT (email) DO UPDATE SET is_active = TRUE, role = 'ops';
                v_result := jsonb_build_object('success', true, 'enrolled', true,
                    'email', v_joiner);
                PERFORM public.write_audit_log(
                    'staff_enrolled', 'admin', NULL, 'bank_staff', NULL,
                    jsonb_build_object('email', v_joiner, 'approved_by', p_decided_by_email));
            END IF;
        ELSE
            v_result := jsonb_build_object('success', true, 'enrolled', false,
                'email', v_joiner);
        END IF;
        v_customer_email := v_joiner;

    ELSIF v_req.request_type = 'support_draft' THEN
        SELECT * INTO v_draft FROM public.support_case_drafts WHERE id = v_req.target_id;
        IF NOT FOUND THEN
            v_result := jsonb_build_object('success', false, 'error', 'Support draft no longer exists');
        ELSE
            SELECT * INTO v_case FROM public.support_cases WHERE id = v_draft.support_case_id;
            IF v_decision = 'approve' THEN
                UPDATE public.support_case_drafts
                SET human_review_state = CASE WHEN NULLIF(btrim(p_note),'') IS NULL THEN 'approved' ELSE 'edited' END,
                    groq_draft = COALESCE(NULLIF(btrim(p_note), ''), groq_draft),
                    updated_at = NOW()
                WHERE id = v_draft.id RETURNING * INTO v_draft;
                UPDATE public.support_cases
                SET status = 'resolved', final_sent_response = v_draft.groq_draft, updated_at = NOW()
                WHERE id = v_case.id;
            ELSE
                UPDATE public.support_case_drafts
                SET human_review_state = 'rejected', updated_at = NOW() WHERE id = v_draft.id;
                UPDATE public.support_cases SET status = 'closed', updated_at = NOW() WHERE id = v_case.id;
            END IF;
            v_result := jsonb_build_object('success', true, 'support_case_id', v_case.id,
                'answer_text', v_draft.groq_draft, 'case_subject', v_case.subject);
            v_customer_email := COALESCE(v_case.customer_email,
                (SELECT email FROM public.profiles WHERE id = v_case.profile_id));
        END IF;

    ELSIF v_req.request_type = 'fraud_hold_release' THEN
        IF v_decision = 'approve' THEN
            v_result := public.release_account_hold(v_req.target_id, NULL);
        ELSE
            v_result := jsonb_build_object('success', true, 'released', false,
                'note', 'Hold left in place by ops decision.');
        END IF;
        v_customer_email := v_req.requested_for_email;

    ELSIF v_req.request_type = 'dispute' THEN
        v_result := public.resolve_dispute(
            v_req.target_id, v_decision = 'approve',
            COALESCE(NULLIF(btrim(p_note), ''),
                     CASE WHEN v_decision = 'approve'
                          THEN 'Dispute upheld after review.'
                          ELSE 'After review we were unable to uphold this dispute.' END),
            p_decided_by_email);
        v_customer_email := COALESCE(v_result ->> 'raised_by_email', v_req.requested_for_email);

    ELSIF v_req.request_type = 'transfer_reversal' THEN
        IF v_decision = 'approve' THEN
            v_result := public.reverse_transaction(
                v_req.target_id,
                COALESCE(NULLIF(btrim(p_note), ''), 'Reversal authorised by operations.'), NULL);
        ELSE
            v_result := jsonb_build_object('success', true, 'reversed', false,
                'note', 'Reversal declined by ops; the transaction stands.');
        END IF;
        v_customer_email := COALESCE(v_result ->> 'beneficiary_email', v_req.requested_for_email);

    ELSE
        v_result := jsonb_build_object('success', true, 'deferred_to_caller', true);
        v_customer_email := v_req.requested_for_email;
    END IF;

    UPDATE public.ops_approvals
    SET status = CASE
                    WHEN COALESCE((v_result ->> 'success')::boolean, true) = false THEN 'failed'
                    WHEN v_decision = 'approve' THEN 'approved'
                    ELSE 'rejected'
                 END,
        decided_by_email = p_decided_by_email,
        decision_note = NULLIF(btrim(p_note), ''),
        decision_result = v_result,
        decided_at = NOW(), updated_at = NOW()
    WHERE id = v_req.id RETURNING * INTO v_req;

    PERFORM public.write_audit_log(
        'ops_approval_resolved', 'admin', NULL, 'ops_approval', v_req.id,
        jsonb_build_object('ref_code', v_req.ref_code, 'decision', v_decision,
                           'request_type', v_req.request_type, 'decided_by', p_decided_by_email,
                           'status', v_req.status));

    RETURN jsonb_build_object(
        'success', COALESCE((v_result ->> 'success')::boolean, true),
        'ref_code', v_req.ref_code, 'request_type', v_req.request_type,
        'target_id', v_req.target_id, 'decision', v_decision, 'status', v_req.status,
        'subject', v_req.subject, 'summary', v_req.summary, 'payload', v_req.payload,
        'customer_email', COALESCE(v_customer_email, v_req.requested_for_email),
        'decision_note', v_req.decision_note, 'result', v_result);
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Permissions
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.is_bank_admin(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.remove_bank_staff(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_bank_admin(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.remove_bank_staff(TEXT, TEXT) TO service_role;
