-- Migration 008: cap concurrent loans per person.
--
-- apply_for_loan had no check against a profile already having a loan in
-- flight. Someone could email "I'd like to borrow 200000 rupees" repeatedly
-- and get each one auto-approved and disbursed instantly (each individually
-- under the Rs 200,000 ceiling), completely bypassing the human-review
-- safeguard meant for larger amounts. Fixed: one loan per profile at a time,
-- either pending_review or active -- must be resolved (approved & fully
-- repaid, or rejected) before a new application is accepted.

CREATE OR REPLACE FUNCTION public.apply_for_loan(
    p_profile_id UUID,
    p_account_id UUID,
    p_amount BIGINT,
    p_term_months INT DEFAULT 12
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_account public.accounts%ROWTYPE;
    v_is_holder BOOLEAN;
    v_has_open_loan BOOLEAN;
    v_loan_id UUID;
    v_interest_rate NUMERIC := 10;
    v_total_repayable BIGINT;
    v_monthly_payment BIGINT;
    v_auto_approve_ceiling BIGINT := 20000000;
    v_max_loan_amount BIGINT := 200000000;
    v_disbursement JSONB;
BEGIN
    IF p_amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Loan amount must be positive');
    END IF;

    IF p_amount > v_max_loan_amount THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Requested amount exceeds the maximum loan size we can process by email (Rs 2,000,000). Please visit a branch for larger loans.');
    END IF;

    IF p_term_months <= 0 OR p_term_months > 60 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Loan term must be between 1 and 60 months');
    END IF;

    SELECT * INTO v_account FROM public.accounts WHERE id = p_account_id;
    IF v_account.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Account not found');
    END IF;

    IF v_account.status <> 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Account is not active');
    END IF;

    SELECT EXISTS(
        SELECT 1 FROM public.account_holders WHERE account_id = p_account_id AND profile_id = p_profile_id
    ) INTO v_is_holder;
    IF NOT v_is_holder THEN
        RETURN jsonb_build_object('success', false, 'error', 'Only an account holder may apply for a loan against this account');
    END IF;

    SELECT EXISTS(
        SELECT 1 FROM public.loans WHERE profile_id = p_profile_id AND status IN ('pending_review', 'active')
    ) INTO v_has_open_loan;
    IF v_has_open_loan THEN
        RETURN jsonb_build_object('success', false, 'error',
            'You already have a loan that is active or awaiting review. Please finish repaying it (or wait for the review decision) before applying for another.');
    END IF;

    v_total_repayable := ROUND(p_amount * (1 + (v_interest_rate / 100.0) * (p_term_months / 12.0)));
    v_monthly_payment := CEIL(v_total_repayable::NUMERIC / p_term_months);

    INSERT INTO public.loans (
        profile_id, account_id, principal_amount, interest_rate_pct, term_months,
        total_repayable, monthly_payment_amount, outstanding_balance, status
    ) VALUES (
        p_profile_id, p_account_id, p_amount, v_interest_rate, p_term_months,
        v_total_repayable, v_monthly_payment, v_total_repayable, 'pending_review'
    ) RETURNING id INTO v_loan_id;

    PERFORM public.write_audit_log(
        'loan_requested', 'customer', p_profile_id, 'loan', v_loan_id,
        jsonb_build_object('amount', p_amount, 'term_months', p_term_months)
    );

    IF p_amount <= v_auto_approve_ceiling THEN
        v_disbursement := public.disburse_loan(v_loan_id);
        RETURN v_disbursement || jsonb_build_object('status', 'active', 'auto_approved', true);
    END IF;

    RETURN jsonb_build_object(
        'success', true, 'loan_id', v_loan_id, 'status', 'pending_review', 'auto_approved', false,
        'principal_amount', p_amount, 'total_repayable', v_total_repayable,
        'monthly_payment_amount', v_monthly_payment, 'term_months', p_term_months
    );
END;
$$;

ALTER FUNCTION public.apply_for_loan(UUID, UUID, BIGINT, INT) OWNER TO banking_functions;
REVOKE EXECUTE ON FUNCTION public.apply_for_loan(UUID, UUID, BIGINT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_for_loan(UUID, UUID, BIGINT, INT) TO service_role;
