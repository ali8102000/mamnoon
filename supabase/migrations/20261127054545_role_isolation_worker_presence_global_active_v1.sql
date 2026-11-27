CREATE OR REPLACE FUNCTION public.sync_worker_team_presence_for_request(_request_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 UPDATE public.provider_presence_roles p
 SET status=CASE
  WHEN EXISTS(SELECT 1 FROM public.service_requests r WHERE r.provider_id=p.user_id AND r.provider_role='worker' AND r.status IN ('accepted','in_progress'))
    OR EXISTS(SELECT 1 FROM public.service_request_providers srp2 JOIN public.service_requests r2 ON r2.id=srp2.request_id
      WHERE srp2.provider_id=p.user_id AND r2.status IN ('accepted','in_progress')) THEN 'in_trip'
  WHEN wp.available AND wp.status='approved' AND (wp.suspended_until IS NULL OR wp.suspended_until<=now()) THEN 'online'
  ELSE 'offline' END
 FROM public.service_request_providers srp
 JOIN public.worker_profiles wp ON wp.user_id=srp.provider_id
 WHERE srp.request_id=_request_id AND p.user_id=srp.provider_id AND p.role='worker';
END $$;

CREATE OR REPLACE FUNCTION public.sync_provider_role_presence_from_request()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_user uuid; v_role text; v_online boolean; v_active boolean;
BEGIN
 IF TG_OP='UPDATE' AND OLD.provider_id IS NOT NULL AND
   (NEW.provider_id IS DISTINCT FROM OLD.provider_id OR NEW.provider_role IS DISTINCT FROM OLD.provider_role) THEN
  v_user:=OLD.provider_id; v_role:=OLD.provider_role;
  SELECT CASE v_role
   WHEN 'driver' THEN EXISTS(SELECT 1 FROM public.driver_profiles p WHERE p.user_id=v_user AND p.available AND p.status='approved' AND (p.suspended_until IS NULL OR p.suspended_until<=now()))
   WHEN 'large_driver' THEN EXISTS(SELECT 1 FROM public.naqil_profiles p WHERE p.user_id=v_user AND p.available AND p.status='approved' AND (p.suspended_until IS NULL OR p.suspended_until<=now()))
   WHEN 'worker' THEN EXISTS(SELECT 1 FROM public.worker_profiles p WHERE p.user_id=v_user AND p.available AND p.status='approved' AND (p.suspended_until IS NULL OR p.suspended_until<=now()))
   ELSE false END INTO v_online;
  SELECT EXISTS(SELECT 1 FROM public.service_requests sr WHERE sr.provider_id=v_user AND sr.provider_role=v_role AND sr.status IN ('accepted','in_progress'))
   OR (v_role='worker' AND EXISTS(SELECT 1 FROM public.service_request_providers srp JOIN public.service_requests sr ON sr.id=srp.request_id
      WHERE srp.provider_id=v_user AND sr.status IN ('accepted','in_progress'))) INTO v_active;
  UPDATE public.provider_presence_roles SET status=CASE WHEN v_active THEN 'in_trip' WHEN v_online THEN 'online' ELSE 'offline' END
   WHERE user_id=v_user AND role=v_role;
 END IF;
 IF NEW.provider_id IS NOT NULL AND NEW.provider_role IS NOT NULL THEN
  v_user:=NEW.provider_id; v_role:=NEW.provider_role;
  SELECT CASE v_role
   WHEN 'driver' THEN EXISTS(SELECT 1 FROM public.driver_profiles p WHERE p.user_id=v_user AND p.available AND p.status='approved' AND (p.suspended_until IS NULL OR p.suspended_until<=now()))
   WHEN 'large_driver' THEN EXISTS(SELECT 1 FROM public.naqil_profiles p WHERE p.user_id=v_user AND p.available AND p.status='approved' AND (p.suspended_until IS NULL OR p.suspended_until<=now()))
   WHEN 'worker' THEN EXISTS(SELECT 1 FROM public.worker_profiles p WHERE p.user_id=v_user AND p.available AND p.status='approved' AND (p.suspended_until IS NULL OR p.suspended_until<=now()))
   ELSE false END INTO v_online;
  SELECT EXISTS(SELECT 1 FROM public.service_requests sr WHERE sr.provider_id=v_user AND sr.provider_role=v_role AND sr.status IN ('accepted','in_progress'))
   OR (v_role='worker' AND EXISTS(SELECT 1 FROM public.service_request_providers srp JOIN public.service_requests sr ON sr.id=srp.request_id
      WHERE srp.provider_id=v_user AND sr.status IN ('accepted','in_progress'))) INTO v_active;
  UPDATE public.provider_presence_roles SET status=CASE WHEN NEW.status IN ('accepted','in_progress') OR v_active THEN 'in_trip'
   WHEN v_online THEN 'online' ELSE 'offline' END WHERE user_id=v_user AND role=v_role;
 END IF;
 RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.sync_provider_role_presence_from_profile()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_role text;
BEGIN
 v_role:=TG_ARGV[0];
 UPDATE public.provider_presence_roles p SET status=CASE
  WHEN EXISTS(SELECT 1 FROM public.service_requests sr WHERE sr.provider_id=NEW.user_id AND sr.provider_role=v_role AND sr.status IN ('accepted','in_progress'))
    OR (v_role='worker' AND EXISTS(SELECT 1 FROM public.service_request_providers srp JOIN public.service_requests sr ON sr.id=srp.request_id
      WHERE srp.provider_id=NEW.user_id AND sr.status IN ('accepted','in_progress'))) THEN 'in_trip'
  WHEN NEW.available AND NEW.status='approved' AND (NEW.suspended_until IS NULL OR NEW.suspended_until<=now()) THEN 'online'
  ELSE 'offline' END
 WHERE p.user_id=NEW.user_id AND p.role=v_role;
 RETURN NEW;
END $$;

