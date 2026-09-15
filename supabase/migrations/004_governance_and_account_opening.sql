-- =============================================================================
-- MIGRATION: 004_governance_and_account_opening.sql
-- DESCRIPTION: Implements the previously-scoped-out edge cases from the capstone
--              feature list: self-service account opening, either-or vs
--              both-signature transfer authority, majority-vote closure for 3+
--              holders, minor/guardian accounts with an age-based promotion
--              trigger, adding a holder to an account with active holds, and a
--              weekend/holiday rule for standing orders.
--
-- Backward compatible: every new column has a default that preserves today's
-- behavior exactly (either_or authority, unanimous closure, adult holders,
-- next-business-day standing orders). No existing data or RPC caller breaks.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. SCHEMA ADDITIONS
-- -----------------------------------------------------------------------------

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS date_of_birth DATE;

ALTER TABLE public.account_holders
  ADD COLUMN IF NOT EXISTS holder_type TEXT NOT NULL DEFAULT 'adult'
    CHECK (holder_type IN ('adult', 'minor', 'guardian')),
  ADD COLUMN IF NOT EXISTS guardian_of_profile_id UUID REFERENCES public.profiles(id);
-- holder_type='minor': view-only, cannot initiate transfers (enforced in n8n's
--   authorization step, mirrored by is_holder_transfer_authorized() below).
-- holder_type='guardian': acts on behalf of the minor named in guardian_of_profile_id,
--   who must also be a holder (holder_type='minor') on the same account.

ALTER TABLE public.accounts
  ADD COLUMN IF NOT EXISTS authority_model TEXT NOT NULL DEFAULT 'either_or'
    CHECK (authority_model IN ('either_or', 'all_signatures')),
  ADD COLUMN IF NOT EXISTS closure_authority TEXT NOT NULL DEFAULT 'unanimous'
    CHECK (closure_authority IN ('unanimous', 'majority'));
-- authority_model: 'either_or' (default) - any holder can transfer unilaterally.
--   'all_signatures' - a transfer only executes once every holder has consented.
-- closure_authority: 'unanimous' (default, and always used for 2-holder accounts).
--   'majority' only takes effect for accounts with 3+ holders (see decisions.md #5).

ALTER TABLE public.standing_orders
  ADD COLUMN IF NOT EXISTS weekend_holiday_rule TEXT NOT NULL DEFAULT 'next_business_day'
    CHECK (weekend_holiday_rule IN ('next_business_day', 'process_early', 'allow_weekend'));

-- Widen joint_account_actions to cover transfer approvals and holder additions,
-- not just closure, and give it a payload column to carry action-specific data.
ALTER TABLE public.joint_account_actions
  DROP CONSTRAINT IF EXISTS joint_account_actions_action_type_check;
ALTER TABLE public.joint_account_actions
  ADD CONSTRAINT joint_account_actions_action_type_check
    CHECK (action_type IN ('close_account', 'transfer_approval', 'add_holder'));
ALTER TABLE public.joint_account_actions
  ADD COLUMN IF NOT EXISTS payload JSONB NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS idx_account_holders_holder_type ON public.account_holders(holder_type);

-- -----------------------------------------------------------------------------
-- 2. SELF-SERVICE ACCOUNT OPENING
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.open_account_for_profile(
    p_profile_id UUID,
    p_account_type TEXT,
    p_currency TEXT DEFAULT 'USD',
    p_holder_type TEXT DEFAULT 'adult',
    p_guardian_profile_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_account_id UUID;
    v_account_number TEXT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_profile_id) THEN
        RAISE EXCEPTION 'Profile % not found', p_profile_id;
    END IF;

    IF p_holder_type NOT IN ('adult', 'minor') THEN
        RAISE EXCEPTION 'p_holder_type for the primary holder must be adult or minor (guardian is added separately)';
    END IF;

    IF p_holder_type = 'minor' AND p_guardian_profile_id IS NULL THEN
        RAISE EXCEPTION 'A minor account requires a guardian profile id';
    END IF;

    IF p_guardian_profile_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_guardian_profile_id) THEN
        RAISE EXCEPTION 'Guardian profile % not found', p_guardian_profile_id;
    END IF;

    v_account_number := 'ACC-' || UPPER(SUBSTRING(REPLACE(gen_random_uuid()::text, '-', '') FROM 1 FOR 10));

    INSERT INTO public.accounts (account_number, account_type, currency, balance, status)
    VALUES (v_account_number, p_account_type, p_currency, 0, 'active')
    RETURNING id INTO v_account_id;

    INSERT INTO public.account_holders (account_id, profile_id, role, holder_type)
    VALUES (v_account_id, p_profile_id, 'primary', p_holder_type);

    IF p_guardian_profile_id IS NOT NULL THEN
        INSERT INTO public.account_holders (account_id, profile_id, role, holder_type, guardian_of_profile_id)
        VALUES (v_account_id, p_guardian_profile_id, 'joint', 'guardian', p_profile_id);
    END IF;

    PERFORM public.write_audit_log(
        'account_opened', 'customer', p_profile_id, 'account', v_account_id,
        jsonb_build_object(
            'account_type', p_account_type, 'currency', p_currency,
            'holder_type', p_holder_type, 'guardian_profile_id', p_guardian_profile_id
        )
    );

    RETURN jsonb_build_object(
        'success', true, 'account_id', v_account_id, 'account_number', v_account_number,
        'account_type', p_account_type, 'currency', p_currency, 'holder_type', p_holder_type
    );
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. ADDING A HOLDER TO AN ACCOUNT WITH ACTIVE HOLDS
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.add_account_holder(
    p_account_id UUID,
    p_new_profile_id UUID,
    p_role TEXT,
    p_requested_by_profile_id UUID,
    p_acknowledge_active_holds BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_active_holds INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.accounts WHERE id = p_account_id) THEN
        RAISE EXCEPTION 'Account % not found', p_account_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = p_account_id AND profile_id = p_requested_by_profile_id
    ) THEN
        RAISE EXCEPTION 'Profile % is not an existing holder of account %, cannot request a holder addition', p_requested_by_profile_id, p_account_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_new_profile_id) THEN
        RAISE EXCEPTION 'New holder profile % not found', p_new_profile_id;
    END IF;

    IF EXISTS (SELECT 1 FROM public.account_holders WHERE account_id = p_account_id AND profile_id = p_new_profile_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'Profile is already a holder of this account');
    END IF;

    SELECT COUNT(*) INTO v_active_holds
    FROM public.account_holds
    WHERE account_id = p_account_id AND status = 'active';

    -- Decision (see docs/decisions.md #8): adding a holder to an account with an
    -- active hold is allowed, but only with explicit acknowledgment -- never silently.
    IF v_active_holds > 0 AND NOT p_acknowledge_active_holds THEN
        RETURN jsonb_build_object(
            'success', false,
            'requires_acknowledgment', true,
            'active_holds_count', v_active_holds,
            'error', 'Account has active holds. Adding a holder requires explicit acknowledgment.'
        );
    END IF;

    INSERT INTO public.account_holders (account_id, profile_id, role)
    VALUES (p_account_id, p_new_profile_id, p_role);

    PERFORM public.write_audit_log(
        'holder_added', 'customer', p_requested_by_profile_id, 'account', p_account_id,
        jsonb_build_object(
            'new_profile_id', p_new_profile_id, 'role', p_role,
            'active_holds_acknowledged', v_active_holds > 0
        )
    );

    RETURN jsonb_build_object(
        'success', true, 'account_id', p_account_id, 'new_profile_id', p_new_profile_id,
        'role', p_role, 'active_holds_present', v_active_holds > 0
    );
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. GENERALIZED JOINT ACTION FINALIZATION (closure / transfer approval / add holder)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.finalize_joint_action_if_complete(p_joint_action_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_action public.joint_account_actions%ROWTYPE;
    v_account public.accounts%ROWTYPE;
    v_total_holders INT;
    v_consents_count INT;
    v_required INT;
    v_result JSONB;
BEGIN
    SELECT * INTO v_action FROM public.joint_account_actions WHERE id = p_joint_action_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Joint action % not found', p_joint_action_id;
    END IF;

    IF v_action.status <> 'pending' THEN
        RETURN jsonb_build_object('success', true, 'joint_action_id', p_joint_action_id, 'status', v_action.status);
    END IF;

    SELECT * INTO v_account FROM public.accounts WHERE id = v_action.account_id;

    SELECT COUNT(*) INTO v_total_holders FROM public.account_holders WHERE account_id = v_action.account_id;
    SELECT COUNT(*) INTO v_consents_count
    FROM public.joint_account_consents
    WHERE joint_action_id = p_joint_action_id AND consent = TRUE;

    -- Majority-vote governance only ever applies to closure, and only for 3+
    -- holder accounts that have opted into it (see docs/decisions.md #5).
    -- Transfer approvals and holder additions always require every holder.
    IF v_action.action_type = 'close_account' AND v_account.closure_authority = 'majority' AND v_total_holders >= 3 THEN
        v_required := FLOOR(v_total_holders / 2.0) + 1;
    ELSE
        v_required := v_total_holders;
    END IF;

    IF v_consents_count < v_required THEN
        RETURN jsonb_build_object(
            'success', true, 'joint_action_id', p_joint_action_id, 'status', 'pending',
            'requires_additional_signatures', true,
            'consents_count', v_consents_count, 'required', v_required
        );
    END IF;

    UPDATE public.joint_account_actions SET status = 'approved', updated_at = NOW() WHERE id = p_joint_action_id;

    IF v_action.action_type = 'close_account' THEN
        PERFORM public.close_account(v_action.account_id);
        v_result := jsonb_build_object('success', true, 'status', 'approved', 'executed_action', 'close_account');
    ELSIF v_action.action_type = 'transfer_approval' THEN
        v_result := public.execute_transfer(
            v_action.account_id,
            (v_action.payload ->> 'destination_account_id')::UUID,
            (v_action.payload ->> 'amount')::BIGINT,
            v_action.payload ->> 'currency',
            v_action.payload ->> 'idempotency_key',
            v_action.requested_by_profile_id,
            (v_action.payload ->> 'fraud_assessment_id')::UUID
        );
    ELSIF v_action.action_type = 'add_holder' THEN
        v_result := public.add_account_holder(
            v_action.account_id,
            (v_action.payload ->> 'new_profile_id')::UUID,
            COALESCE(v_action.payload ->> 'role', 'joint'),
            v_action.requested_by_profile_id,
            TRUE
        );
    END IF;

    PERFORM public.write_audit_log(
        'joint_action_finalized', 'system', NULL, 'joint_account_action', p_joint_action_id,
        jsonb_build_object('action_type', v_action.action_type, 'consents_count', v_consents_count, 'required', v_required)
    );

    RETURN v_result || jsonb_build_object('joint_action_id', p_joint_action_id);
END;
$$;

-- request_joint_closure and record_joint_consent are refactored to delegate to
-- the shared finalize helper above, instead of duplicating the unanimous-count
-- logic inline. Signatures are unchanged -- fully backward compatible.

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
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = p_account_id AND profile_id = p_requested_by_profile_id
    ) THEN
        RAISE EXCEPTION 'Profile % is not an account holder of %', p_requested_by_profile_id, p_account_id;
    END IF;

    INSERT INTO public.joint_account_actions (account_id, action_type, status, requested_by_profile_id, expires_at)
    VALUES (p_account_id, 'close_account', 'pending', p_requested_by_profile_id, NOW() + INTERVAL '7 days')
    RETURNING id INTO v_action_id;

    INSERT INTO public.joint_account_consents (joint_action_id, profile_id, consent)
    VALUES (v_action_id, p_requested_by_profile_id, TRUE);

    PERFORM public.write_audit_log(
        'joint_closure_requested', 'customer', p_requested_by_profile_id, 'joint_account_action', v_action_id,
        jsonb_build_object('account_id', p_account_id)
    );

    RETURN public.finalize_joint_action_if_complete(v_action_id);
END;
$$;

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
BEGIN
    SELECT * INTO v_action FROM public.joint_account_actions WHERE id = p_joint_action_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Joint action % not found', p_joint_action_id;
    END IF;

    IF v_action.status <> 'pending' THEN
        RAISE EXCEPTION 'Joint action % is already %', p_joint_action_id, v_action.status;
    END IF;

    IF v_action.expires_at IS NOT NULL AND v_action.expires_at <= NOW() THEN
        UPDATE public.joint_account_actions SET status = 'expired', updated_at = NOW() WHERE id = p_joint_action_id;
        RAISE EXCEPTION 'Joint action % has expired', p_joint_action_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = v_action.account_id AND profile_id = p_profile_id
    ) THEN
        RAISE EXCEPTION 'Profile % is not an account holder of %', p_profile_id, v_action.account_id;
    END IF;

    INSERT INTO public.joint_account_consents (joint_action_id, profile_id, consent)
    VALUES (p_joint_action_id, p_profile_id, p_consent)
    ON CONFLICT (joint_action_id, profile_id)
    DO UPDATE SET consent = EXCLUDED.consent, created_at = NOW();

    PERFORM public.write_audit_log(
        'joint_consent_recorded', 'customer', p_profile_id, 'joint_account_consent', p_joint_action_id,
        jsonb_build_object('consent', p_consent, 'action_type', v_action.action_type)
    );

    IF NOT p_consent THEN
        UPDATE public.joint_account_actions SET status = 'rejected', updated_at = NOW() WHERE id = p_joint_action_id;
        RETURN jsonb_build_object('success', true, 'joint_action_id', p_joint_action_id, 'status', 'rejected');
    END IF;

    RETURN public.finalize_joint_action_if_complete(p_joint_action_id);
END;
$$;

-- -----------------------------------------------------------------------------
-- 5. EITHER-OR VS BOTH-SIGNATURE TRANSFER AUTHORITY
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.request_transfer_approval(
    p_source_account_id UUID,
    p_destination_account_id UUID,
    p_amount BIGINT,
    p_currency TEXT,
    p_idempotency_key TEXT,
    p_fraud_assessment_id UUID,
    p_initiated_by_profile_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_action_id UUID;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.account_holders
        WHERE account_id = p_source_account_id AND profile_id = p_initiated_by_profile_id
    ) THEN
        RAISE EXCEPTION 'Profile % is not a holder of account %', p_initiated_by_profile_id, p_source_account_id;
    END IF;

    INSERT INTO public.joint_account_actions (account_id, action_type, status, requested_by_profile_id, payload)
    VALUES (
        p_source_account_id, 'transfer_approval', 'pending', p_initiated_by_profile_id,
        jsonb_build_object(
            'destination_account_id', p_destination_account_id,
            'amount', p_amount,
            'currency', p_currency,
            'idempotency_key', p_idempotency_key,
            'fraud_assessment_id', p_fraud_assessment_id
        )
    ) RETURNING id INTO v_action_id;

    INSERT INTO public.joint_account_consents (joint_action_id, profile_id, consent)
    VALUES (v_action_id, p_initiated_by_profile_id, TRUE);

    PERFORM public.write_audit_log(
        'transfer_approval_requested', 'customer', p_initiated_by_profile_id, 'joint_account_action', v_action_id,
        jsonb_build_object('account_id', p_source_account_id, 'amount', p_amount, 'destination_account_id', p_destination_account_id)
    );

    RETURN public.finalize_joint_action_if_complete(v_action_id);
END;
$$;

-- Drop-in replacement entry point for n8n: same signature as execute_transfer.
-- Routes to immediate execution (either_or, the default) or a pending
-- multi-signature approval (all_signatures, 2+ holders).
CREATE OR REPLACE FUNCTION public.initiate_transfer(
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
    v_source public.accounts%ROWTYPE;
    v_total_holders INT;
BEGIN
    SELECT * INTO v_source FROM public.accounts WHERE id = p_source_account_id;
    IF v_source.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Source account not found');
    END IF;

    SELECT COUNT(*) INTO v_total_holders FROM public.account_holders WHERE account_id = p_source_account_id;

    IF v_source.authority_model = 'all_signatures' AND v_total_holders > 1 THEN
        RETURN public.request_transfer_approval(
            p_source_account_id, p_destination_account_id, p_amount, p_currency,
            p_idempotency_key, p_fraud_assessment_id, p_initiated_by_profile_id
        );
    END IF;

    RETURN public.execute_transfer(
        p_source_account_id, p_destination_account_id, p_amount, p_currency,
        p_idempotency_key, p_initiated_by_profile_id, p_fraud_assessment_id
    );
END;
$$;

-- -----------------------------------------------------------------------------
-- 6. MINOR/GUARDIAN ACCOUNTS -- AGE-BASED PROMOTION TRIGGER
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_holder_transfer_authorized(p_account_id UUID, p_profile_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_holder_type TEXT;
BEGIN
    SELECT holder_type INTO v_holder_type
    FROM public.account_holders
    WHERE account_id = p_account_id AND profile_id = p_profile_id;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- Minors can view balances but never initiate transfers; guardians and adults can.
    RETURN v_holder_type IN ('adult', 'guardian');
END;
$$;

CREATE OR REPLACE FUNCTION public.promote_minors_to_adult()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_promoted JSONB := '[]'::jsonb;
    v_row RECORD;
BEGIN
    FOR v_row IN
        SELECT ah.id AS holder_id, ah.account_id, ah.profile_id
        FROM public.account_holders ah
        JOIN public.profiles p ON p.id = ah.profile_id
        WHERE ah.holder_type = 'minor'
          AND p.date_of_birth IS NOT NULL
          AND p.date_of_birth <= (CURRENT_DATE - INTERVAL '18 years')
    LOOP
        UPDATE public.account_holders SET holder_type = 'adult' WHERE id = v_row.holder_id;
        v_promoted := v_promoted || jsonb_build_object(
            'holder_id', v_row.holder_id, 'account_id', v_row.account_id, 'profile_id', v_row.profile_id
        );
        PERFORM public.write_audit_log(
            'minor_promoted_to_adult', 'system', NULL, 'account_holder', v_row.holder_id,
            jsonb_build_object('account_id', v_row.account_id, 'profile_id', v_row.profile_id)
        );
    END LOOP;

    RETURN jsonb_build_object('success', true, 'promoted_count', jsonb_array_length(v_promoted), 'promoted', v_promoted);
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. WEEKEND/HOLIDAY STANDING ORDER SCHEDULING RULE
-- Redefinition of execute_standing_order(), identical to 001's version except
-- for the weekend-adjustment block applied to both next-execution calculations
-- (the "already executed this slot" replay branch, and the real success branch).
-- -----------------------------------------------------------------------------

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

            -- Weekend/holiday rule (see docs/decisions.md #15)
            IF v_order.weekend_holiday_rule = 'next_business_day' THEN
                WHILE EXTRACT(DOW FROM v_next_exec) IN (0, 6) LOOP
                    v_next_exec := v_next_exec + INTERVAL '1 day';
                END LOOP;
            ELSIF v_order.weekend_holiday_rule = 'process_early' THEN
                WHILE EXTRACT(DOW FROM v_next_exec) IN (0, 6) LOOP
                    v_next_exec := v_next_exec - INTERVAL '1 day';
                END LOOP;
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
                UPDATE public.idempotency_keys
                SET locked_at = NOW()
                WHERE key = v_idempotency_key;
            END IF;
        END IF;
    ELSE
        INSERT INTO public.idempotency_keys (key, request_hash, status, locked_at)
        VALUES (v_idempotency_key, MD5(v_idempotency_key), 'processing', NOW());
    END IF;

    UPDATE public.standing_orders
    SET execution_locked_at = NOW()
    WHERE id = p_standing_order_id;

    BEGIN
        v_transaction_id := public.process_money_movement(
            v_order.source_account_id,
            v_order.destination_account_id,
            v_order.amount,
            v_order.currency,
            'Recurring standing order payment',
            NULL
        );

        UPDATE public.idempotency_keys
        SET status = 'completed',
            transaction_id = v_transaction_id,
            response_body = jsonb_build_object('success', true, 'transaction_id', v_transaction_id)
        WHERE key = v_idempotency_key;

        IF v_order.frequency = 'daily' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 day';
        ELSIF v_order.frequency = 'weekly' THEN v_next_exec := v_order.next_execution_at + INTERVAL '1 week';
        ELSE v_next_exec := v_order.next_execution_at + INTERVAL '1 month';
        END IF;

        -- Weekend/holiday rule (see docs/decisions.md #15)
        IF v_order.weekend_holiday_rule = 'next_business_day' THEN
            WHILE EXTRACT(DOW FROM v_next_exec) IN (0, 6) LOOP
                v_next_exec := v_next_exec + INTERVAL '1 day';
            END LOOP;
        ELSIF v_order.weekend_holiday_rule = 'process_early' THEN
            WHILE EXTRACT(DOW FROM v_next_exec) IN (0, 6) LOOP
                v_next_exec := v_next_exec - INTERVAL '1 day';
            END LOOP;
        END IF;

        UPDATE public.standing_orders
        SET next_execution_at = v_next_exec,
            execution_locked_at = NULL,
            retry_count = 0,
            last_error = NULL,
            updated_at = NOW()
        WHERE id = p_standing_order_id;

        PERFORM public.write_audit_log(
            'standing_order_executed', 'system', NULL, 'standing_order', p_standing_order_id,
            jsonb_build_object('transaction_id', v_transaction_id, 'next_execution_at', v_next_exec)
        );

        RETURN jsonb_build_object(
            'success', true,
            'standing_order_id', p_standing_order_id,
            'transaction_id', v_transaction_id,
            'next_execution_at', v_next_exec
        );

    EXCEPTION WHEN OTHERS THEN
        v_err_msg := SQLERRM;

        UPDATE public.idempotency_keys
        SET status = 'failed',
            response_body = jsonb_build_object('success', false, 'error', v_err_msg)
        WHERE key = v_idempotency_key;

        UPDATE public.standing_orders
        SET retry_count = v_order.retry_count + 1,
            last_error = v_err_msg,
            status = CASE WHEN v_order.retry_count + 1 >= 3 THEN 'failed' ELSE v_order.status END,
            execution_locked_at = NULL,
            updated_at = NOW()
        WHERE id = p_standing_order_id;

        PERFORM public.write_audit_log(
            'standing_order_failed', 'system', NULL, 'standing_order', p_standing_order_id,
            jsonb_build_object(
                'reason', v_err_msg, 'retry_count', v_order.retry_count + 1,
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

-- -----------------------------------------------------------------------------
-- 8. OWNERSHIP + GRANTS
-- Follows the existing security model exactly: every financial/governance
-- function is owned by banking_functions and callable only by service_role.
-- Also hardens the functions that migration 001 left implicitly executable by
-- PUBLIC (the default in Postgres) -- closing a latent gap, not one this
-- migration introduced.
-- -----------------------------------------------------------------------------

ALTER FUNCTION public.open_account_for_profile(UUID, TEXT, TEXT, TEXT, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.add_account_holder(UUID, UUID, TEXT, UUID, BOOLEAN) OWNER TO banking_functions;
ALTER FUNCTION public.finalize_joint_action_if_complete(UUID) OWNER TO banking_functions;
ALTER FUNCTION public.request_transfer_approval(UUID, UUID, BIGINT, TEXT, TEXT, UUID, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.initiate_transfer(UUID, UUID, BIGINT, TEXT, TEXT, UUID, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.is_holder_transfer_authorized(UUID, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.promote_minors_to_adult() OWNER TO banking_functions;
ALTER FUNCTION public.execute_standing_order(UUID) OWNER TO banking_functions;
ALTER FUNCTION public.request_joint_closure(UUID, UUID) OWNER TO banking_functions;
ALTER FUNCTION public.record_joint_consent(UUID, UUID, BOOLEAN) OWNER TO banking_functions;

REVOKE EXECUTE ON FUNCTION public.open_account_for_profile(UUID, TEXT, TEXT, TEXT, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.add_account_holder(UUID, UUID, TEXT, UUID, BOOLEAN) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.finalize_joint_action_if_complete(UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.request_transfer_approval(UUID, UUID, BIGINT, TEXT, TEXT, UUID, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.initiate_transfer(UUID, UUID, BIGINT, TEXT, TEXT, UUID, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.is_holder_transfer_authorized(UUID, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.promote_minors_to_adult() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.execute_transfer(UUID, UUID, BIGINT, TEXT, TEXT, UUID, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.execute_standing_order(UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.place_account_hold(UUID, TEXT, BOOLEAN, BIGINT, TEXT, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.release_account_hold(UUID, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.request_joint_closure(UUID, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_joint_consent(UUID, UUID, BOOLEAN) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.run_reconciliation(DATE) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.open_account_for_profile(UUID, TEXT, TEXT, TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.add_account_holder(UUID, UUID, TEXT, UUID, BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_joint_action_if_complete(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.request_transfer_approval(UUID, UUID, BIGINT, TEXT, TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.initiate_transfer(UUID, UUID, BIGINT, TEXT, TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.is_holder_transfer_authorized(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.promote_minors_to_adult() TO service_role;
GRANT EXECUTE ON FUNCTION public.execute_transfer(UUID, UUID, BIGINT, TEXT, TEXT, UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.execute_standing_order(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.place_account_hold(UUID, TEXT, BOOLEAN, BIGINT, TEXT, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.release_account_hold(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.request_joint_closure(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.record_joint_consent(UUID, UUID, BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION public.run_reconciliation(DATE) TO service_role;

-- End of Migration 004_governance_and_account_opening.sql
