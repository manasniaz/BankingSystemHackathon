-- 028_staff_enrolment_and_recipient_details.sql
--
-- Two additions.
--
-- 1. The person receiving money is told about it. Until now only the sender
--    heard anything, which is the wrong half: the sender already knows they
--    sent it.
--
-- 2. An address can join the operations team by sending a pass phrase, and the
--    team can change that phrase. The phrase is stored as a bcrypt hash, never
--    in plain text -- not in this file, not in the table, not in the repo.
--
-- A note on what this second feature is. A shared phrase that grants the power
-- to credit accounts is a real risk, so the obvious version of it is not the
-- version built here. Four things bound it:
--
--   * A customer address can never enrol. Someone who is both a customer and an
--     operator can credit their own account, which is the whole attack.
--   * Five wrong guesses per address per hour and that address is locked out.
--   * Every attempt, right or wrong, is recorded -- so a phrase being guessed
--     at looks like something rather than like nothing.
--   * Every existing operator is emailed the moment someone joins. A silent
--     privilege grant is the dangerous one; a loud one gets noticed.
--
-- The phrase can be rotated by any operator, which is what makes it survivable
-- if it leaks.

-- ---------------------------------------------------------------------------
-- 1. The pass phrase, hashed
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.staff_passphrase (
    id          BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    phrase_hash TEXT NOT NULL,
    updated_by  TEXT,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.staff_passphrase IS
    'Single row. bcrypt hash of the operations enrolment phrase. The plain text is never stored anywhere.';

CREATE TABLE IF NOT EXISTS public.staff_enrolment_attempts (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email        TEXT NOT NULL,
    succeeded    BOOLEAN NOT NULL,
    reason       TEXT,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_staff_enrolment_attempts_email
    ON public.staff_enrolment_attempts (lower(email), attempted_at DESC);

ALTER TABLE public.staff_passphrase ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_enrolment_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.staff_passphrase FROM PUBLIC;
REVOKE ALL ON public.staff_enrolment_attempts FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.staff_passphrase TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.staff_enrolment_attempts TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Who is staff, and which mailbox is the team's inbox
-- ---------------------------------------------------------------------------
-- The routing layer used to compare the sender against one hardcoded address,
-- which silently meant the team could only ever have one member. It asks the
-- database now, so a newly enrolled operator works immediately.

CREATE OR REPLACE FUNCTION public.staff_check(p_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_inbox TEXT;
    v_count INT;
BEGIN
    -- The oldest active operator address is the team inbox everything is sent
    -- to, so enrolling a second operator does not redirect the bank's mail.
    SELECT email INTO v_inbox FROM public.bank_staff
    WHERE is_active ORDER BY created_at LIMIT 1;

    SELECT COUNT(*) INTO v_count FROM public.bank_staff WHERE is_active;

    RETURN jsonb_build_object(
        'is_staff', public.is_bank_staff(p_email),
        'ops_inbox', v_inbox,
        'staff_count', v_count
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Joining the operations team
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
    v_staff TEXT[];
BEGIN
    IF v_email = '' OR v_email NOT LIKE '%@%' THEN
        RETURN jsonb_build_object('success', false, 'error', 'No sender address.');
    END IF;

    IF public.is_bank_staff(v_email) THEN
        RETURN jsonb_build_object('success', false, 'already_staff', true,
            'error', 'That address is already on the operations team.');
    END IF;

    -- Checked before the phrase is looked at, so guessing is walled off at the
    -- same point whether the guess was close or nonsense.
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

    -- The control that matters most. An operator can credit any account; a
    -- customer who is also an operator can credit their own.
    IF EXISTS (SELECT 1 FROM public.profiles WHERE lower(email) = v_email) THEN
        INSERT INTO public.staff_enrolment_attempts (email, succeeded, reason)
        VALUES (v_email, FALSE, 'is_customer');
        PERFORM public.write_audit_log(
            'staff_enrolment_refused_customer', 'system', NULL, 'bank_staff', NULL,
            jsonb_build_object('email', v_email));
        RETURN jsonb_build_object('success', false, 'is_customer', true,
            'error', 'That address is registered as a customer of this bank. '
                  || 'A customer cannot also be an operator, because an operator '
                  || 'can credit any account and that would include their own. '
                  || 'Use an address that holds no accounts here.');
    END IF;

    SELECT phrase_hash INTO v_hash FROM public.staff_passphrase WHERE id;
    IF v_hash IS NULL THEN
        RETURN jsonb_build_object('success', false, 'not_configured', true,
            'error', 'Operations enrolment is not configured.');
    END IF;

    v_ok := (extensions.crypt(COALESCE(p_phrase, ''), v_hash) = v_hash);

    INSERT INTO public.staff_enrolment_attempts (email, succeeded, reason)
    VALUES (v_email, v_ok, CASE WHEN v_ok THEN 'enrolled' ELSE 'wrong_phrase' END);

    IF NOT v_ok THEN
        PERFORM public.write_audit_log(
            'staff_enrolment_failed', 'system', NULL, 'bank_staff', NULL,
            jsonb_build_object('email', v_email,
                               'attempt', v_failures + 1, 'of_allowed', 5));
        RETURN jsonb_build_object('success', false, 'wrong_phrase', true,
            'attempts_remaining', 5 - (v_failures + 1),
            'error', 'That is not the operations pass phrase.');
    END IF;

    -- Captured before the insert so the new operator is not in their own
    -- notification list.
    SELECT array_agg(email ORDER BY created_at) INTO v_staff
    FROM public.bank_staff WHERE is_active;

    INSERT INTO public.bank_staff (email, role, note)
    VALUES (v_email, 'ops', 'Self-enrolled with the operations pass phrase')
    ON CONFLICT (email) DO UPDATE SET is_active = TRUE;

    PERFORM public.write_audit_log(
        'staff_enrolled', 'admin', NULL, 'bank_staff', NULL,
        jsonb_build_object('email', v_email, 'method', 'passphrase'));

    RETURN jsonb_build_object(
        'success', true, 'email', v_email,
        'existing_staff', to_jsonb(COALESCE(v_staff, ARRAY[]::TEXT[]))
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Rotating the phrase
-- ---------------------------------------------------------------------------
-- Any active operator can change it, and everyone is told. Rotation is the
-- thing that makes a shared secret survivable, so it must not need a developer.

CREATE OR REPLACE FUNCTION public.change_staff_passphrase(
    p_operator_email TEXT,
    p_new_phrase TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_phrase TEXT := trim(COALESCE(p_new_phrase, ''));
    v_staff TEXT[];
BEGIN
    IF NOT public.is_bank_staff(p_operator_email) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Only the operations team can change the pass phrase.');
    END IF;

    IF length(v_phrase) < 8 THEN
        RETURN jsonb_build_object('success', false, 'error',
            'The new pass phrase must be at least 8 characters.');
    END IF;

    INSERT INTO public.staff_passphrase (id, phrase_hash, updated_by, updated_at)
    VALUES (TRUE, extensions.crypt(v_phrase, extensions.gen_salt('bf')),
            lower(trim(p_operator_email)), NOW())
    ON CONFLICT (id) DO UPDATE
        SET phrase_hash = EXCLUDED.phrase_hash,
            updated_by = EXCLUDED.updated_by,
            updated_at = NOW();

    -- A changed phrase locks out anyone mid-guess, so the counter is cleared
    -- rather than leaving honest operators serving someone else's lockout.
    DELETE FROM public.staff_enrolment_attempts
    WHERE NOT succeeded AND attempted_at > NOW() - INTERVAL '1 hour';

    SELECT array_agg(email ORDER BY created_at) INTO v_staff
    FROM public.bank_staff WHERE is_active;

    PERFORM public.write_audit_log(
        'staff_passphrase_changed', 'admin', NULL, 'staff_passphrase', NULL,
        jsonb_build_object('changed_by', lower(trim(p_operator_email))));

    RETURN jsonb_build_object('success', true,
        'changed_by', lower(trim(p_operator_email)),
        'existing_staff', to_jsonb(COALESCE(v_staff, ARRAY[]::TEXT[])));
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Destination lookup now names the people who will be paid
-- ---------------------------------------------------------------------------
-- Same resolution rules as before; it just also returns the holder addresses,
-- so the recipient can be told money arrived.

CREATE OR REPLACE FUNCTION public.resolve_destination_account(p_lookup TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_lookup TEXT := trim(COALESCE(p_lookup, ''));
    v_account public.accounts%ROWTYPE;
    v_count INT;
    v_numbers TEXT[];
    v_holders TEXT[];
BEGIN
    IF v_lookup = '' THEN
        RETURN jsonb_build_object('found', false, 'reason', 'no_lookup');
    END IF;

    IF v_lookup LIKE '%@%' THEN
        IF public.is_bank_staff(v_lookup) THEN
            RETURN jsonb_build_object('found', false, 'reason', 'staff_address');
        END IF;

        SELECT COUNT(*), array_agg(a.account_number ORDER BY a.created_at)
        INTO v_count, v_numbers
        FROM public.accounts a
        JOIN public.account_holders ah ON ah.account_id = a.id
        JOIN public.profiles p ON p.id = ah.profile_id
        WHERE lower(p.email) = lower(v_lookup) AND a.status = 'active';

        IF v_count = 0 THEN
            RETURN jsonb_build_object('found', false, 'reason', 'no_such_recipient');
        END IF;

        IF v_count > 1 THEN
            RETURN jsonb_build_object(
                'found', false, 'reason', 'ambiguous_recipient',
                'candidates', to_jsonb(v_numbers)
            );
        END IF;

        SELECT a.* INTO v_account
        FROM public.accounts a
        JOIN public.account_holders ah ON ah.account_id = a.id
        JOIN public.profiles p ON p.id = ah.profile_id
        WHERE lower(p.email) = lower(v_lookup) AND a.status = 'active'
        LIMIT 1;
    ELSE
        SELECT * INTO v_account FROM public.accounts
        WHERE upper(account_number) = upper(v_lookup);

        IF v_account.id IS NULL THEN
            BEGIN
                SELECT * INTO v_account FROM public.accounts WHERE id = v_lookup::uuid;
            EXCEPTION WHEN invalid_text_representation THEN
                v_account := NULL;
            END;
        END IF;

        IF v_account.id IS NULL THEN
            RETURN jsonb_build_object('found', false, 'reason', 'no_such_account');
        END IF;
    END IF;

    SELECT array_agg(p.email ORDER BY ah.created_at) INTO v_holders
    FROM public.account_holders ah
    JOIN public.profiles p ON p.id = ah.profile_id
    WHERE ah.account_id = v_account.id;

    RETURN jsonb_build_object(
        'found', true,
        'id', v_account.id,
        'account_id', v_account.id,
        'account_number', v_account.account_number,
        'currency', v_account.currency,
        'status', v_account.status,
        'holder_emails', to_jsonb(COALESCE(v_holders, ARRAY[]::TEXT[]))
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Permissions
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.staff_check(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enrol_bank_staff(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.change_staff_passphrase(TEXT, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.staff_check(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.enrol_bank_staff(TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.change_staff_passphrase(TEXT, TEXT) TO service_role;
