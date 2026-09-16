-- 032_guard_staff_activation_against_customers.sql
--
-- The customer/staff separation was only enforced in one direction. Migration
-- 027 put a trigger on `profiles` refusing to create a customer for an address
-- that is bank staff. Nothing stopped the reverse: activating a `bank_staff`
-- row for an address that already holds an account.
--
-- That is reachable in ordinary use. An operator is removed, becomes a customer
-- (which is the documented behaviour -- a removed address is an ordinary member
-- of the public again), and is later re-activated by an administrator. They
-- would then be both, which is precisely the combination the separation exists
-- to prevent: an operator can act on any account, and that would include their
-- own.
--
-- `enrol_bank_staff()` already refuses it on the way in. This is the floor
-- under that, for any path that writes the table directly.

CREATE OR REPLACE FUNCTION public.guard_customer_not_staff()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.is_active AND EXISTS (
        SELECT 1 FROM public.profiles WHERE lower(email) = lower(NEW.email)
    ) THEN
        RAISE EXCEPTION
            'Address % holds a customer account and cannot be active bank staff.',
            NEW.email;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_customer_not_staff ON public.bank_staff;
CREATE TRIGGER trg_guard_customer_not_staff
    BEFORE INSERT OR UPDATE OF email, is_active ON public.bank_staff
    FOR EACH ROW EXECUTE FUNCTION public.guard_customer_not_staff();
