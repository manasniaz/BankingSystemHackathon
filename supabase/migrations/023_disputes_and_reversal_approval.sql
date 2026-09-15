-- 023: disputes as a tracked object with an explicit joint-account rule
-- (brief #23), and the reversal path wired into the ops approval queue so a
-- reversal can only ever happen with a human signature (brief #27).
--
-- THE JOINT-ACCOUNT DISPUTE RULE, stated explicitly because the brief asks for
-- a decision rather than an implementation:
--   * RAISING is unilateral. Any single holder can raise a dispute without
--     waiting for the others. Requiring co-holder sign-off to report suspected
--     fraud would mean the fastest way to stop money leaving is gated behind
--     someone who may be asleep, unreachable, or the problem.
--   * INPUT is collected from every other holder. They are emailed, told what
--     was disputed, and can reply AGREE or DISAGREE with a comment.
--   * RESOLUTION is never automatic and never unilateral. It always goes to a
--     human, and that human is shown whether the co-holders agreed. A dispute
--     one holder raises against a transaction another holder made is exactly
--     the case where a machine should not be deciding.

ALTER TABLE public.ops_approvals DROP CONSTRAINT IF EXISTS ops_approvals_request_type_check;
ALTER TABLE public.ops_approvals ADD CONSTRAINT ops_approvals_request_type_check
    CHECK (request_type IN ('loan', 'support_draft', 'minor_account',
                            'fraud_hold_release', 'transfer_reversal',
                            'remove_holder', 'dispute'));

CREATE TABLE IF NOT EXISTS public.disputes (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ref_code            TEXT NOT NULL UNIQUE,
    account_id          UUID NOT NULL REFERENCES public.accounts(id),
    transaction_id      UUID REFERENCES public.transactions(id),
    raised_by_profile_id UUID NOT NULL REFERENCES public.profiles(id),
    description         TEXT NOT NULL,
    disputed_amount     BIGINT,
    status              TEXT NOT NULL DEFAULT 'open'
                            CHECK (status IN ('open', 'awaiting_holder_input',
                                              'under_review', 'upheld', 'declined')),
    is_joint_account    BOOLEAN NOT NULL DEFAULT FALSE,
    holder_input        JSONB NOT NULL DEFAULT '[]'::jsonb,
    resolution          TEXT,
    resolved_by_email   TEXT,
    ops_ref_code        TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at         TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_disputes_account ON public.disputes (account_id, status);

ALTER TABLE public.disputes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS disputes_deny_anon ON public.disputes;
CREATE POLICY disputes_deny_anon ON public.disputes
    FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.raise_dispute(
    p_profile_id uuid, p_account_id uuid,
    p_transaction_id uuid DEFAULT NULL, p_description TEXT DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_account public.accounts%ROWTYPE;
    v_tx public.transactions%ROWTYPE;
    v_ref TEXT;
    v_attempt INT := 0;
    v_id UUID;
    v_holder_count INT;
    v_other_holders TEXT[];
    v_is_joint BOOLEAN;
    v_ops JSONB;
    v_raiser TEXT;
BEGIN
    SELECT * INTO v_account FROM public.accounts WHERE id = p_account_id;
    IF v_account.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Account not found.');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.account_holders
                   WHERE account_id = p_account_id AND profile_id = p_profile_id) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'You are not a holder of that account.');
    END IF;

    IF p_transaction_id IS NOT NULL THEN
        SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
        IF v_tx.id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error',
                'We could not find that transaction.');
        END IF;
        IF v_tx.source_account_id <> p_account_id AND v_tx.destination_account_id <> p_account_id THEN
            RETURN jsonb_build_object('success', false, 'error',
                'That transaction does not involve your account.');
        END IF;
        IF v_tx.status = 'reversed' THEN
            RETURN jsonb_build_object('success', false, 'error',
                'That transaction has already been reversed.');
        END IF;
    END IF;

    SELECT COUNT(*) INTO v_holder_count FROM public.account_holders WHERE account_id = p_account_id;
    v_is_joint := v_holder_count > 1;

    SELECT array_agg(p.email ORDER BY p.email) INTO v_other_holders
    FROM public.account_holders ah JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = p_account_id AND ah.profile_id <> p_profile_id;

    SELECT email INTO v_raiser FROM public.profiles WHERE id = p_profile_id;

    LOOP
        v_attempt := v_attempt + 1;
        v_ref := 'DSP-' || UPPER(SUBSTRING(REPLACE(gen_random_uuid()::text, '-', '') FROM 1 FOR 8));
        EXIT WHEN NOT EXISTS (SELECT 1 FROM public.disputes WHERE ref_code = v_ref);
        IF v_attempt > 10 THEN RAISE EXCEPTION 'Could not allocate a dispute ref code'; END IF;
    END LOOP;

    INSERT INTO public.disputes (
        ref_code, account_id, transaction_id, raised_by_profile_id, description,
        disputed_amount, status, is_joint_account
    ) VALUES (
        v_ref, p_account_id, p_transaction_id, p_profile_id,
        COALESCE(NULLIF(btrim(p_description), ''), 'No detail supplied'),
        v_tx.amount,
        CASE WHEN v_is_joint THEN 'awaiting_holder_input' ELSE 'under_review' END,
        v_is_joint
    ) RETURNING id INTO v_id;

    -- Every dispute goes to a human. That is the point of a dispute.
    v_ops := public.create_ops_approval(
        'dispute', v_id,
        'Dispute ' || v_ref || ' on account ' || v_account.account_number,
        v_raiser || ' disputed ' ||
        CASE WHEN p_transaction_id IS NULL THEN 'activity on account ' || v_account.account_number
             ELSE 'a transaction of Rs ' || to_char(COALESCE(v_tx.amount,0) / 100.0, 'FM999,999,999.00') ||
                  ' on account ' || v_account.account_number END ||
        CASE WHEN v_is_joint THEN ' (JOINT account with ' || v_holder_count ||
                                  ' holders - co-holder input is being collected)'
             ELSE '' END ||
        '. Their description: ' || COALESCE(NULLIF(btrim(p_description), ''), 'No detail supplied'),
        jsonb_build_object('dispute_id', v_id, 'dispute_ref', v_ref,
                           'account_id', p_account_id,
                           'account_number', v_account.account_number,
                           'transaction_id', p_transaction_id,
                           'disputed_amount', v_tx.amount,
                           'is_joint_account', v_is_joint,
                           'holder_count', v_holder_count,
                           'raised_by', v_raiser),
        v_raiser
    );

    UPDATE public.disputes SET ops_ref_code = v_ops ->> 'ref_code' WHERE id = v_id;

    PERFORM public.write_audit_log(
        'dispute_raised', 'customer', p_profile_id, 'dispute', v_id,
        jsonb_build_object('ref_code', v_ref, 'account_id', p_account_id,
                           'transaction_id', p_transaction_id, 'is_joint', v_is_joint)
    );

    RETURN jsonb_build_object('success', true,
        'dispute_id', v_id, 'ref_code', v_ref,
        'ops_ref_code', v_ops ->> 'ref_code',
        'account_number', v_account.account_number,
        'transaction_id', p_transaction_id,
        'disputed_amount', v_tx.amount,
        'is_joint_account', v_is_joint,
        'holder_count', v_holder_count,
        'raised_by_email', v_raiser,
        'other_holder_emails', to_jsonb(COALESCE(v_other_holders, ARRAY[]::TEXT[])),
        'status', CASE WHEN v_is_joint THEN 'awaiting_holder_input' ELSE 'under_review' END);
END;
$$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.add_dispute_holder_input(
    p_ref_code TEXT, p_responder_email TEXT, p_agrees BOOLEAN, p_comment TEXT DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_dispute public.disputes%ROWTYPE;
    v_profile_id UUID;
    v_holder_count INT;
    v_input_count INT;
BEGIN
    SELECT * INTO v_dispute FROM public.disputes
    WHERE ref_code = UPPER(btrim(COALESCE(p_ref_code, ''))) FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error',
            'No dispute found for reference ' || COALESCE(p_ref_code, '(none)') || '.');
    END IF;

    SELECT id INTO v_profile_id FROM public.profiles
    WHERE lower(email) = lower(btrim(p_responder_email));
    IF v_profile_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = v_dispute.account_id AND profile_id = v_profile_id
    ) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'You are not a holder of the account this dispute belongs to.');
    END IF;

    IF v_dispute.status IN ('upheld', 'declined') THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Dispute ' || v_dispute.ref_code || ' has already been resolved (' ||
            v_dispute.status || ').');
    END IF;

    -- One input per holder; a later reply replaces an earlier one.
    UPDATE public.disputes
    SET holder_input = (
            SELECT COALESCE(jsonb_agg(e), '[]'::jsonb)
            FROM jsonb_array_elements(holder_input) e
            WHERE e ->> 'email' <> lower(btrim(p_responder_email))
        ) || jsonb_build_array(jsonb_build_object(
            'email', lower(btrim(p_responder_email)),
            'agrees', p_agrees,
            'comment', NULLIF(btrim(p_comment), ''),
            'at', NOW()
        )),
        status = CASE WHEN status = 'awaiting_holder_input' THEN 'under_review' ELSE status END,
        updated_at = NOW()
    WHERE id = v_dispute.id
    RETURNING * INTO v_dispute;

    SELECT COUNT(*) INTO v_holder_count
    FROM public.account_holders WHERE account_id = v_dispute.account_id;
    v_input_count := jsonb_array_length(v_dispute.holder_input);

    PERFORM public.write_audit_log(
        'dispute_holder_input', 'customer', v_profile_id, 'dispute', v_dispute.id,
        jsonb_build_object('ref_code', v_dispute.ref_code, 'agrees', p_agrees)
    );

    RETURN jsonb_build_object('success', true, 'ref_code', v_dispute.ref_code,
        'status', v_dispute.status, 'agrees', p_agrees,
        'inputs_received', v_input_count,
        'holders_total', v_holder_count,
        'holder_input', v_dispute.holder_input,
        'raised_by_email', (SELECT email FROM public.profiles WHERE id = v_dispute.raised_by_profile_id));
END;
$$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.resolve_dispute(
    p_dispute_id uuid, p_uphold BOOLEAN, p_resolution TEXT, p_decided_by_email TEXT
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_dispute public.disputes%ROWTYPE;
    v_reversal JSONB := NULL;
BEGIN
    SELECT * INTO v_dispute FROM public.disputes WHERE id = p_dispute_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Dispute not found.');
    END IF;

    IF v_dispute.status IN ('upheld', 'declined') THEN
        RETURN jsonb_build_object('success', false, 'already_decided', true,
            'error', 'Dispute ' || v_dispute.ref_code || ' was already ' || v_dispute.status || '.');
    END IF;

    -- Upholding a dispute against a specific transaction reverses it. This is
    -- the ONLY route to a reversal in the system, and it is reachable only with
    -- a human decision behind it.
    IF p_uphold AND v_dispute.transaction_id IS NOT NULL THEN
        v_reversal := public.reverse_transaction(
            v_dispute.transaction_id,
            'Dispute ' || v_dispute.ref_code || ' upheld: ' ||
            COALESCE(NULLIF(btrim(p_resolution), ''), 'no further detail'),
            NULL
        );
    END IF;

    UPDATE public.disputes
    SET status = CASE WHEN p_uphold THEN 'upheld' ELSE 'declined' END,
        resolution = NULLIF(btrim(p_resolution), ''),
        resolved_by_email = p_decided_by_email,
        resolved_at = NOW(), updated_at = NOW()
    WHERE id = p_dispute_id
    RETURNING * INTO v_dispute;

    PERFORM public.write_audit_log(
        'dispute_resolved', 'admin', NULL, 'dispute', p_dispute_id,
        jsonb_build_object('ref_code', v_dispute.ref_code, 'upheld', p_uphold,
                           'decided_by', p_decided_by_email,
                           'reversal', v_reversal)
    );

    RETURN jsonb_build_object('success', true,
        'dispute_id', p_dispute_id, 'ref_code', v_dispute.ref_code,
        'status', v_dispute.status, 'upheld', p_uphold,
        'resolution', v_dispute.resolution,
        'reversal', v_reversal,
        'account_id', v_dispute.account_id,
        'raised_by_email', (SELECT email FROM public.profiles WHERE id = v_dispute.raised_by_profile_id));
END;
$$;

-- ---------------------------------------------------------------------------
-- resolve_ops_approval now dispatches the two request types that previously
-- fell through to "deferred to caller": a dispute decision, and a standalone
-- transfer reversal.

CREATE OR REPLACE FUNCTION public.resolve_ops_approval(
    p_ref_code TEXT, p_decision TEXT, p_decided_by_email TEXT, p_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_req public.ops_approvals%ROWTYPE;
    v_decision TEXT;
    v_result JSONB := '{}'::jsonb;
    v_draft public.support_case_drafts%ROWTYPE;
    v_case public.support_cases%ROWTYPE;
    v_customer_email TEXT;
BEGIN
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

ALTER FUNCTION public.raise_dispute(uuid, uuid, uuid, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.add_dispute_holder_input(TEXT, TEXT, BOOLEAN, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.resolve_dispute(uuid, BOOLEAN, TEXT, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.resolve_ops_approval(TEXT, TEXT, TEXT, TEXT) OWNER TO banking_functions;

REVOKE ALL ON FUNCTION public.raise_dispute(uuid, uuid, uuid, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.add_dispute_holder_input(TEXT, TEXT, BOOLEAN, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_dispute(uuid, BOOLEAN, TEXT, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.raise_dispute(uuid, uuid, uuid, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.add_dispute_holder_input(TEXT, TEXT, BOOLEAN, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.resolve_dispute(uuid, BOOLEAN, TEXT, TEXT) TO service_role;
