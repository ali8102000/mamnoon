ALTER TABLE public.service_requests DROP CONSTRAINT IF EXISTS service_requests_provider_role_check;
ALTER TABLE public.service_requests ADD CONSTRAINT service_requests_provider_role_check
 CHECK (
  (provider_id IS NULL AND (provider_role IS NULL OR provider_role IN ('driver','large_driver','worker')))
  OR
  (provider_id IS NOT NULL AND provider_role IN ('driver','large_driver','worker'))
 );

CREATE OR REPLACE FUNCTION public.guard_service_request_provider_role()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_role text;
BEGIN
 IF NEW.provider_id IS NULL THEN
  IF TG_OP='UPDATE' AND OLD.provider_id IS NOT NULL THEN
   NEW.provider_role:=OLD.provider_role;
  ELSE
   NEW.provider_role:=NULL;
  END IF;
  RETURN NEW;
 END IF;
 v_role:=CASE WHEN NEW.type::text='service' THEN 'worker'
   WHEN NEW.type::text='taxi' AND NEW.vehicle_category='large'::public.vehicle_category THEN 'large_driver'
   WHEN NEW.type::text='taxi' THEN 'driver' ELSE NULL END;
 IF v_role IS NULL THEN RAISE EXCEPTION 'provider_role_cannot_be_resolved'; END IF;
 IF TG_OP='UPDATE' AND NEW.provider_id IS NOT DISTINCT FROM OLD.provider_id AND NEW.provider_role IS DISTINCT FROM OLD.provider_role
 THEN RAISE EXCEPTION 'provider_role_is_immutable_for_assigned_request'; END IF;
 IF NEW.provider_role IS NOT NULL AND NEW.provider_role<>v_role THEN RAISE EXCEPTION 'provider_role_does_not_match_request_type'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.user_roles ur WHERE ur.user_id=NEW.provider_id AND ur.role=v_role::public.app_role)
 THEN RAISE EXCEPTION 'provider_role_not_granted'; END IF;
 IF v_role='driver' AND NOT EXISTS(SELECT 1 FROM public.driver_profiles p WHERE p.user_id=NEW.provider_id AND p.status='approved' AND p.vehicle_category IN ('economy','premium','luxury'))
 THEN RAISE EXCEPTION 'approved_taxi_profile_required'; END IF;
 IF v_role='large_driver' AND NOT EXISTS(SELECT 1 FROM public.naqil_profiles p WHERE p.user_id=NEW.provider_id AND p.status='approved' AND p.vehicle_category='large'::public.vehicle_category)
 THEN RAISE EXCEPTION 'approved_naqil_profile_required'; END IF;
 IF v_role='worker' AND NOT EXISTS(SELECT 1 FROM public.worker_profiles p WHERE p.user_id=NEW.provider_id AND p.status='approved')
 THEN RAISE EXCEPTION 'approved_worker_profile_required'; END IF;
 NEW.provider_role:=v_role; RETURN NEW;
END $$;

