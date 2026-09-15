-- 016: a customer can now choose the mandate ("both of us must approve" vs
-- "either of us can act") when inviting someone to a joint account, and that
-- choice is applied to the account when the invitation is accepted. Until now
-- accounts.authority_model existed but every joint account silently got the
-- 'either_or' default because nothing ever set it.

DROP FUNCTION IF EXISTS public.create_joint_account_invitation(uuid, text, text, text);

CREATE OR REPLACE FUNCTION public.create_joint_account_invitation(
    p_inviter_profile_id uuid,
    p_invitee_email text,
    p_account_type text DEFAULT 'checking',
    p_currency text DEFAULT 'PKR',
    p_authority_model text DEFAULT 'either_or'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
DECLARE
    v_invitation_id UUID;
    v_expires_at TIMESTAMPTZ;
    v_inviter_email TEXT;
    v_authority TEXT;
BEGIN
    v_authority := COALESCE(NULLIF(btrim(p_authority_model), ''), 'either_or');
    IF v_authority NOT IN ('either_or', 'all_signatures') THEN
        RETURN jsonb_build_object('success', false, 'error',
            'Authority model must be either_or or all_signatures.');
    END IF;

    SELECT email INTO v_inviter_email FROM public.profiles WHERE id = p_inviter_profile_id;
    IF v_inviter_email IS NULL THEN
        RAISE EXCEPTION 'Inviter profile % not found', p_inviter_profile_id;
    END IF;

    IF lower(v_inviter_email) = lower(p_invitee_email) THEN
        RETURN jsonb_build_object('success', false, 'error', 'You cannot invite yourself to a joint account');
    END IF;

    UPDATE public.joint_account_invitations
    SET status = 'expired', updated_at = NOW()
    WHERE inviter_profile_id = p_inviter_profile_id
      AND lower(invitee_email) = lower(p_invitee_email)
      AND status = 'pending';

    INSERT INTO public.joint_account_invitations
        (inviter_profile_id, invitee_email, account_type, currency, authority_model)
    VALUES (p_inviter_profile_id, lower(p_invitee_email), p_account_type, p_currency, v_authority)
    RETURNING id, expires_at INTO v_invitation_id, v_expires_at;

    PERFORM public.write_audit_log(
        'joint_invitation_created', 'customer', p_inviter_profile_id,
        'joint_account_invitation', v_invitation_id,
        jsonb_build_object('invitee_email', p_invitee_email, 'expires_at', v_expires_at,
                           'authority_model', v_authority)
    );

    RETURN jsonb_build_object(
        'success', true, 'invitation_id', v_invitation_id, 'expires_at', v_expires_at,
        'inviter_email', v_inviter_email, 'authority_model', v_authority
    );
END;
$$;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.respond_to_joint_invitation(
    p_invitation_id uuid, p_responder_email text, p_accept boolean,
    p_responder_profile_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
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

    SELECT email, full_name INTO v_inviter_email, v_inviter_name
    FROM public.profiles WHERE id = v_inv.inviter_profile_id;

    IF lower(v_inv.invitee_email) <> lower(p_responder_email) THEN
        RETURN jsonb_build_object('success', false, 'error',
            'This invitation was not addressed to your email address');
    END IF;

    IF v_inv.status <> 'pending' THEN
        RETURN jsonb_build_object('success', true, 'status', v_inv.status, 'already_processed', true,
            'account_id', v_inv.account_id, 'inviter_email', v_inviter_email, 'inviter_name', v_inviter_name);
    END IF;

    IF v_inv.expires_at <= NOW() THEN
        UPDATE public.joint_account_invitations SET status = 'expired', updated_at = NOW()
        WHERE id = p_invitation_id;
        RETURN jsonb_build_object('success', false, 'status', 'expired',
            'error', 'This invitation has expired',
            'inviter_email', v_inviter_email, 'inviter_name', v_inviter_name);
    END IF;

    IF NOT p_accept THEN
        UPDATE public.joint_account_invitations SET status = 'rejected', updated_at = NOW()
        WHERE id = p_invitation_id;
        PERFORM public.write_audit_log('joint_invitation_rejected', 'customer',
            p_responder_profile_id, 'joint_account_invitation', p_invitation_id, '{}'::jsonb);
        RETURN jsonb_build_object('success', true, 'status', 'rejected',
            'inviter_email', v_inviter_email, 'inviter_name', v_inviter_name);
    END IF;

    v_invitee_profile_id := p_responder_profile_id;
    IF v_invitee_profile_id IS NULL THEN
        SELECT id INTO v_invitee_profile_id FROM public.profiles
        WHERE lower(email) = lower(p_responder_email);
    END IF;

    IF v_invitee_profile_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'invitee_profile_required',
            'needs_profile_creation', true,
            'inviter_email', v_inviter_email, 'inviter_name', v_inviter_name);
    END IF;

    v_account_number := 'JNT-' || UPPER(SUBSTRING(REPLACE(gen_random_uuid()::text, '-', '') FROM 1 FOR 10));

    INSERT INTO public.accounts (account_number, account_type, currency, balance, status, authority_model)
    VALUES (v_account_number, v_inv.account_type, v_inv.currency, 0, 'active',
            COALESCE(v_inv.authority_model, 'either_or'))
    RETURNING id INTO v_account_id;

    INSERT INTO public.account_holders (account_id, profile_id, role)
    VALUES (v_account_id, v_inv.inviter_profile_id, 'primary');
    INSERT INTO public.account_holders (account_id, profile_id, role)
    VALUES (v_account_id, v_invitee_profile_id, 'joint');

    UPDATE public.joint_account_invitations
    SET status = 'accepted', account_id = v_account_id, updated_at = NOW()
    WHERE id = p_invitation_id;

    PERFORM public.write_audit_log(
        'joint_account_created', 'customer', v_invitee_profile_id, 'account', v_account_id,
        jsonb_build_object('inviter_profile_id', v_inv.inviter_profile_id,
                           'invitation_id', p_invitation_id,
                           'authority_model', COALESCE(v_inv.authority_model, 'either_or'))
    );

    RETURN jsonb_build_object(
        'success', true, 'status', 'accepted', 'account_id', v_account_id,
        'account_number', v_account_number, 'currency', v_inv.currency,
        'authority_model', COALESCE(v_inv.authority_model, 'either_or'),
        'inviter_email', v_inviter_email, 'inviter_name', v_inviter_name
    );
END;
$$;

ALTER FUNCTION public.create_joint_account_invitation(uuid, text, text, text, text) OWNER TO banking_functions;
ALTER FUNCTION public.respond_to_joint_invitation(uuid, text, boolean, uuid) OWNER TO banking_functions;
REVOKE ALL ON FUNCTION public.create_joint_account_invitation(uuid, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.respond_to_joint_invitation(uuid, text, boolean, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_joint_account_invitation(uuid, text, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.respond_to_joint_invitation(uuid, text, boolean, uuid) TO service_role;
