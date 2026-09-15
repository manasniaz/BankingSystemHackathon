-- =============================================================================
-- MIGRATION: 005_pkr_currency_joint_invitations_public_rag.sql
-- DESCRIPTION:
--   1. Switches the system's default/active currency to PKR (Pakistani Rupees).
--      The BIGINT minor-unit representation is unchanged -- paisa (1 PKR = 100
--      paisa) map onto the same integer-minor-unit column design used for USD,
--      so no column types change, only the currency code and existing rows.
--   2. Joint account invitations: Person A invites Person B by email; a 5-minute
--      window to accept/reject; idempotent against duplicate responses; a sweep
--      function expires stale invitations and reports them for notification.
--   3. Public (non-customer) RAG support: support_cases no longer requires a
--      bank profile_id -- anyone can ask a policy question, identified by email,
--      and is recognized as a "returning" inquirer within a short window.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. PKR AS THE SYSTEM CURRENCY
-- -----------------------------------------------------------------------------

ALTER TABLE public.accounts ALTER COLUMN currency SET DEFAULT 'PKR';
UPDATE public.accounts SET currency = 'PKR' WHERE currency = 'USD';

ALTER TABLE public.standing_orders ALTER COLUMN currency SET DEFAULT 'PKR';
UPDATE public.standing_orders SET currency = 'PKR' WHERE currency = 'USD';

ALTER TABLE public.transactions ALTER COLUMN currency SET DEFAULT 'PKR';
UPDATE public.transactions SET currency = 'PKR' WHERE currency = 'USD';

-- -----------------------------------------------------------------------------
-- 2. JOINT ACCOUNT INVITATIONS
-- -----------------------------------------------------------------------------

CREATE TABLE public.joint_account_invitations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    inviter_profile_id UUID NOT NULL REFERENCES public.profiles(id),
    invitee_email TEXT NOT NULL,
    account_type TEXT NOT NULL DEFAULT 'checking' CHECK (account_type IN ('checking', 'savings', 'joint', 'business')),
    currency TEXT NOT NULL DEFAULT 'PKR',
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'rejected', 'expired')),
    account_id UUID REFERENCES public.accounts(id),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '5 minutes'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_joint_invitations_invitee_email ON public.joint_account_invitations(invitee_email);
CREATE INDEX idx_joint_invitations_status_expiry ON public.joint_account_invitations(status, expires_at);

-- New tables aren't covered by 001's one-time "GRANT ALL ON ALL TABLES" snapshot,
-- so banking_functions needs an explicit grant here (and ALTER DEFAULT PRIVILEGES
-- so future migrations don't hit this same gap).
GRANT ALL PRIVILEGES ON TABLE public.joint_account_invitations TO banking_functions;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO banking_functions;

ALTER TABLE public.joint_account_invitations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "deny_all_client_access" ON public.joint_account_invitations
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

CREATE OR REPLACE FUNCTION public.create_joint_account_invitation(
    p_inviter_profile_id UUID,
    p_invitee_email TEXT,
    p_account_type TEXT DEFAULT 'checking',
    p_currency TEXT DEFAULT 'PKR'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_invitation_id UUID;
    v_expires_at TIMESTAMPTZ;
    v_inviter_email TEXT;
BEGIN
    SELECT email INTO v_inviter_email FROM public.profiles WHERE id = p_inviter_profile_id;
    IF v_inviter_email IS NULL THEN
        RAISE EXCEPTION 'Inviter profile % not found', p_inviter_profile_id;
    END IF;

    IF lower(v_inviter_email) = lower(p_invitee_email) THEN
        RETURN jsonb_build_object('success', false, 'error', 'You cannot invite yourself to a joint account');
    END IF;

    -- Superseding an old pending invite between the same pair avoids two
    -- concurrent invitations racing to create two different accounts.
    UPDATE public.joint_account_invitations
    SET status = 'expired', updated_at = NOW()
    WHERE inviter_profile_id = p_inviter_profile_id
      AND lower(invitee_email) = lower(p_invitee_email)
      AND status = 'pending';

    INSERT INTO public.joint_account_invitations (inviter_profile_id, invitee_email, account_type, currency)
    VALUES (p_inviter_profile_id, lower(p_invitee_email), p_account_type, p_currency)
    RETURNING id, expires_at INTO v_invitation_id, v_expires_at;

    PERFORM public.write_audit_log(
        'joint_invitation_created', 'customer', p_inviter_profile_id, 'joint_account_invitation', v_invitation_id,
        jsonb_build_object('invitee_email', p_invitee_email, 'expires_at', v_expires_at)
    );

    RETURN jsonb_build_object(
        'success', true, 'invitation_id', v_invitation_id, 'expires_at', v_expires_at,
        'inviter_email', v_inviter_email
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.respond_to_joint_invitation(
    p_invitation_id UUID,
    p_responder_email TEXT,
    p_accept BOOLEAN,
    p_responder_profile_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_inv public.joint_account_invitations%ROWTYPE;
    v_account_id UUID;
    v_account_number TEXT;
    v_invitee_profile_id UUID;
    v_inviter_email TEXT;
    v_inviter_name TEXT;
BEGIN
    SELECT * INTO v_inv FROM public.joint_account_invitations WHERE id = p_invitation_id FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invitation not found');
    END IF;

    -- Looked up once, up front, so every return branch (not just acceptance)
    -- can notify the inviter of the outcome.
    SELECT email, full_name INTO v_inviter_email, v_inviter_name FROM public.profiles WHERE id = v_inv.inviter_profile_id;

    IF lower(v_inv.invitee_email) <> lower(p_responder_email) THEN
        RETURN jsonb_build_object('success', false, 'error', 'This invitation was not addressed to your email address');
    END IF;

    -- Idempotent: a duplicate accept/reject (double email, retry, etc.) returns
    -- the already-settled state instead of erroring or creating a second account.
    IF v_inv.status <> 'pending' THEN
        RETURN jsonb_build_object(
            'success', true, 'status', v_inv.status, 'already_processed', true,
            'account_id', v_inv.account_id, 'inviter_email', v_inviter_email, 'inviter_name', v_inviter_name
        );
    END IF;

    IF v_inv.expires_at <= NOW() THEN
        UPDATE public.joint_account_invitations SET status = 'expired', updated_at = NOW() WHERE id = p_invitation_id;
        RETURN jsonb_build_object('success', false, 'status', 'expired', 'error', 'This invitation has expired', 'inviter_email', v_inviter_email, 'inviter_name', v_inviter_name);
    END IF;

    IF NOT p_accept THEN
        UPDATE public.joint_account_invitations SET status = 'rejected', updated_at = NOW() WHERE id = p_invitation_id;
        PERFORM public.write_audit_log(
            'joint_invitation_rejected', 'customer', p_responder_profile_id, 'joint_account_invitation', p_invitation_id, '{}'::jsonb
        );
        RETURN jsonb_build_object('success', true, 'status', 'rejected', 'inviter_email', v_inviter_email, 'inviter_name', v_inviter_name);
    END IF;

    v_invitee_profile_id := p_responder_profile_id;
    IF v_invitee_profile_id IS NULL THEN
        SELECT id INTO v_invitee_profile_id FROM public.profiles WHERE lower(email) = lower(p_responder_email);
    END IF;

    -- The invitee doesn't have a bank profile yet. The caller (n8n) creates one
    -- via the same path used for single-account opening, then calls this RPC
    -- again with p_responder_profile_id set -- the invitation stays 'pending'
    -- and untouched so that retry is safe.
    IF v_invitee_profile_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'invitee_profile_required', 'needs_profile_creation', true, 'inviter_email', v_inviter_email, 'inviter_name', v_inviter_name);
    END IF;

    v_account_number := 'JNT-' || UPPER(SUBSTRING(REPLACE(gen_random_uuid()::text, '-', '') FROM 1 FOR 10));

    INSERT INTO public.accounts (account_number, account_type, currency, balance, status)
    VALUES (v_account_number, v_inv.account_type, v_inv.currency, 0, 'active')
    RETURNING id INTO v_account_id;

    INSERT INTO public.account_holders (account_id, profile_id, role) VALUES (v_account_id, v_inv.inviter_profile_id, 'primary');
    INSERT INTO public.account_holders (account_id, profile_id, role) VALUES (v_account_id, v_invitee_profile_id, 'joint');

    UPDATE public.joint_account_invitations
    SET status = 'accepted', account_id = v_account_id, updated_at = NOW()
    WHERE id = p_invitation_id;

    PERFORM public.write_audit_log(
        'joint_account_created', 'customer', v_invitee_profile_id, 'account', v_account_id,
        jsonb_build_object('inviter_profile_id', v_inv.inviter_profile_id, 'invitation_id', p_invitation_id)
    );

    RETURN jsonb_build_object(
        'success', true, 'status', 'accepted', 'account_id', v_account_id,
        'account_number', v_account_number, 'currency', v_inv.currency,
        'inviter_email', v_inviter_email, 'inviter_name', v_inviter_name
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.expire_stale_joint_invitations()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_expired JSONB := '[]'::jsonb;
    v_row RECORD;
BEGIN
    FOR v_row IN
        SELECT ji.id, ji.inviter_profile_id, ji.invitee_email, p.email AS inviter_email, p.full_name AS inviter_name
        FROM public.joint_account_invitations ji
        JOIN public.profiles p ON p.id = ji.inviter_profile_id
        WHERE ji.status = 'pending' AND ji.expires_at <= NOW()
        FOR UPDATE OF ji SKIP LOCKED
    LOOP
        UPDATE public.joint_account_invitations SET status = 'expired', updated_at = NOW() WHERE id = v_row.id;
        v_expired := v_expired || jsonb_build_object(
            'invitation_id', v_row.id, 'inviter_email', v_row.inviter_email,
            'inviter_name', v_row.inviter_name, 'invitee_email', v_row.invitee_email
        );
        PERFORM public.write_audit_log('joint_invitation_expired', 'system', NULL, 'joint_account_invitation', v_row.id, '{}'::jsonb);
    END LOOP;

    RETURN jsonb_build_object('success', true, 'expired_count', jsonb_array_length(v_expired), 'expired', v_expired);
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. PUBLIC (NON-CUSTOMER) RAG SUPPORT
-- -----------------------------------------------------------------------------

ALTER TABLE public.support_cases ALTER COLUMN profile_id DROP NOT NULL;
ALTER TABLE public.support_cases ADD COLUMN IF NOT EXISTS customer_email TEXT;
ALTER TABLE public.support_cases ADD COLUMN IF NOT EXISTS inquirer_type TEXT NOT NULL DEFAULT 'customer'
  CHECK (inquirer_type IN ('customer', 'public'));
ALTER TABLE public.support_cases
  ADD CONSTRAINT support_cases_identity_check CHECK (profile_id IS NOT NULL OR customer_email IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_support_cases_customer_email ON public.support_cases(customer_email);

-- -----------------------------------------------------------------------------
-- 4. OWNERSHIP + GRANTS
-- -----------------------------------------------------------------------------

ALTER FUNCTION public.create_joint_account_invitation(UUID, TEXT, TEXT, TEXT) OWNER TO banking_functions;
ALTER FUNCTION public.respond_to_joint_invitation(UUID, TEXT, BOOLEAN, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.expire_stale_joint_invitations() OWNER TO banking_functions;

REVOKE EXECUTE ON FUNCTION public.create_joint_account_invitation(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.respond_to_joint_invitation(UUID, TEXT, BOOLEAN, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.expire_stale_joint_invitations() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_joint_account_invitation(UUID, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.respond_to_joint_invitation(UUID, TEXT, BOOLEAN, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.expire_stale_joint_invitations() TO service_role;

-- End of Migration 005_pkr_currency_joint_invitations_public_rag.sql
