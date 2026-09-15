-- 013: co-holders approve or decline a pending joint action (both-signature
-- transfer, closure, add-holder) by replying to the bank with a short ref code.
-- A UUID is too long to survive a human email round-trip; JNT-XXXXXXXX is not.
--
-- NOTE: respond_to_joint_action_by_ref() is dropped and redefined with a fourth
-- argument in 014. This file is kept as applied.

ALTER TABLE public.joint_account_actions
    ADD COLUMN IF NOT EXISTS ref_code TEXT;

UPDATE public.joint_account_actions
SET ref_code = 'JNT-' || UPPER(SUBSTRING(REPLACE(id::text, '-', '') FROM 1 FOR 8))
WHERE ref_code IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_joint_actions_ref_code
    ON public.joint_account_actions (ref_code);

CREATE OR REPLACE FUNCTION public.assign_joint_action_ref_code()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_ref TEXT; v_attempt INT := 0;
BEGIN
    IF NEW.ref_code IS NOT NULL THEN RETURN NEW; END IF;
    LOOP
        v_attempt := v_attempt + 1;
        v_ref := 'JNT-' || UPPER(SUBSTRING(REPLACE(gen_random_uuid()::text, '-', '') FROM 1 FOR 8));
        EXIT WHEN NOT EXISTS (SELECT 1 FROM public.joint_account_actions WHERE ref_code = v_ref);
        IF v_attempt > 10 THEN RAISE EXCEPTION 'Could not allocate a joint action ref code'; END IF;
    END LOOP;
    NEW.ref_code := v_ref;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_joint_action_ref_code ON public.joint_account_actions;
CREATE TRIGGER trg_joint_action_ref_code
    BEFORE INSERT ON public.joint_account_actions
    FOR EACH ROW EXECUTE FUNCTION public.assign_joint_action_ref_code();

ALTER TABLE public.joint_account_actions ALTER COLUMN ref_code SET NOT NULL;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.respond_to_joint_action_by_ref(
    p_ref_code TEXT, p_responder_email TEXT, p_accept BOOLEAN
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
    WHERE ref_code = UPPER(btrim(COALESCE(p_ref_code, '')));

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
        'ref_code', v_action.ref_code,
        'action_type', v_action.action_type,
        'account_id', v_action.account_id,
        'account_number', v_account.account_number,
        'payload', v_action.payload,
        'responder_email', lower(btrim(p_responder_email)),
        'requester_email', (SELECT email FROM public.profiles WHERE id = v_action.requested_by_profile_id),
        'pending_holder_emails', to_jsonb(COALESCE(v_pending_emails, ARRAY[]::TEXT[]))
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- Return every joint action a holder still has to sign, so WF-00 can chase them.

CREATE OR REPLACE FUNCTION public.list_pending_joint_actions_for_email(p_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_rows JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'ref_code', ja.ref_code, 'action_type', ja.action_type,
        'account_number', a.account_number, 'payload', ja.payload,
        'expires_at', ja.expires_at,
        'requested_by', rp.email
    ) ORDER BY ja.created_at), '[]'::jsonb)
    INTO v_rows
    FROM public.joint_account_actions ja
    JOIN public.accounts a ON a.id = ja.account_id
    JOIN public.account_holders ah ON ah.account_id = ja.account_id
    JOIN public.profiles p ON p.id = ah.profile_id
    LEFT JOIN public.profiles rp ON rp.id = ja.requested_by_profile_id
    WHERE lower(p.email) = lower(btrim(p_email))
      AND ja.status = 'pending' AND ja.expires_at > NOW()
      AND NOT EXISTS (
          SELECT 1 FROM public.joint_account_consents c
          WHERE c.joint_action_id = ja.id AND c.profile_id = p.id AND c.consent
      );

    RETURN jsonb_build_object('success', true, 'pending', v_rows,
                              'pending_count', jsonb_array_length(v_rows));
END;
$$;

ALTER FUNCTION public.respond_to_joint_action_by_ref(TEXT, TEXT, BOOLEAN) OWNER TO banking_functions;
ALTER FUNCTION public.list_pending_joint_actions_for_email(TEXT) OWNER TO banking_functions;
REVOKE ALL ON FUNCTION public.respond_to_joint_action_by_ref(TEXT, TEXT, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_pending_joint_actions_for_email(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.respond_to_joint_action_by_ref(TEXT, TEXT, BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.list_pending_joint_actions_for_email(TEXT) TO service_role;
