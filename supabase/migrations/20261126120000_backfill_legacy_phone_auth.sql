-- Attach existing legacy phone/email accounts to Supabase phone auth without marking
-- the phone as verified. The user must still complete SMS OTP before signing in.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE u.phone IS NULL
      AND p.phone ~ '^\\+9647[0-9]{9}$'
      AND EXISTS (
        SELECT 1 FROM auth.users other
        WHERE other.phone = p.phone AND other.id <> u.id
      )
  ) THEN
    RAISE EXCEPTION 'A legacy profile phone is already assigned to another auth user; resolve the conflict before enabling phone OTP.';
  END IF;
END
$$;

UPDATE auth.users u
SET phone = p.phone,
    raw_user_meta_data = COALESCE(u.raw_user_meta_data, '{}'::jsonb)
      || jsonb_build_object('phone', p.phone),
    updated_at = now()
FROM public.profiles p
WHERE p.id = u.id
  AND u.phone IS NULL
  AND p.phone ~ '^\\+9647[0-9]{9}$'
  AND (SELECT count(*) FROM public.profiles duplicate WHERE duplicate.phone = p.phone) = 1
  AND NOT EXISTS (
    SELECT 1 FROM auth.users other
    WHERE other.phone = p.phone AND other.id <> u.id
  );
