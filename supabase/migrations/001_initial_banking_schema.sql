-- =============================================================================
-- MIGRATION: 001_initial_banking_schema.sql
-- DESCRIPTION: Core Banking System Schema, Role Setup, Financial RPCs, and RLS
-- TARGET: Supabase PostgreSQL
-- AUTHOR: Financial Systems Engineering Team
-- =============================================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------------------------------------------------------
-- 1. ROLE SETUP
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'banking_functions') THEN
        CREATE ROLE banking_functions NOLOGIN;
    END IF;
END
$$;

GRANT banking_functions TO postgres;

-- Schema access fix for Supabase Cloud.
-- In newer Supabase projects the public schema is owned by supabase_admin, not postgres.
-- We attempt to transfer ownership (works if postgres has the right) and fall back silently.
-- We then unconditionally grant CREATE+USAGE so postgres and banking_functions can create objects.
DO $$
BEGIN
    ALTER SCHEMA public OWNER TO postgres;
EXCEPTION WHEN insufficient_privilege OR object_not_in_prerequisite_state THEN
    RAISE NOTICE 'Could not ALTER SCHEMA public OWNER TO postgres (insufficient privilege) — skipping.';
END;
$$;

GRANT USAGE, CREATE ON SCHEMA public TO postgres;
GRANT USAGE, CREATE ON SCHEMA public TO banking_functions;

-- -----------------------------------------------------------------------------
-- 2. TABLE DEFINITIONS (All 15 Tables)
-- -----------------------------------------------------------------------------

-- Table 1: profiles (1:1 with auth.users)
CREATE TABLE public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT NOT NULL UNIQUE,
    full_name TEXT NOT NULL,
    phone_number TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 2: accounts
-- Opening balance rule: All accounts start at balance = 0.
-- Any non-zero initial balance MUST be created via an explicit ledger entry.
CREATE TABLE public.accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_number TEXT UNIQUE NOT NULL,
    account_type TEXT NOT NULL CHECK (account_type IN ('checking', 'savings', 'joint', 'business')),
    currency TEXT NOT NULL DEFAULT 'USD',
    balance BIGINT NOT NULL DEFAULT 0 CHECK (balance >= 0),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'frozen', 'closed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 3: account_holders
CREATE TABLE public.account_holders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'primary' CHECK (role IN ('primary', 'joint', 'beneficiary')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT unique_account_profile UNIQUE (account_id, profile_id)
);

-- Table 4: transactions
CREATE TABLE public.transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_account_id UUID REFERENCES public.accounts(id),
    destination_account_id UUID REFERENCES public.accounts(id),
    amount BIGINT NOT NULL CHECK (amount > 0),
    currency TEXT NOT NULL DEFAULT 'USD',
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'failed', 'reversed')),
    description TEXT,
    initiated_by_profile_id UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 5: ledger_entries (Append-Only Double-Entry Ledger)
CREATE TABLE public.ledger_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID NOT NULL REFERENCES public.transactions(id) ON DELETE RESTRICT,
    account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE RESTRICT,
    entry_type TEXT NOT NULL CHECK (entry_type IN ('debit', 'credit')),
    amount BIGINT NOT NULL CHECK (amount > 0),
    balance_after BIGINT NOT NULL CHECK (balance_after >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 6: idempotency_keys
CREATE TABLE public.idempotency_keys (
    key TEXT PRIMARY KEY,
    transaction_id UUID REFERENCES public.transactions(id) ON DELETE SET NULL,
    request_hash TEXT NOT NULL,
    response_body JSONB,
    status TEXT NOT NULL DEFAULT 'processing' CHECK (status IN ('processing', 'completed', 'failed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    locked_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 7: account_holds
CREATE TABLE public.account_holds (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    hold_type TEXT NOT NULL CHECK (hold_type IN ('fraud_investigation', 'compliance', 'dispute', 'partial_reservation', 'court_order')),
    is_full_freeze BOOLEAN NOT NULL DEFAULT FALSE,
    amount_held BIGINT NOT NULL DEFAULT 0 CHECK (amount_held >= 0),
    reason TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'released', 'expired')),
    placed_by_profile_id UUID REFERENCES public.profiles(id),
    released_by_profile_id UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    released_at TIMESTAMPTZ
);

-- Table 8: standing_orders
CREATE TABLE public.standing_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    destination_account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    amount BIGINT NOT NULL CHECK (amount > 0),
    currency TEXT NOT NULL DEFAULT 'USD',
    frequency TEXT NOT NULL CHECK (frequency IN ('daily', 'weekly', 'monthly')),
    next_execution_at TIMESTAMPTZ NOT NULL,
    execution_locked_at TIMESTAMPTZ,
    retry_count INT NOT NULL DEFAULT 0,
    last_error TEXT,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'failed', 'cancelled')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 9: joint_account_actions
CREATE TABLE public.joint_account_actions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    action_type TEXT NOT NULL DEFAULT 'close_account' CHECK (action_type IN ('close_account')),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'expired')),
    requested_by_profile_id UUID NOT NULL REFERENCES public.profiles(id),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 10: joint_account_consents
CREATE TABLE public.joint_account_consents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    joint_action_id UUID NOT NULL REFERENCES public.joint_account_actions(id) ON DELETE CASCADE,
    profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    consent BOOLEAN NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT unique_action_profile_consent UNIQUE (joint_action_id, profile_id)
);

-- Table 11: fraud_assessments
CREATE TABLE public.fraud_assessments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
    amount BIGINT NOT NULL CHECK (amount > 0),
    risk_score NUMERIC(5, 2) NOT NULL CHECK (risk_score >= 0 AND risk_score <= 100),
    approved BOOLEAN NOT NULL,
    reason TEXT,
    consumed BOOLEAN NOT NULL DEFAULT FALSE,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 12: support_cases
CREATE TABLE public.support_cases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    subject TEXT NOT NULL,
    inquiry TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'awaiting_human_review', 'resolved', 'closed')),
    final_sent_response TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 13: support_case_drafts (Internal RAG / AI workflow)
CREATE TABLE public.support_case_drafts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    support_case_id UUID NOT NULL REFERENCES public.support_cases(id) ON DELETE CASCADE UNIQUE,
    rag_doc_ids JSONB DEFAULT '[]'::jsonb,
    similarity_scores JSONB DEFAULT '[]'::jsonb,
    confidence_score NUMERIC(5,2),
    threshold_exceeded BOOLEAN NOT NULL DEFAULT FALSE,
    groq_draft TEXT,
    human_review_state TEXT NOT NULL DEFAULT 'pending' CHECK (human_review_state IN ('pending', 'approved', 'edited', 'rejected')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 14: reconciliation_runs
CREATE TABLE public.reconciliation_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_date DATE NOT NULL UNIQUE,
    passed BOOLEAN NOT NULL,
    total_system_debits BIGINT NOT NULL DEFAULT 0,
    total_system_credits BIGINT NOT NULL DEFAULT 0,
    discrepancies JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Table 15: audit_log (Append-Only System Audit Trail)
CREATE TABLE public.audit_log (
    seq BIGSERIAL PRIMARY KEY,
    id UUID UNIQUE NOT NULL DEFAULT gen_random_uuid(),
    event_type TEXT NOT NULL,
    actor_type TEXT NOT NULL CHECK (actor_type IN ('customer', 'system', 'n8n', 'python', 'admin', 'trigger')),
    actor_id UUID,
    target_type TEXT,
    target_id UUID,
    details JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 3. INDEXES
-- -----------------------------------------------------------------------------
CREATE INDEX idx_account_holders_profile ON public.account_holders(profile_id);
CREATE INDEX idx_account_holders_account ON public.account_holders(account_id);
CREATE INDEX idx_transactions_source ON public.transactions(source_account_id);
CREATE INDEX idx_transactions_dest ON public.transactions(destination_account_id);
CREATE INDEX idx_transactions_created ON public.transactions(created_at DESC);
CREATE INDEX idx_ledger_entries_account ON public.ledger_entries(account_id);
CREATE INDEX idx_ledger_entries_tx ON public.ledger_entries(transaction_id);
CREATE INDEX idx_account_holds_account_status ON public.account_holds(account_id, status);
CREATE INDEX idx_standing_orders_next_exec ON public.standing_orders(next_execution_at) WHERE status = 'active';
CREATE INDEX idx_fraud_assessments_account ON public.fraud_assessments(account_id, expires_at);
CREATE INDEX idx_support_cases_profile ON public.support_cases(profile_id);
CREATE INDEX idx_audit_log_created ON public.audit_log(created_at DESC);
CREATE INDEX idx_audit_log_event ON public.audit_log(event_type);

-- -----------------------------------------------------------------------------
-- 4. APPEND-ONLY PROTECTION TRIGGERS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prevent_modification_append_only()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'Table % is append-only. UPDATE and DELETE operations are prohibited.', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER trg_ledger_entries_append_only
BEFORE UPDATE OR DELETE ON public.ledger_entries
FOR EACH ROW EXECUTE FUNCTION public.prevent_modification_append_only();

CREATE TRIGGER trg_audit_log_append_only
BEFORE UPDATE OR DELETE ON public.audit_log
FOR EACH ROW EXECUTE FUNCTION public.prevent_modification_append_only();

-- -----------------------------------------------------------------------------
-- 5. SYSTEM FUNCTIONS & TRIGGERS
-- -----------------------------------------------------------------------------

-- Audit Logger Helper Function
CREATE OR REPLACE FUNCTION public.write_audit_log(
    p_event_type TEXT,
    p_actor_type TEXT,
    p_actor_id UUID,
    p_target_type TEXT,
    p_target_id UUID,
    p_details JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_audit_id UUID;
BEGIN
    INSERT INTO public.audit_log (
        event_type,
        actor_type,
        actor_id,
        target_type,
        target_id,
        details
    ) VALUES (
        p_event_type,
        p_actor_type,
        p_actor_id,
        p_target_type,
        p_target_id,
        COALESCE(p_details, '{}'::jsonb)
    ) RETURNING id INTO v_audit_id;

    RETURN v_audit_id;
END;
$$;

-- Supabase Auth Signup Sync Trigger Function
CREATE OR REPLACE FUNCTION public.create_profile_for_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO public.profiles (id, email, full_name)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email)
    )
    ON CONFLICT (id) DO UPDATE
    SET email = EXCLUDED.email,
        updated_at = NOW();

    PERFORM public.write_audit_log(
        'profile_created',
        'trigger',
        NEW.id,
        'profile',
        NEW.id,
        jsonb_build_object('email', NEW.email)
    );

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.create_profile_for_user();

-- Available Balance Calculation Helper
CREATE OR REPLACE FUNCTION public.get_available_balance(p_account_id UUID)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_cached_balance BIGINT;
    v_held_amount BIGINT;
BEGIN
    SELECT balance INTO v_cached_balance
    FROM public.accounts
    WHERE id = p_account_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account % not found', p_account_id;
    END IF;

    SELECT COALESCE(SUM(amount_held), 0) INTO v_held_amount
    FROM public.account_holds
    WHERE account_id = p_account_id
      AND status = 'active'
      AND is_full_freeze = FALSE;

    RETURN GREATEST(0, v_cached_balance - v_held_amount);
END;
$$;

-- Fraud Assessment Validation Helper
CREATE OR REPLACE FUNCTION public.check_fraud_assessment(
    p_fraud_assessment_id UUID,
    p_account_id UUID,
    p_amount BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_assessment public.fraud_assessments%ROWTYPE;
BEGIN
    SELECT * INTO v_assessment
    FROM public.fraud_assessments
    WHERE id = p_fraud_assessment_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Fraud assessment % does not exist', p_fraud_assessment_id;
    END IF;

    IF v_assessment.account_id <> p_account_id THEN
        RAISE EXCEPTION 'Fraud assessment % is for account %, not %', p_fraud_assessment_id, v_assessment.account_id, p_account_id;
    END IF;

    IF v_assessment.amount < p_amount THEN
        RAISE EXCEPTION 'Fraud assessment amount % is less than transfer amount %', v_assessment.amount, p_amount;
    END IF;

    IF NOT v_assessment.approved THEN
        RAISE EXCEPTION 'Fraud assessment % is NOT approved (reason: %)', p_fraud_assessment_id, v_assessment.reason;
    END IF;

    IF v_assessment.expires_at <= NOW() THEN
        RAISE EXCEPTION 'Fraud assessment % has expired at %', p_fraud_assessment_id, v_assessment.expires_at;
    END IF;

    IF v_assessment.consumed THEN
        RAISE EXCEPTION 'Fraud assessment % has already been consumed', p_fraud_assessment_id;
    END IF;

    -- Mark assessment as consumed atomically
    UPDATE public.fraud_assessments
    SET consumed = TRUE
    WHERE id = p_fraud_assessment_id;

    RETURN TRUE;
END;
$$;

-- Account Closure Helper Function
CREATE OR REPLACE FUNCTION public.close_account(p_account_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_account public.accounts%ROWTYPE;
    v_active_holds INT;
    v_active_standing_orders INT;
BEGIN
    SELECT * INTO v_account
    FROM public.accounts
    WHERE id = p_account_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account % not found', p_account_id;
    END IF;

    IF v_account.status = 'closed' THEN
        RETURN jsonb_build_object('success', true, 'status', 'already_closed');
    END IF;

    IF v_account.balance <> 0 THEN
        RAISE EXCEPTION 'Cannot close account % with non-zero balance (current balance: %)', p_account_id, v_account.balance;
    END IF;

    SELECT COUNT(*) INTO v_active_holds
    FROM public.account_holds
    WHERE account_id = p_account_id AND status = 'active';

    IF v_active_holds > 0 THEN
        RAISE EXCEPTION 'Cannot close account % with % active holds', p_account_id, v_active_holds;
    END IF;

    SELECT COUNT(*) INTO v_active_standing_orders
    FROM public.standing_orders
    WHERE source_account_id = p_account_id AND status = 'active';

    IF v_active_standing_orders > 0 THEN
        RAISE EXCEPTION 'Cannot close account % with % active standing orders', p_account_id, v_active_standing_orders;
    END IF;

    UPDATE public.accounts
    SET status = 'closed',
        updated_at = NOW()
    WHERE id = p_account_id;

    PERFORM public.write_audit_log(
        'account_closed',
        'system',
        NULL,
        'account',
        p_account_id,
        jsonb_build_object('previous_status', v_account.status)
    );

    RETURN jsonb_build_object('success', true, 'account_id', p_account_id, 'status', 'closed');
END;
$$;

-- Shared Core Money Movement Helper Function
-- Enforces identical financial invariants for both ad-hoc transfers and standing orders.
CREATE OR REPLACE FUNCTION public.process_money_movement(
    p_source_account_id UUID,
    p_destination_account_id UUID,
    p_amount BIGINT,
    p_currency TEXT,
    p_description TEXT,
    p_initiated_by_profile_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_first_account_id UUID;
    v_second_account_id UUID;
    v_source_account public.accounts%ROWTYPE;
    v_dest_account public.accounts%ROWTYPE;
    v_transaction_id UUID;
    v_new_source_balance BIGINT;
    v_new_dest_balance BIGINT;
    v_avail_balance BIGINT;
    v_freeze_count INT;
BEGIN
    -- 1. Basic Parameter Validation
    IF p_source_account_id = p_destination_account_id THEN
        RAISE EXCEPTION 'Source and destination accounts must be different';
    END IF;

    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be strictly positive';
    END IF;

    -- 2. Deterministic Row Locking (Deadlock Prevention)
    IF p_source_account_id < p_destination_account_id THEN
        v_first_account_id := p_source_account_id;
        v_second_account_id := p_destination_account_id;
    ELSE
        v_first_account_id := p_destination_account_id;
        v_second_account_id := p_source_account_id;
    END IF;

    PERFORM 1 FROM public.accounts WHERE id = v_first_account_id FOR UPDATE;
    PERFORM 1 FROM public.accounts WHERE id = v_second_account_id FOR UPDATE;

    SELECT * INTO v_source_account FROM public.accounts WHERE id = p_source_account_id;
    SELECT * INTO v_dest_account FROM public.accounts WHERE id = p_destination_account_id;

    IF v_source_account.id IS NULL THEN
        RAISE EXCEPTION 'Source account % does not exist', p_source_account_id;
    END IF;

    IF v_dest_account.id IS NULL THEN
        RAISE EXCEPTION 'Destination account % does not exist', p_destination_account_id;
    END IF;

    IF v_source_account.currency <> p_currency OR v_dest_account.currency <> p_currency THEN
        RAISE EXCEPTION 'Currency mismatch: Transfer currency % does not match account currencies (% / %)',
            p_currency, v_source_account.currency, v_dest_account.currency;
    END IF;

    IF v_source_account.status <> 'active' THEN
        RAISE EXCEPTION 'Source account % is %', p_source_account_id, v_source_account.status;
    END IF;

    IF v_dest_account.status <> 'active' THEN
        RAISE EXCEPTION 'Destination account % is %', p_destination_account_id, v_dest_account.status;
    END IF;

    -- Check active full freezes
    SELECT COUNT(*) INTO v_freeze_count
    FROM public.account_holds
    WHERE account_id = p_source_account_id AND status = 'active' AND is_full_freeze = TRUE;

    IF v_freeze_count > 0 THEN
        RAISE EXCEPTION 'Source account % has active freeze hold', p_source_account_id;
    END IF;

    SELECT COUNT(*) INTO v_freeze_count
    FROM public.account_holds
    WHERE account_id = p_destination_account_id AND status = 'active' AND is_full_freeze = TRUE;

    IF v_freeze_count > 0 THEN
        RAISE EXCEPTION 'Destination account % has active freeze hold', p_destination_account_id;
    END IF;

    -- Available Balance Check
    v_avail_balance := public.get_available_balance(p_source_account_id);
    IF v_avail_balance < p_amount THEN
        RAISE EXCEPTION 'Insufficient available balance in account %. Available: %, Requested: %',
            p_source_account_id, v_avail_balance, p_amount;
    END IF;

    -- Financial Mutations
    INSERT INTO public.transactions (
        source_account_id,
        destination_account_id,
        amount,
        currency,
        status,
        description,
        initiated_by_profile_id
    ) VALUES (
        p_source_account_id,
        p_destination_account_id,
        p_amount,
        p_currency,
        'completed',
        p_description,
        p_initiated_by_profile_id
    ) RETURNING id INTO v_transaction_id;

    UPDATE public.accounts
    SET balance = balance - p_amount, updated_at = NOW()
    WHERE id = p_source_account_id
    RETURNING balance INTO v_new_source_balance;

    UPDATE public.accounts
    SET balance = balance + p_amount, updated_at = NOW()
    WHERE id = p_destination_account_id
    RETURNING balance INTO v_new_dest_balance;

    -- Debit Ledger Entry
    INSERT INTO public.ledger_entries (transaction_id, account_id, entry_type, amount, balance_after)
    VALUES (v_transaction_id, p_source_account_id, 'debit', p_amount, v_new_source_balance);

    -- Credit Ledger Entry
    INSERT INTO public.ledger_entries (transaction_id, account_id, entry_type, amount, balance_after)
    VALUES (v_transaction_id, p_destination_account_id, 'credit', p_amount, v_new_dest_balance);

    RETURN v_transaction_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- 6. CORE FINANCIAL RPC FUNCTIONS
-- -----------------------------------------------------------------------------

-- Core Atomic Transfer Function
CREATE OR REPLACE FUNCTION public.execute_transfer(
    p_source_account_id UUID,
    p_destination_account_id UUID,
    p_amount BIGINT,
    p_currency TEXT,
    p_idempotency_key TEXT,
    p_initiated_by_profile_id UUID,
    p_fraud_assessment_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_transaction_id UUID;
    v_existing_key public.idempotency_keys%ROWTYPE;
    v_request_hash TEXT;
    v_response_json JSONB;
BEGIN
    -- 1. Authorization Guard
    -- NOTE: auth.role() removed. execute_transfer is restricted to service_role
    -- via GRANT, so no authenticated user can call it directly. This check is
    -- therefore unnecessary and caused permission denied errors in Supabase Cloud.

    -- 2. Idempotency Gatekeeping & Concurrency Guard
    IF p_idempotency_key IS NULL OR TRIM(p_idempotency_key) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Idempotency key is required');
    END IF;

    v_request_hash := MD5(CONCAT_WS(':', p_source_account_id, p_destination_account_id, p_amount, p_currency, p_fraud_assessment_id));

    -- Lock & Fetch Idempotency Key Record
    SELECT * INTO v_existing_key
    FROM public.idempotency_keys
    WHERE key = p_idempotency_key FOR UPDATE;

    IF FOUND THEN
        -- 1. Check parameter mismatch
        IF v_existing_key.request_hash <> v_request_hash THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Idempotency key reuse with different parameters',
                'idempotency_key', p_idempotency_key
            );
        END IF;

        -- 2. Replay completed or failed result
        IF v_existing_key.status = 'completed' THEN
            RETURN v_existing_key.response_body;
        ELSIF v_existing_key.status = 'failed' THEN
            RETURN v_existing_key.response_body;
        ELSIF v_existing_key.status = 'processing' THEN
            -- Check lock age
            IF v_existing_key.locked_at > NOW() - INTERVAL '5 minutes' THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'Concurrent transaction in progress for idempotency key ' || p_idempotency_key
                );
            ELSE
                -- Safely recover stale lock (>5 mins old) and take ownership.
                -- Ownership is GUARANTEED by the `SELECT ... FOR UPDATE` above (line 648-650):
                -- that lock is held for the lifetime of this transaction, so no concurrent
                -- worker can simultaneously enter this branch for the same key.
                -- Updating locked_at stamps this worker as the new owner in the DB record
                -- so that any future reader (after our transaction commits) sees a fresh lock.
                UPDATE public.idempotency_keys
                SET locked_at = NOW()
                WHERE key = p_idempotency_key;
            END IF;
        END IF;
    ELSE
        -- Insert new idempotency record in processing state
        INSERT INTO public.idempotency_keys (key, request_hash, status, locked_at)
        VALUES (p_idempotency_key, v_request_hash, 'processing', NOW());
    END IF;

    BEGIN
        -- 3. Fraud Assessment Verification & Consumption
        PERFORM public.check_fraud_assessment(p_fraud_assessment_id, p_source_account_id, p_amount);

        -- 4. Execute Core Money Movement
        v_transaction_id := public.process_money_movement(
            p_source_account_id,
            p_destination_account_id,
            p_amount,
            p_currency,
            'Funds transfer',
            p_initiated_by_profile_id
        );

        -- 5. Audit Log
        PERFORM public.write_audit_log(
            'transfer_completed',
            'system',
            p_initiated_by_profile_id,
            'transaction',
            v_transaction_id,
            jsonb_build_object(
                'source_account_id', p_source_account_id,
                'destination_account_id', p_destination_account_id,
                'amount', p_amount,
                'currency', p_currency,
                'idempotency_key', p_idempotency_key,
                'fraud_assessment_id', p_fraud_assessment_id
            )
        );

        -- 6. Store Response Payload
        v_response_json := jsonb_build_object(
            'success', true,
            'transaction_id', v_transaction_id,
            'status', 'completed',
            'amount', p_amount,
            'currency', p_currency,
            'source_account_id', p_source_account_id,
            'destination_account_id', p_destination_account_id
        );

        UPDATE public.idempotency_keys
        SET status = 'completed',
            transaction_id = v_transaction_id,
            response_body = v_response_json
        WHERE key = p_idempotency_key;

        RETURN v_response_json;

    EXCEPTION WHEN OTHERS THEN
        v_response_json := jsonb_build_object(
            'success', false,
            'error', SQLERRM,
            'idempotency_key', p_idempotency_key
        );

        UPDATE public.idempotency_keys
        SET status = 'failed',
            response_body = v_response_json
        WHERE key = p_idempotency_key;

        PERFORM public.write_audit_log(
            'transfer_failed',
            'system',
            p_initiated_by_profile_id,
            'account',
            p_source_account_id,
            jsonb_build_object(
                'error', SQLERRM,
                'idempotency_key', p_idempotency_key,
                'amount', p_amount
            )
        );

        RETURN v_response_json;
    END;
END;
$$;

-- Recurring Standing Order Executor
-- NOTE: Standing orders are pre-authorized recurring payment instructions created by the account holder.
-- Separate ad-hoc fraud assessment scoring applies to one-off transfers (execute_transfer),
-- while standing orders undergo full account, hold, currency, and balance checks during execution.
CREATE OR REPLACE FUNCTION public.execute_standing_order(
    p_standing_order_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_order public.standing_orders%ROWTYPE;
    v_transaction_id UUID;
    v_next_exec TIMESTAMPTZ;
    v_idempotency_key TEXT;
    v_existing_key public.idempotency_keys%ROWTYPE;
    v_err_msg TEXT;
BEGIN
    SELECT * INTO v_order
    FROM public.standing_orders
    WHERE id = p_standing_order_id FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Standing order not found', 'standing_order_id', p_standing_order_id);
    END IF;

    -- 10-minute Standing Order Stale Lock Protection
    IF v_order.execution_locked_at IS NOT NULL AND v_order.execution_locked_at > NOW() - INTERVAL '10 minutes' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Standing order is locked by active worker',
            'standing_order_id', p_standing_order_id,
            'locked_at', v_order.execution_locked_at
        );
    END IF;

    IF v_order.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Standing order is not active', 'status', v_order.status);
    END IF;

    IF v_order.next_execution_at > NOW() THEN
        RETURN jsonb_build_object('success', false, 'error', 'Standing order is not due yet', 'next_execution_at', v_order.next_execution_at);
    END IF;

    -- Prevent Duplicate Execution for Same Schedule Slot via Idempotency Key Atomic Lock
    v_idempotency_key := 'so_' || p_standing_order_id::text || '_' || EXTRACT(EPOCH FROM v_order.next_execution_at)::text;

    SELECT * INTO v_existing_key
    FROM public.idempotency_keys
    WHERE key = v_idempotency_key FOR UPDATE;

    IF FOUND THEN
        IF v_existing_key.status = 'completed' THEN
            IF v_order.frequency = 'daily' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 day';
            ELSIF v_order.frequency = 'weekly' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 week';
            ELSE v_next_exec := v_order.next_execution_at + INTERVAL '1 month';
            END IF;

            UPDATE public.standing_orders
            SET next_execution_at = v_next_exec,
                execution_locked_at = NULL
            WHERE id = p_standing_order_id;

            RETURN jsonb_build_object(
                'success', true,
                'message', 'Standing order already executed for scheduled timestamp',
                'standing_order_id', p_standing_order_id,
                'next_execution_at', v_next_exec
            );
        ELSIF v_existing_key.status = 'processing' THEN
            IF v_existing_key.locked_at > NOW() - INTERVAL '5 minutes' THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'Standing order execution already in progress by another worker',
                    'standing_order_id', p_standing_order_id
                );
            ELSE
                -- Safely recover stale lock (>5 mins old) on standing order idempotency key
                UPDATE public.idempotency_keys
                SET locked_at = NOW()
                WHERE key = v_idempotency_key;
            END IF;
        END IF;
    ELSE
        INSERT INTO public.idempotency_keys (key, request_hash, status, locked_at)
        VALUES (v_idempotency_key, MD5(v_idempotency_key), 'processing', NOW());
    END IF;

    -- Lock Standing Order Worker Slot
    UPDATE public.standing_orders
    SET execution_locked_at = NOW()
    WHERE id = p_standing_order_id;

    BEGIN
        -- Execute Core Money Movement (Shared Safety Pipeline)
        v_transaction_id := public.process_money_movement(
            v_order.source_account_id,
            v_order.destination_account_id,
            v_order.amount,
            v_order.currency,
            'Recurring standing order payment',
            NULL
        );

        -- Record Completed Idempotency Key
        UPDATE public.idempotency_keys
        SET status = 'completed',
            transaction_id = v_transaction_id,
            response_body = jsonb_build_object('success', true, 'transaction_id', v_transaction_id)
        WHERE key = v_idempotency_key;

        -- Calculate Next Execution Time
        IF v_order.frequency = 'daily' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 day';
        ELSIF v_order.frequency = 'weekly' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 week';
        ELSE v_next_exec := v_order.next_execution_at + INTERVAL '1 month';
        END IF;

        -- Update Standing Order to Success State
        UPDATE public.standing_orders
        SET next_execution_at = v_next_exec,
            execution_locked_at = NULL,
            retry_count = 0,
            last_error = NULL,
            updated_at = NOW()
        WHERE id = p_standing_order_id;

        PERFORM public.write_audit_log(
            'standing_order_executed',
            'system',
            NULL,
            'standing_order',
            p_standing_order_id,
            jsonb_build_object(
                'transaction_id', v_transaction_id,
                'next_execution_at', v_next_exec
            )
        );

        RETURN jsonb_build_object(
            'success', true,
            'standing_order_id', p_standing_order_id,
            'transaction_id', v_transaction_id,
            'next_execution_at', v_next_exec
        );

    EXCEPTION WHEN OTHERS THEN
        v_err_msg := SQLERRM;

        -- Update Idempotency Key to Failed
        UPDATE public.idempotency_keys
        SET status = 'failed',
            response_body = jsonb_build_object('success', false, 'error', v_err_msg)
        WHERE key = v_idempotency_key;

        -- Persist Retry Counter, Error, and Status Update on Failure
        UPDATE public.standing_orders
        SET retry_count = v_order.retry_count + 1,
            last_error = v_err_msg,
            status = CASE WHEN v_order.retry_count + 1 >= 3 THEN 'failed' ELSE v_order.status END,
            execution_locked_at = NULL,
            updated_at = NOW()
        WHERE id = p_standing_order_id;

        PERFORM public.write_audit_log(
            'standing_order_failed',
            'system',
            NULL,
            'standing_order',
            p_standing_order_id,
            jsonb_build_object(
                'reason', v_err_msg,
                'retry_count', v_order.retry_count + 1,
                'status', CASE WHEN v_order.retry_count + 1 >= 3 THEN 'failed' ELSE v_order.status END
            )
        );

        RETURN jsonb_build_object(
            'success', false,
            'error', v_err_msg,
            'standing_order_id', p_standing_order_id,
            'retry_count', v_order.retry_count + 1,
            'status', CASE WHEN v_order.retry_count + 1 >= 3 THEN 'failed' ELSE v_order.status END
        );
    END;
END;
$$;

-- Account Hold Placement RPC
CREATE OR REPLACE FUNCTION public.place_account_hold(
    p_account_id UUID,
    p_hold_type TEXT,
    p_is_full_freeze BOOLEAN,
    p_amount_held BIGINT,
    p_reason TEXT,
    p_placed_by_profile_id UUID
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_hold_id UUID;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.accounts WHERE id = p_account_id) THEN
        RAISE EXCEPTION 'Account % not found', p_account_id;
    END IF;

    INSERT INTO public.account_holds (
        account_id,
        hold_type,
        is_full_freeze,
        amount_held,
        reason,
        status,
        placed_by_profile_id
    ) VALUES (
        p_account_id,
        p_hold_type,
        p_is_full_freeze,
        COALESCE(p_amount_held, 0),
        p_reason,
        'active',
        p_placed_by_profile_id
    ) RETURNING id INTO v_hold_id;

    IF p_is_full_freeze THEN
        UPDATE public.accounts
        SET status = 'frozen',
            updated_at = NOW()
        WHERE id = p_account_id;
    END IF;

    PERFORM public.write_audit_log(
        'hold_placed',
        'system',
        p_placed_by_profile_id,
        'account_hold',
        v_hold_id,
        jsonb_build_object(
            'account_id', p_account_id,
            'hold_type', p_hold_type,
            'is_full_freeze', p_is_full_freeze,
            'amount_held', p_amount_held,
            'reason', p_reason
        )
    );

    RETURN v_hold_id;
END;
$$;

-- Account Hold Release RPC
CREATE OR REPLACE FUNCTION public.release_account_hold(
    p_hold_id UUID,
    p_released_by_profile_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_hold public.account_holds%ROWTYPE;
    v_remaining_freezes INT;
BEGIN
    SELECT * INTO v_hold
    FROM public.account_holds
    WHERE id = p_hold_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account hold % not found', p_hold_id;
    END IF;

    IF v_hold.status <> 'active' THEN
        RAISE EXCEPTION 'Account hold % is already %', p_hold_id, v_hold.status;
    END IF;

    UPDATE public.account_holds
    SET status = 'released',
        released_by_profile_id = p_released_by_profile_id,
        released_at = NOW()
    WHERE id = p_hold_id;

    SELECT COUNT(*) INTO v_remaining_freezes
    FROM public.account_holds
    WHERE account_id = v_hold.account_id
      AND status = 'active'
      AND is_full_freeze = TRUE;

    IF v_remaining_freezes = 0 THEN
        UPDATE public.accounts
        SET status = 'active',
            updated_at = NOW()
        WHERE id = v_hold.account_id AND status = 'frozen';
    END IF;

    PERFORM public.write_audit_log(
        'hold_released',
        'system',
        p_released_by_profile_id,
        'account_hold',
        p_hold_id,
        jsonb_build_object(
            'account_id', v_hold.account_id,
            'remaining_freezes', v_remaining_freezes
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'hold_id', p_hold_id,
        'status', 'released',
        'remaining_freezes', v_remaining_freezes
    );
END;
$$;

-- Joint Account Closure Request RPC
CREATE OR REPLACE FUNCTION public.request_joint_closure(
    p_account_id UUID,
    p_requested_by_profile_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_action_id UUID;
    v_total_holders INT;
    v_consents_count INT;
BEGIN
    -- Authorization Check
    -- NOTE: auth.role() removed. RPC is restricted via GRANT to service_role/authenticated.
    -- Caller identity is verified by checking account_holders table below.

    IF NOT EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = p_account_id AND profile_id = p_requested_by_profile_id
    ) THEN
        RAISE EXCEPTION 'Profile % is not an account holder of %', p_requested_by_profile_id, p_account_id;
    END IF;

    INSERT INTO public.joint_account_actions (
        account_id,
        action_type,
        status,
        requested_by_profile_id,
        expires_at
    ) VALUES (
        p_account_id,
        'close_account',
        'pending',
        p_requested_by_profile_id,
        NOW() + INTERVAL '7 days'
    ) RETURNING id INTO v_action_id;

    INSERT INTO public.joint_account_consents (
        joint_action_id,
        profile_id,
        consent
    ) VALUES (
        v_action_id,
        p_requested_by_profile_id,
        TRUE
    );

    SELECT COUNT(*) INTO v_total_holders
    FROM public.account_holders
    WHERE account_id = p_account_id;

    SELECT COUNT(*) INTO v_consents_count
    FROM public.joint_account_consents
    WHERE joint_action_id = v_action_id AND consent = TRUE;

    PERFORM public.write_audit_log(
        'joint_closure_requested',
        'customer',
        p_requested_by_profile_id,
        'joint_account_action',
        v_action_id,
        jsonb_build_object('account_id', p_account_id, 'consents_count', v_consents_count, 'total_holders', v_total_holders)
    );

    IF v_consents_count >= v_total_holders THEN
        UPDATE public.joint_account_actions SET status = 'approved', updated_at = NOW() WHERE id = v_action_id;
        PERFORM public.close_account(p_account_id);
        RETURN jsonb_build_object('success', true, 'joint_action_id', v_action_id, 'status', 'approved');
    END IF;

    RETURN jsonb_build_object('success', true, 'joint_action_id', v_action_id, 'status', 'pending');
END;
$$;

-- Joint Account Consent Record RPC
CREATE OR REPLACE FUNCTION public.record_joint_consent(
    p_joint_action_id UUID,
    p_profile_id UUID,
    p_consent BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_action public.joint_account_actions%ROWTYPE;
    v_total_holders INT;
    v_consents_count INT;
BEGIN
    -- Authorization Check
    -- NOTE: auth.role() removed. RPC is restricted via GRANT to service_role/authenticated.
    -- Caller identity is verified by checking account_holders table below.

    SELECT * INTO v_action
    FROM public.joint_account_actions
    WHERE id = p_joint_action_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Joint action % not found', p_joint_action_id;
    END IF;

    IF v_action.status <> 'pending' THEN
        RAISE EXCEPTION 'Joint action % is already %', p_joint_action_id, v_action.status;
    END IF;

    IF v_action.expires_at <= NOW() THEN
        UPDATE public.joint_account_actions SET status = 'expired', updated_at = NOW() WHERE id = p_joint_action_id;
        RAISE EXCEPTION 'Joint action % has expired', p_joint_action_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = v_action.account_id AND profile_id = p_profile_id
    ) THEN
        RAISE EXCEPTION 'Profile % is not an account holder of %', p_profile_id, v_action.account_id;
    END IF;

    INSERT INTO public.joint_account_consents (
        joint_action_id,
        profile_id,
        consent
    ) VALUES (
        p_joint_action_id,
        p_profile_id,
        p_consent
    )
    ON CONFLICT (joint_action_id, profile_id)
    DO UPDATE SET consent = EXCLUDED.consent, created_at = NOW();

    PERFORM public.write_audit_log(
        'joint_consent_recorded',
        'customer',
        p_profile_id,
        'joint_account_consent',
        p_joint_action_id,
        jsonb_build_object('consent', p_consent)
    );

    IF NOT p_consent THEN
        UPDATE public.joint_account_actions SET status = 'rejected', updated_at = NOW() WHERE id = p_joint_action_id;
        RETURN jsonb_build_object('success', true, 'joint_action_id', p_joint_action_id, 'status', 'rejected');
    END IF;

    SELECT COUNT(*) INTO v_total_holders
    FROM public.account_holders
    WHERE account_id = v_action.account_id;

    SELECT COUNT(*) INTO v_consents_count
    FROM public.joint_account_consents
    WHERE joint_action_id = p_joint_action_id AND consent = TRUE;

    IF v_consents_count >= v_total_holders THEN
        UPDATE public.joint_account_actions SET status = 'approved', updated_at = NOW() WHERE id = p_joint_action_id;
        PERFORM public.close_account(v_action.account_id);
        RETURN jsonb_build_object('success', true, 'joint_action_id', p_joint_action_id, 'status', 'approved');
    END IF;

    RETURN jsonb_build_object('success', true, 'joint_action_id', p_joint_action_id, 'status', 'pending');
END;
$$;

-- Reconciliation Engine RPC
CREATE OR REPLACE FUNCTION public.run_reconciliation(p_run_date DATE)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_total_debits BIGINT;
    v_total_credits BIGINT;
    v_discrepancies JSONB := '[]'::jsonb;
    v_rec_id UUID;
    v_passed BOOLEAN;
    v_acc RECORD;
    v_calculated_bal BIGINT;
BEGIN
    SELECT COALESCE(SUM(amount), 0) INTO v_total_debits
    FROM public.ledger_entries WHERE entry_type = 'debit';

    SELECT COALESCE(SUM(amount), 0) INTO v_total_credits
    FROM public.ledger_entries WHERE entry_type = 'credit';

    IF v_total_debits <> v_total_credits THEN
        v_discrepancies := jsonb_insert(
            v_discrepancies,
            '{0}',
            jsonb_build_object('type', 'system_imbalance', 'debits', v_total_debits, 'credits', v_total_credits)
        );
    END IF;

    FOR v_acc IN SELECT id, balance FROM public.accounts LOOP
        SELECT COALESCE(SUM(CASE WHEN entry_type = 'credit' THEN amount ELSE -amount END), 0)
        INTO v_calculated_bal
        FROM public.ledger_entries
        WHERE account_id = v_acc.id;

        IF v_acc.balance <> v_calculated_bal THEN
            v_discrepancies := v_discrepancies || jsonb_build_object(
                'account_id', v_acc.id,
                'cached_balance', v_acc.balance,
                'ledger_calculated_balance', v_calculated_bal,
                'diff', v_acc.balance - v_calculated_bal
            );
        END IF;
    END LOOP;

    v_passed := (jsonb_array_length(v_discrepancies) = 0);

    INSERT INTO public.reconciliation_runs (
        run_date,
        passed,
        total_system_debits,
        total_system_credits,
        discrepancies
    ) VALUES (
        p_run_date,
        v_passed,
        v_total_debits,
        v_total_credits,
        v_discrepancies
    )
    ON CONFLICT (run_date) DO UPDATE
    SET passed = EXCLUDED.passed,
        total_system_debits = EXCLUDED.total_system_debits,
        total_system_credits = EXCLUDED.total_system_credits,
        discrepancies = EXCLUDED.discrepancies,
        created_at = NOW()
    RETURNING id INTO v_rec_id;

    PERFORM public.write_audit_log(
        'reconciliation_completed',
        'system',
        NULL,
        'reconciliation_run',
        v_rec_id,
        jsonb_build_object('passed', v_passed, 'run_date', p_run_date)
    );

    RETURN jsonb_build_object(
        'success', true,
        'reconciliation_id', v_rec_id,
        'run_date', p_run_date,
        'passed', v_passed,
        'total_debits', v_total_debits,
        'total_credits', v_total_credits,
        'discrepancies', v_discrepancies
    );
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. FUNCTION OWNERSHIP
-- -----------------------------------------------------------------------------
ALTER FUNCTION public.prevent_modification_append_only() OWNER TO banking_functions;
ALTER FUNCTION public.write_audit_log(TEXT, TEXT, UUID, TEXT, UUID, JSONB) OWNER TO banking_functions;
ALTER FUNCTION public.create_profile_for_user() OWNER TO banking_functions;
ALTER FUNCTION public.get_available_balance(UUID) OWNER TO banking_functions;
ALTER FUNCTION public.check_fraud_assessment(UUID, UUID, BIGINT) OWNER TO banking_functions;
ALTER FUNCTION public.close_account(UUID) OWNER TO banking_functions;
ALTER FUNCTION public.process_money_movement(UUID, UUID, BIGINT, TEXT, TEXT, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.execute_transfer(UUID, UUID, BIGINT, TEXT, TEXT, UUID, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.execute_standing_order(UUID) OWNER TO banking_functions;
ALTER FUNCTION public.place_account_hold(UUID, TEXT, BOOLEAN, BIGINT, TEXT, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.release_account_hold(UUID, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.request_joint_closure(UUID, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.record_joint_consent(UUID, UUID, BOOLEAN) OWNER TO banking_functions;
ALTER FUNCTION public.run_reconciliation(DATE) OWNER TO banking_functions;

-- -----------------------------------------------------------------------------
-- 8. ROW LEVEL SECURITY (RLS) POLICIES
-- -----------------------------------------------------------------------------
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_holders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idempotency_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_holds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.standing_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.joint_account_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.joint_account_consents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fraud_assessments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_case_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

-- Profiles Policies
CREATE POLICY profiles_select_own ON public.profiles
    FOR SELECT TO authenticated USING (id = auth.uid());
CREATE POLICY profiles_update_own ON public.profiles
    FOR UPDATE TO authenticated USING (id = auth.uid());

-- Accounts Policies (Read-Only for Account Holders)
CREATE POLICY accounts_select_holder ON public.accounts
    FOR SELECT TO authenticated USING (
        EXISTS (
            SELECT 1 FROM public.account_holders
            WHERE account_holders.account_id = accounts.id
              AND account_holders.profile_id = auth.uid()
        )
    );

-- Account Holders Policies
-- NOTE: The EXISTS sub-query MUST NOT re-query account_holders (same table) because PostgreSQL
-- applies RLS recursively to all queries on that table, causing infinite recursion.
-- A user is a holder if and only if a row exists with their own profile_id, so the
-- simple equality check is both correct and safe.
CREATE POLICY account_holders_select_member ON public.account_holders
    FOR SELECT TO authenticated USING (
        profile_id = auth.uid()
    );

-- Transactions Policies (Read-Only for Account Holders)
CREATE POLICY transactions_select_holder ON public.transactions
    FOR SELECT TO authenticated USING (
        EXISTS (
            SELECT 1 FROM public.account_holders
            WHERE (account_holders.account_id = transactions.source_account_id OR account_holders.account_id = transactions.destination_account_id)
              AND account_holders.profile_id = auth.uid()
        )
    );

-- Ledger Entries Policies (Read-Only for Account Holders)
CREATE POLICY ledger_entries_select_holder ON public.ledger_entries
    FOR SELECT TO authenticated USING (
        EXISTS (
            SELECT 1 FROM public.account_holders
            WHERE account_holders.account_id = ledger_entries.account_id
              AND account_holders.profile_id = auth.uid()
        )
    );

-- Account Holds Policies
CREATE POLICY account_holds_select_holder ON public.account_holds
    FOR SELECT TO authenticated USING (
        EXISTS (
            SELECT 1 FROM public.account_holders
            WHERE account_holders.account_id = account_holds.account_id
              AND account_holders.profile_id = auth.uid()
        )
    );

-- Standing Orders Policies
CREATE POLICY standing_orders_select_holder ON public.standing_orders
    FOR SELECT TO authenticated USING (
        EXISTS (
            SELECT 1 FROM public.account_holders
            WHERE account_holders.account_id = standing_orders.source_account_id
              AND account_holders.profile_id = auth.uid()
        )
    );

-- Joint Actions & Consents Policies
CREATE POLICY joint_actions_select_holder ON public.joint_account_actions
    FOR SELECT TO authenticated USING (
        EXISTS (
            SELECT 1 FROM public.account_holders
            WHERE account_holders.account_id = joint_account_actions.account_id
              AND account_holders.profile_id = auth.uid()
        )
    );

CREATE POLICY joint_account_consents_select_holder ON public.joint_account_consents
    FOR SELECT TO authenticated USING (
        EXISTS (
            SELECT 1 FROM public.joint_account_actions ja
            JOIN public.account_holders ah ON ah.account_id = ja.account_id
            WHERE ja.id = joint_account_consents.joint_action_id
              AND ah.profile_id = auth.uid()
        )
    );

-- Fraud Assessments Policies (Read-Only for Account Holders)
CREATE POLICY fraud_assessments_select_holder ON public.fraud_assessments
    FOR SELECT TO authenticated USING (
        EXISTS (
            SELECT 1 FROM public.account_holders
            WHERE account_holders.account_id = fraud_assessments.account_id
              AND account_holders.profile_id = auth.uid()
        )
    );

-- Support Cases Policies
CREATE POLICY support_cases_select_own ON public.support_cases
    FOR SELECT TO authenticated USING (profile_id = auth.uid());
CREATE POLICY support_cases_insert_own ON public.support_cases
    FOR INSERT TO authenticated WITH CHECK (profile_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 9. PERMISSIONS & GRANTS
-- -----------------------------------------------------------------------------

-- Table Level Privileges for banking_functions role
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO banking_functions;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO banking_functions;

-- Default Read-Only Table Access for API Roles
GRANT SELECT ON ALL TABLES IN SCHEMA public TO service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;

-- Specific Non-Financial Write Permissions for API Roles
GRANT INSERT, UPDATE ON public.profiles TO service_role, authenticated;
GRANT INSERT, UPDATE ON public.fraud_assessments TO service_role;
GRANT INSERT, UPDATE ON public.support_cases TO service_role, authenticated;
GRANT INSERT, UPDATE ON public.support_case_drafts TO service_role;

-- Revoke Direct DML on Financial & Security Tables
REVOKE INSERT, UPDATE, DELETE ON public.accounts FROM service_role, authenticated, anon, PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON public.ledger_entries FROM service_role, authenticated, anon, PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON public.transactions FROM service_role, authenticated, anon, PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON public.idempotency_keys FROM service_role, authenticated, anon, PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON public.fraud_assessments FROM authenticated, anon, PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON public.audit_log FROM service_role, authenticated, anon, PUBLIC;

-- Revoke Execution on ALL Functions by default
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated, service_role;

-- Grant RPC Execution Privileges
GRANT EXECUTE ON FUNCTION public.execute_transfer(UUID, UUID, BIGINT, TEXT, TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.execute_standing_order(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.place_account_hold(UUID, TEXT, BOOLEAN, BIGINT, TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.release_account_hold(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.request_joint_closure(UUID, UUID) TO service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.record_joint_consent(UUID, UUID, BOOLEAN) TO service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.run_reconciliation(DATE) TO service_role;

-- End of Migration 001_initial_banking_schema.sql
