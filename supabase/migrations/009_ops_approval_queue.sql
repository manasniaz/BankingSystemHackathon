-- 009: Generic ops approval queue driven by email round-trip.
-- Every request needing a human decision becomes an ops_approvals row with a short
-- ref_code. The ops mailbox receives the ref_code, replies APPROVE/REJECT, and
-- WF-00 calls resolve_ops_approval(), which dispatches to the real RPC.
--
-- NOTE: resolve_ops_approval() as defined here writes audit_log.actor_type =
-- 'operator', which the CHECK constraint rejects. Migration 011 replaces the
-- whole function with the corrected version ('admin'). This file is kept as
-- applied so the migration history replays exactly.

CREATE TABLE IF NOT EXISTS public.ops_approvals (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ref_code           TEXT NOT NULL UNIQUE,
    request_type       TEXT NOT NULL CHECK (request_type IN (
                           'loan', 'support_draft', 'minor_account',
                           'fraud_hold_release', 'transfer_reversal', 'remove_holder')),
    target_id          UUID,
    status             TEXT NOT NULL DEFAULT 'pending'
                           CHECK (status IN ('pending','approved','rejected','expired','failed')),
    subject            TEXT NOT NULL,
    summary            TEXT NOT NULL,
    payload            JSONB NOT NULL DEFAULT '{}'::jsonb,
    requested_for_email TEXT,
    decided_by_email   TEXT,
    decision_note      TEXT,
    decision_result    JSONB,
    expires_at         TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    decided_at         TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_ops_approvals_status ON public.ops_approvals (status, expires_at);
CREATE INDEX IF NOT EXISTS idx_ops_approvals_target ON public.ops_approvals (request_type, target_id);

ALTER TABLE public.ops_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ops_approvals_deny_anon ON public.ops_approvals;
CREATE POLICY ops_approvals_deny_anon ON public.ops_approvals
    FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_ops_approval(
    p_request_type TEXT,
    p_target_id UUID,
    p_subject TEXT,
    p_summary TEXT,
    p_payload JSONB DEFAULT '{}'::jsonb,
    p_requested_for_email TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_ref TEXT;
    v_id UUID;
    v_attempt INT := 0;
BEGIN
    IF p_subject IS NULL OR btrim(p_subject) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'A subject is required');
    END IF;

    -- Reuse an already-open request for the same target instead of creating a duplicate.
    SELECT id, ref_code INTO v_id, v_ref
    FROM public.ops_approvals
    WHERE request_type = p_request_type AND target_id IS NOT DISTINCT FROM p_target_id
      AND status = 'pending' AND expires_at > NOW()
    LIMIT 1;

    IF v_id IS NOT NULL THEN
        RETURN jsonb_build_object('success', true, 'ref_code', v_ref,
                                  'ops_approval_id', v_id, 'reused', true);
    END IF;

    LOOP
        v_attempt := v_attempt + 1;
        v_ref := 'OPS-' || UPPER(SUBSTRING(REPLACE(gen_random_uuid()::text, '-', '') FROM 1 FOR 8));
        EXIT WHEN NOT EXISTS (SELECT 1 FROM public.ops_approvals WHERE ref_code = v_ref);
        IF v_attempt > 10 THEN
            RAISE EXCEPTION 'Could not allocate a unique ops approval ref code';
        END IF;
    END LOOP;

    INSERT INTO public.ops_approvals (
        ref_code, request_type, target_id, subject, summary, payload, requested_for_email
    ) VALUES (
        v_ref, p_request_type, p_target_id, p_subject, p_summary,
        COALESCE(p_payload, '{}'::jsonb), p_requested_for_email
    ) RETURNING id INTO v_id;

    PERFORM public.write_audit_log(
        'ops_approval_requested', 'system', NULL, 'ops_approval', v_id,
        jsonb_build_object('ref_code', v_ref, 'request_type', p_request_type, 'target_id', p_target_id)
    );

    RETURN jsonb_build_object('success', true, 'ref_code', v_ref,
                              'ops_approval_id', v_id, 'reused', false);
END;
$$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.resolve_ops_approval(
    p_ref_code TEXT,
    p_decision TEXT,
    p_decided_by_email TEXT,
    p_note TEXT DEFAULT NULL
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
        RETURN jsonb_build_object('success', false, 'error',
            'Decision must be APPROVE or REJECT.');
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
            'ref_code', v_req.ref_code, 'status', v_req.status,
            'request_type', v_req.request_type);
    END IF;

    IF v_req.expires_at <= NOW() THEN
        UPDATE public.ops_approvals SET status = 'expired', updated_at = NOW() WHERE id = v_req.id;
        RETURN jsonb_build_object('success', false, 'error',
            'Request ' || v_req.ref_code || ' expired on ' || to_char(v_req.expires_at, 'YYYY-MM-DD') || '.',
            'ref_code', v_req.ref_code, 'status', 'expired');
    END IF;

    -- Dispatch -------------------------------------------------------------
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
                WHERE id = v_draft.id
                RETURNING * INTO v_draft;
                UPDATE public.support_cases
                SET status = 'resolved', final_sent_response = v_draft.groq_draft, updated_at = NOW()
                WHERE id = v_case.id;
            ELSE
                UPDATE public.support_case_drafts
                SET human_review_state = 'rejected', updated_at = NOW() WHERE id = v_draft.id;
                UPDATE public.support_cases
                SET status = 'closed', updated_at = NOW() WHERE id = v_case.id;
            END IF;
            v_result := jsonb_build_object('success', true,
                'support_case_id', v_case.id, 'answer_text', v_draft.groq_draft,
                'case_subject', v_case.subject);
            v_customer_email := COALESCE(v_case.customer_email,
                (SELECT email FROM public.profiles WHERE id = v_case.profile_id));
        END IF;

    ELSIF v_req.request_type = 'fraud_hold_release' THEN
        IF v_decision = 'approve' THEN
            v_result := jsonb_build_object('success', true,
                'released', public.release_account_hold(v_req.target_id, NULL));
        ELSE
            v_result := jsonb_build_object('success', true, 'released', false,
                'note', 'Hold left in place by ops decision.');
        END IF;
        v_customer_email := v_req.requested_for_email;

    ELSE
        -- minor_account / transfer_reversal / remove_holder are finalised by the
        -- caller (they need steps outside the database, e.g. auth-user creation).
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
        decided_at = NOW(),
        updated_at = NOW()
    WHERE id = v_req.id
    RETURNING * INTO v_req;

    PERFORM public.write_audit_log(
        'ops_approval_resolved', 'operator', NULL, 'ops_approval', v_req.id,
        jsonb_build_object('ref_code', v_req.ref_code, 'decision', v_decision,
                           'request_type', v_req.request_type, 'decided_by', p_decided_by_email,
                           'status', v_req.status)
    );

    RETURN jsonb_build_object(
        'success', COALESCE((v_result ->> 'success')::boolean, true),
        'ref_code', v_req.ref_code,
        'request_type', v_req.request_type,
        'target_id', v_req.target_id,
        'decision', v_decision,
        'status', v_req.status,
        'subject', v_req.subject,
        'summary', v_req.summary,
        'payload', v_req.payload,
        'customer_email', COALESCE(v_customer_email, v_req.requested_for_email),
        'decision_note', v_req.decision_note,
        'result', v_result
    );
END;
$$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.expire_stale_ops_approvals()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_count INT;
BEGIN
    WITH expired AS (
        UPDATE public.ops_approvals SET status = 'expired', updated_at = NOW()
        WHERE status = 'pending' AND expires_at <= NOW()
        RETURNING id
    ) SELECT COUNT(*) INTO v_count FROM expired;
    RETURN jsonb_build_object('success', true, 'expired_count', v_count);
END;
$$;

-- ---------------------------------------------------------------------------

ALTER FUNCTION public.create_ops_approval(TEXT, UUID, TEXT, TEXT, JSONB, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.resolve_ops_approval(TEXT, TEXT, TEXT, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.expire_stale_ops_approvals() OWNER TO banking_functions;

REVOKE ALL ON FUNCTION public.create_ops_approval(TEXT, UUID, TEXT, TEXT, JSONB, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_ops_approval(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.expire_stale_ops_approvals() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_ops_approval(TEXT, UUID, TEXT, TEXT, JSONB, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.resolve_ops_approval(TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.expire_stale_ops_approvals() TO service_role;
