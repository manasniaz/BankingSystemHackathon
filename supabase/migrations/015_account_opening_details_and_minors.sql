-- 015: real account opening. Date of birth is captured and stored, an applicant
-- under 18 cannot open an account alone, and a minor account is created only once
-- the named guardian has consented by email. Also adds the mandate column that
-- 016 uses to let a joint account be opened either-or or all-signatures.
--
-- The minor/guardian *schema* (account_holders.holder_type, guardian_of_profile_id,
-- profiles.date_of_birth, promote_minors_to_adult) already existed from 004/005 --
-- what was missing was any way for a real customer to reach it, because nothing
-- ever asked for a date of birth.

ALTER TABLE public.joint_account_invitations
    ADD COLUMN IF NOT EXISTS authority_model TEXT NOT NULL DEFAULT 'either_or';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'joint_invitations_authority_model_check') THEN
        ALTER TABLE public.joint_account_invitations
            ADD CONSTRAINT joint_invitations_authority_model_check
            CHECK (authority_model IN ('either_or', 'all_signatures'));
    END IF;
END $$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_profile_details(
    p_profile_id UUID, p_date_of_birth DATE DEFAULT NULL, p_phone_number TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_profile public.profiles%ROWTYPE;
BEGIN
    IF p_date_of_birth IS NOT NULL THEN
        IF p_date_of_birth > CURRENT_DATE THEN
            RETURN jsonb_build_object('success', false, 'error', 'Date of birth cannot be in the future.');
        END IF;
        IF p_date_of_birth < CURRENT_DATE - INTERVAL '120 years' THEN
            RETURN jsonb_build_object('success', false, 'error', 'That date of birth is not plausible.');
        END IF;
    END IF;

    UPDATE public.profiles
    SET date_of_birth = COALESCE(p_date_of_birth, date_of_birth),
        phone_number  = COALESCE(NULLIF(btrim(p_phone_number), ''), phone_number),
        updated_at = NOW()
    WHERE id = p_profile_id
    RETURNING * INTO v_profile;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Profile not found.');
    END IF;

    RETURN jsonb_build_object('success', true, 'profile_id', v_profile.id,
        'date_of_birth', v_profile.date_of_birth, 'phone_number', v_profile.phone_number,
        'age_years', CASE WHEN v_profile.date_of_birth IS NULL THEN NULL
                          ELSE EXTRACT(YEAR FROM age(v_profile.date_of_birth))::INT END);
END;
$$;

-- ---------------------------------------------------------------------------
-- Single entry point for opening an account for someone who gave us their details.

CREATE OR REPLACE FUNCTION public.open_account_with_details(
    p_profile_id UUID,
    p_account_type TEXT DEFAULT 'checking',
    p_currency TEXT DEFAULT 'PKR',
    p_date_of_birth DATE DEFAULT NULL,
    p_phone_number TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_profile public.profiles%ROWTYPE;
    v_dob DATE;
    v_age INT;
    v_details JSONB;
BEGIN
    SELECT * INTO v_profile FROM public.profiles WHERE id = p_profile_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Profile not found.');
    END IF;

    IF p_account_type NOT IN ('checking','savings','business') THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Account type must be checking, savings or business.');
    END IF;

    IF p_date_of_birth IS NOT NULL THEN
        v_details := public.set_profile_details(p_profile_id, p_date_of_birth, p_phone_number);
        IF NOT COALESCE((v_details ->> 'success')::boolean, false) THEN
            RETURN v_details;
        END IF;
    ELSIF p_phone_number IS NOT NULL THEN
        PERFORM public.set_profile_details(p_profile_id, NULL, p_phone_number);
    END IF;

    SELECT date_of_birth INTO v_dob FROM public.profiles WHERE id = p_profile_id;

    IF v_dob IS NULL THEN
        RETURN jsonb_build_object('success', false, 'needs_date_of_birth', true,
            'error', 'We need your date of birth before we can open an account.');
    END IF;

    v_age := EXTRACT(YEAR FROM age(v_dob))::INT;

    IF v_age < 18 THEN
        RETURN jsonb_build_object('success', false, 'age_restricted', true, 'age_years', v_age,
            'error', 'An applicant under 18 cannot open an account on their own. ' ||
                     'A parent or guardian must consent first.');
    END IF;

    RETURN public.open_account_for_profile(p_profile_id, p_account_type, p_currency, 'adult', NULL)
           || jsonb_build_object('age_years', v_age);
END;
$$;

-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.minor_account_requests (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ref_code            TEXT NOT NULL UNIQUE,
    applicant_email     TEXT NOT NULL,
    applicant_name      TEXT NOT NULL,
    date_of_birth       DATE NOT NULL,
    guardian_email      TEXT NOT NULL,
    guardian_name       TEXT,
    account_type        TEXT NOT NULL DEFAULT 'savings',
    currency            TEXT NOT NULL DEFAULT 'PKR',
    status              TEXT NOT NULL DEFAULT 'pending_guardian'
                            CHECK (status IN ('pending_guardian','guardian_approved',
                                              'guardian_rejected','completed','expired')),
    account_id          UUID REFERENCES public.accounts(id),
    minor_profile_id    UUID REFERENCES public.profiles(id),
    guardian_profile_id UUID REFERENCES public.profiles(id),
    expires_at          TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_minor_requests_status ON public.minor_account_requests (status, expires_at);

ALTER TABLE public.minor_account_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS minor_requests_deny_anon ON public.minor_account_requests;
CREATE POLICY minor_requests_deny_anon ON public.minor_account_requests
    FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.request_minor_account(
    p_applicant_email TEXT, p_applicant_name TEXT, p_date_of_birth DATE,
    p_guardian_email TEXT, p_account_type TEXT DEFAULT 'savings', p_currency TEXT DEFAULT 'PKR'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_ref TEXT; v_id UUID; v_age INT; v_attempt INT := 0;
    v_guardian_profile public.profiles%ROWTYPE;
BEGIN
    IF p_applicant_email IS NULL OR p_guardian_email IS NULL OR p_date_of_birth IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Applicant email, guardian email and date of birth are all required.');
    END IF;

    IF lower(btrim(p_applicant_email)) = lower(btrim(p_guardian_email)) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'The guardian must be a different person from the applicant.');
    END IF;

    IF p_date_of_birth > CURRENT_DATE THEN
        RETURN jsonb_build_object('success', false, 'error', 'Date of birth cannot be in the future.');
    END IF;

    v_age := EXTRACT(YEAR FROM age(p_date_of_birth))::INT;
    IF v_age >= 18 THEN
        RETURN jsonb_build_object('success', false, 'error',
            'This applicant is ' || v_age || ' and can open an account directly; no guardian is needed.');
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.minor_account_requests
        WHERE lower(applicant_email) = lower(btrim(p_applicant_email))
          AND status = 'pending_guardian' AND expires_at > NOW()
    ) THEN
        SELECT ref_code INTO v_ref FROM public.minor_account_requests
        WHERE lower(applicant_email) = lower(btrim(p_applicant_email))
          AND status = 'pending_guardian' AND expires_at > NOW() LIMIT 1;
        RETURN jsonb_build_object('success', true, 'reused', true, 'ref_code', v_ref,
            'guardian_email', lower(btrim(p_guardian_email)), 'age_years', v_age);
    END IF;

    LOOP
        v_attempt := v_attempt + 1;
        v_ref := 'MIN-' || UPPER(SUBSTRING(REPLACE(gen_random_uuid()::text, '-', '') FROM 1 FOR 8));
        EXIT WHEN NOT EXISTS (SELECT 1 FROM public.minor_account_requests WHERE ref_code = v_ref);
        IF v_attempt > 10 THEN RAISE EXCEPTION 'Could not allocate a minor request ref code'; END IF;
    END LOOP;

    SELECT * INTO v_guardian_profile FROM public.profiles
    WHERE lower(email) = lower(btrim(p_guardian_email));

    INSERT INTO public.minor_account_requests (
        ref_code, applicant_email, applicant_name, date_of_birth,
        guardian_email, guardian_name, account_type, currency, guardian_profile_id
    ) VALUES (
        v_ref, lower(btrim(p_applicant_email)), btrim(p_applicant_name), p_date_of_birth,
        lower(btrim(p_guardian_email)), v_guardian_profile.full_name,
        COALESCE(p_account_type, 'savings'), COALESCE(p_currency, 'PKR'), v_guardian_profile.id
    ) RETURNING id INTO v_id;

    PERFORM public.write_audit_log(
        'minor_account_requested', 'customer', NULL, 'minor_account_request', v_id,
        jsonb_build_object('ref_code', v_ref, 'applicant_email', lower(btrim(p_applicant_email)),
                           'guardian_email', lower(btrim(p_guardian_email)), 'age_years', v_age)
    );

    RETURN jsonb_build_object('success', true, 'reused', false, 'ref_code', v_ref,
        'request_id', v_id, 'age_years', v_age,
        'applicant_email', lower(btrim(p_applicant_email)),
        'applicant_name', btrim(p_applicant_name),
        'guardian_email', lower(btrim(p_guardian_email)),
        'guardian_is_existing_customer', v_guardian_profile.id IS NOT NULL,
        'expires_at', (SELECT expires_at FROM public.minor_account_requests WHERE id = v_id));
END;
$$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.respond_to_minor_account_request(
    p_ref_code TEXT, p_responder_email TEXT, p_accept BOOLEAN
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_req public.minor_account_requests%ROWTYPE;
    v_minor_profile_id UUID;
BEGIN
    SELECT * INTO v_req FROM public.minor_account_requests
    WHERE ref_code = UPPER(btrim(COALESCE(p_ref_code, ''))) FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error',
            'No guardian request found for reference ' || COALESCE(p_ref_code, '(none)') || '.');
    END IF;

    -- Only the named guardian may answer, and only from their own address.
    IF lower(btrim(p_responder_email)) <> lower(v_req.guardian_email) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'This guardian consent request was not addressed to your email address.');
    END IF;

    IF v_req.status <> 'pending_guardian' THEN
        RETURN jsonb_build_object('success', false, 'already_decided', true,
            'error', 'Request ' || v_req.ref_code || ' was already ' || v_req.status || '.',
            'ref_code', v_req.ref_code, 'status', v_req.status);
    END IF;

    IF v_req.expires_at <= NOW() THEN
        UPDATE public.minor_account_requests SET status = 'expired', updated_at = NOW() WHERE id = v_req.id;
        RETURN jsonb_build_object('success', false, 'error',
            'Request ' || v_req.ref_code || ' expired on ' ||
            to_char(v_req.expires_at, 'YYYY-MM-DD') || '.', 'status', 'expired');
    END IF;

    UPDATE public.minor_account_requests
    SET status = CASE WHEN p_accept THEN 'guardian_approved' ELSE 'guardian_rejected' END,
        updated_at = NOW()
    WHERE id = v_req.id RETURNING * INTO v_req;

    PERFORM public.write_audit_log(
        CASE WHEN p_accept THEN 'minor_account_guardian_approved' ELSE 'minor_account_guardian_rejected' END,
        'customer', v_req.guardian_profile_id, 'minor_account_request', v_req.id,
        jsonb_build_object('ref_code', v_req.ref_code)
    );

    SELECT id INTO v_minor_profile_id FROM public.profiles
    WHERE lower(email) = lower(v_req.applicant_email);

    RETURN jsonb_build_object(
        'success', true, 'ref_code', v_req.ref_code, 'status', v_req.status,
        'accepted', p_accept,
        'applicant_email', v_req.applicant_email, 'applicant_name', v_req.applicant_name,
        'date_of_birth', v_req.date_of_birth,
        'guardian_email', v_req.guardian_email,
        'account_type', v_req.account_type, 'currency', v_req.currency,
        'minor_profile_id', v_minor_profile_id,
        'guardian_profile_id', v_req.guardian_profile_id,
        'minor_needs_profile', v_minor_profile_id IS NULL,
        'guardian_needs_profile', v_req.guardian_profile_id IS NULL
    );
END;
$$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.finalize_minor_account_request(
    p_ref_code TEXT, p_minor_profile_id UUID, p_guardian_profile_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_req public.minor_account_requests%ROWTYPE;
    v_opened JSONB;
BEGIN
    SELECT * INTO v_req FROM public.minor_account_requests
    WHERE ref_code = UPPER(btrim(COALESCE(p_ref_code, ''))) FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Request not found.');
    END IF;

    IF v_req.status = 'completed' THEN
        RETURN jsonb_build_object('success', true, 'already_completed', true,
            'account_id', v_req.account_id, 'ref_code', v_req.ref_code);
    END IF;

    IF v_req.status <> 'guardian_approved' THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Request ' || v_req.ref_code || ' is ' || v_req.status ||
            ', not approved by the guardian.');
    END IF;

    IF p_minor_profile_id IS NULL OR p_guardian_profile_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Both the minor and the guardian must have a profile before the account can be opened.');
    END IF;

    PERFORM public.set_profile_details(p_minor_profile_id, v_req.date_of_birth, NULL);

    v_opened := public.open_account_for_profile(
        p_minor_profile_id, v_req.account_type, v_req.currency, 'minor', p_guardian_profile_id
    );

    IF NOT COALESCE((v_opened ->> 'success')::boolean, false) THEN
        RETURN v_opened;
    END IF;

    UPDATE public.minor_account_requests
    SET status = 'completed', account_id = (v_opened ->> 'account_id')::UUID,
        minor_profile_id = p_minor_profile_id, guardian_profile_id = p_guardian_profile_id,
        updated_at = NOW()
    WHERE id = v_req.id;

    PERFORM public.write_audit_log(
        'minor_account_opened', 'system', NULL, 'minor_account_request', v_req.id,
        jsonb_build_object('ref_code', v_req.ref_code, 'account_id', v_opened ->> 'account_id',
                           'minor_profile_id', p_minor_profile_id,
                           'guardian_profile_id', p_guardian_profile_id)
    );

    RETURN v_opened || jsonb_build_object(
        'ref_code', v_req.ref_code,
        'applicant_email', v_req.applicant_email, 'applicant_name', v_req.applicant_name,
        'guardian_email', v_req.guardian_email,
        'turns_18_on', (v_req.date_of_birth + INTERVAL '18 years')::DATE
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.expire_stale_minor_account_requests()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_count INT;
BEGIN
    WITH expired AS (
        UPDATE public.minor_account_requests SET status = 'expired', updated_at = NOW()
        WHERE status = 'pending_guardian' AND expires_at <= NOW()
        RETURNING id
    ) SELECT COUNT(*) INTO v_count FROM expired;
    RETURN jsonb_build_object('success', true, 'expired_count', v_count);
END;
$$;

-- ---------------------------------------------------------------------------

ALTER FUNCTION public.set_profile_details(UUID, DATE, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.open_account_with_details(UUID, TEXT, TEXT, DATE, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.request_minor_account(TEXT, TEXT, DATE, TEXT, TEXT, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.respond_to_minor_account_request(TEXT, TEXT, BOOLEAN) OWNER TO banking_functions;
ALTER FUNCTION public.finalize_minor_account_request(TEXT, UUID, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.expire_stale_minor_account_requests() OWNER TO banking_functions;

REVOKE ALL ON FUNCTION public.set_profile_details(UUID, DATE, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.open_account_with_details(UUID, TEXT, TEXT, DATE, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_minor_account(TEXT, TEXT, DATE, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.respond_to_minor_account_request(TEXT, TEXT, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.finalize_minor_account_request(TEXT, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.expire_stale_minor_account_requests() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.set_profile_details(UUID, DATE, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.open_account_with_details(UUID, TEXT, TEXT, DATE, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.request_minor_account(TEXT, TEXT, DATE, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.respond_to_minor_account_request(TEXT, TEXT, BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_minor_account_request(TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.expire_stale_minor_account_requests() TO service_role;
