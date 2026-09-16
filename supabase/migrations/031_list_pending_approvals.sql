-- 031_list_pending_approvals.sql
--
-- An alert email can be lost, filed as spam, or deleted. When that happens the
-- approval queue becomes invisible and the request silently expires after seven
-- days -- which is how a customer's loan ends up never being decided by anyone.
-- An operator must be able to ASK what is waiting rather than depending on a
-- message having arrived.
--
-- Emailing the bank "list pending approvals" returns the queue.

CREATE OR REPLACE FUNCTION public.list_pending_approvals(p_operator_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_rows JSONB;
    v_is_admin BOOLEAN;
BEGIN
    IF NOT public.is_bank_staff(p_operator_email) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Only the operations team can list pending approvals.');
    END IF;

    v_is_admin := public.is_bank_admin(p_operator_email);

    SELECT COALESCE(jsonb_agg(r ORDER BY r->>'created_at'), '[]'::jsonb) INTO v_rows
    FROM (
        SELECT jsonb_build_object(
            'ref_code', o.ref_code,
            'request_type', o.request_type,
            'subject', o.subject,
            'requested_for', o.requested_for_email,
            'created_at', to_char(o.created_at, 'YYYY-MM-DD HH24:MI'),
            'expires_at', to_char(o.expires_at, 'YYYY-MM-DD'),
            'days_left', GREATEST(0, EXTRACT(DAY FROM (o.expires_at - NOW()))::int),
            -- Only an administrator can decide who joins the team, so an
            -- ordinary operator is told the request exists but that it is not
            -- theirs to answer.
            'yours_to_decide', (o.request_type <> 'staff_enrolment' OR v_is_admin)
        ) AS r
        FROM public.ops_approvals o
        WHERE o.status = 'pending' AND o.expires_at > NOW()
    ) s;

    RETURN jsonb_build_object('success', true, 'is_admin', v_is_admin,
        'count', jsonb_array_length(v_rows), 'approvals', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.list_pending_approvals(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_pending_approvals(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.list_pending_approvals(TEXT) TO banking_functions;
