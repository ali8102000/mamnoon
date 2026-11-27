CREATE OR REPLACE FUNCTION public.guard_worker_team_assignment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_request_type text;
BEGIN
 SELECT type::text INTO v_request_type FROM public.service_requests WHERE id=NEW.request_id;
 IF NOT FOUND OR v_request_type<>'service' THEN RAISE EXCEPTION 'worker_team_requires_service_request'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.user_roles ur WHERE ur.user_id=NEW.provider_id AND ur.role='worker')
  OR NOT EXISTS(SELECT 1 FROM public.worker_profiles wp WHERE wp.user_id=NEW.provider_id AND wp.status='approved') THEN
  RAISE EXCEPTION 'approved_worker_profile_required';
 END IF;
 IF EXISTS(
  SELECT 1 FROM public.service_requests r
  WHERE r.provider_id=NEW.provider_id AND r.provider_role='worker'
   AND r.id<>NEW.request_id AND r.status IN ('pending','searching','accepted','in_progress')
 ) OR EXISTS(
  SELECT 1 FROM public.service_request_providers srp
  JOIN public.service_requests r ON r.id=srp.request_id
  WHERE srp.provider_id=NEW.provider_id AND srp.request_id<>NEW.request_id
   AND r.status IN ('pending','searching','accepted','in_progress')
 ) THEN RAISE EXCEPTION 'worker_has_active_request'; END IF;
 RETURN NEW;
END $$;

