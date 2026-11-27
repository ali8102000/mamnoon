ALTER TABLE public.service_requests ADD COLUMN provider_role text;
ALTER TABLE public.request_offers ADD COLUMN provider_role text;
ALTER TABLE public.live_locations ADD COLUMN provider_role text;
ALTER TABLE public.trip_location_points ADD COLUMN provider_role text;

UPDATE public.service_requests
SET provider_role=CASE WHEN provider_id IS NULL THEN NULL WHEN type::text='service' THEN 'worker'
 WHEN vehicle_category='large'::public.vehicle_category THEN 'large_driver' ELSE 'driver' END
WHERE provider_role IS NULL;
UPDATE public.request_offers o
SET provider_role=CASE WHEN r.type::text='service' THEN 'worker'
 WHEN r.vehicle_category='large'::public.vehicle_category THEN 'large_driver' ELSE 'driver' END
FROM public.service_requests r WHERE r.id=o.request_id AND o.provider_role IS NULL;
UPDATE public.live_locations l SET provider_role=r.provider_role FROM public.service_requests r
WHERE r.id=l.request_id AND l.role='provider' AND l.provider_role IS NULL;
UPDATE public.trip_location_points p SET provider_role=r.provider_role FROM public.service_requests r
WHERE r.id=p.request_id AND p.role='provider' AND p.provider_role IS NULL;

ALTER TABLE public.service_requests ADD CONSTRAINT service_requests_provider_role_check
 CHECK((provider_id IS NULL AND provider_role IS NULL) OR (provider_id IS NOT NULL AND provider_role IN ('driver','large_driver','worker')));
ALTER TABLE public.request_offers ADD CONSTRAINT request_offers_provider_role_check CHECK(provider_role IS NULL OR provider_role IN ('driver','large_driver','worker'));
ALTER TABLE public.live_locations ADD CONSTRAINT live_locations_provider_role_check CHECK(provider_role IS NULL OR provider_role IN ('driver','large_driver','worker'));
ALTER TABLE public.trip_location_points ADD CONSTRAINT trip_location_points_provider_role_check CHECK(provider_role IS NULL OR provider_role IN ('driver','large_driver','worker'));
CREATE INDEX request_offers_provider_role_status ON public.request_offers(provider_id,provider_role,status,expires_at DESC);
CREATE INDEX service_requests_provider_role_active ON public.service_requests(provider_id,provider_role,status)
 WHERE provider_id IS NOT NULL AND provider_role IS NOT NULL AND status IN ('accepted','in_progress');

CREATE OR REPLACE FUNCTION public.guard_service_request_provider_role()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_role text;
BEGIN
 IF NEW.provider_id IS NULL THEN NEW.provider_role:=NULL; RETURN NEW; END IF;
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
REVOKE ALL ON FUNCTION public.guard_service_request_provider_role() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER trg_guard_service_request_provider_role BEFORE INSERT OR UPDATE OF provider_id,provider_role,type,vehicle_category
 ON public.service_requests FOR EACH ROW EXECUTE FUNCTION public.guard_service_request_provider_role();

CREATE OR REPLACE FUNCTION public.set_request_offer_provider_role()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_type text; v_category text;
BEGIN
 SELECT type::text,vehicle_category::text INTO v_type,v_category FROM public.service_requests WHERE id=NEW.request_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'request_unavailable'; END IF;
 NEW.provider_role:=CASE WHEN v_type='service' THEN 'worker' WHEN v_category='large' THEN 'large_driver' ELSE 'driver' END;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.set_request_offer_provider_role() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER trg_set_request_offer_provider_role BEFORE INSERT OR UPDATE OF request_id,provider_id
 ON public.request_offers FOR EACH ROW EXECUTE FUNCTION public.set_request_offer_provider_role();

CREATE OR REPLACE FUNCTION public.sync_provider_role_presence_from_request()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_user uuid; v_role text; v_online boolean;
BEGIN
 IF TG_OP='UPDATE' AND OLD.provider_id IS NOT NULL AND
   (NEW.provider_id IS DISTINCT FROM OLD.provider_id OR NEW.provider_role IS DISTINCT FROM OLD.provider_role) THEN
  v_user:=OLD.provider_id; v_role:=OLD.provider_role;
  SELECT CASE v_role
   WHEN 'driver' THEN EXISTS(SELECT 1 FROM public.driver_profiles p WHERE p.user_id=v_user AND p.available AND p.status='approved' AND (p.suspended_until IS NULL OR p.suspended_until<=now()))
   WHEN 'large_driver' THEN EXISTS(SELECT 1 FROM public.naqil_profiles p WHERE p.user_id=v_user AND p.available AND p.status='approved' AND (p.suspended_until IS NULL OR p.suspended_until<=now()))
   WHEN 'worker' THEN EXISTS(SELECT 1 FROM public.worker_profiles p WHERE p.user_id=v_user AND p.available AND p.status='approved' AND (p.suspended_until IS NULL OR p.suspended_until<=now()))
   ELSE false END INTO v_online;
  UPDATE public.provider_presence_roles SET status=CASE WHEN EXISTS(SELECT 1 FROM public.service_requests sr WHERE sr.provider_id=v_user AND sr.provider_role=v_role AND sr.status IN ('accepted','in_progress'))
   THEN 'in_trip' ELSE CASE WHEN v_online THEN 'online' ELSE 'offline' END END WHERE user_id=v_user AND role=v_role;
 END IF;
 IF NEW.provider_id IS NOT NULL AND NEW.provider_role IS NOT NULL THEN
  v_user:=NEW.provider_id; v_role:=NEW.provider_role;
  SELECT CASE v_role
   WHEN 'driver' THEN EXISTS(SELECT 1 FROM public.driver_profiles p WHERE p.user_id=v_user AND p.available AND p.status='approved' AND (p.suspended_until IS NULL OR p.suspended_until<=now()))
   WHEN 'large_driver' THEN EXISTS(SELECT 1 FROM public.naqil_profiles p WHERE p.user_id=v_user AND p.available AND p.status='approved' AND (p.suspended_until IS NULL OR p.suspended_until<=now()))
   WHEN 'worker' THEN EXISTS(SELECT 1 FROM public.worker_profiles p WHERE p.user_id=v_user AND p.available AND p.status='approved' AND (p.suspended_until IS NULL OR p.suspended_until<=now()))
   ELSE false END INTO v_online;
  UPDATE public.provider_presence_roles SET status=CASE WHEN NEW.status IN ('accepted','in_progress') THEN 'in_trip' ELSE CASE WHEN v_online THEN 'online' ELSE 'offline' END END
   WHERE user_id=v_user AND role=v_role;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.sync_provider_role_presence_from_request() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER trg_sync_provider_role_presence_from_request AFTER INSERT OR UPDATE OF provider_id,provider_role,status
 ON public.service_requests FOR EACH ROW EXECUTE FUNCTION public.sync_provider_role_presence_from_request();

CREATE OR REPLACE FUNCTION public.sync_provider_role_presence_from_profile()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_role text;
BEGIN
 v_role:=TG_ARGV[0];
 UPDATE public.provider_presence_roles p SET status=CASE
  WHEN EXISTS(SELECT 1 FROM public.service_requests sr WHERE sr.provider_id=NEW.user_id AND sr.provider_role=v_role AND sr.status IN ('accepted','in_progress')) THEN 'in_trip'
  WHEN NEW.available AND NEW.status='approved' AND (NEW.suspended_until IS NULL OR NEW.suspended_until<=now()) THEN 'online'
  ELSE 'offline' END
 WHERE p.user_id=NEW.user_id AND p.role=v_role;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.sync_provider_role_presence_from_profile() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER trg_sync_driver_role_presence AFTER UPDATE OF available,status,suspended_until ON public.driver_profiles
 FOR EACH ROW EXECUTE FUNCTION public.sync_provider_role_presence_from_profile('driver');
CREATE TRIGGER trg_sync_naqil_role_presence AFTER UPDATE OF available,status,suspended_until ON public.naqil_profiles
 FOR EACH ROW EXECUTE FUNCTION public.sync_provider_role_presence_from_profile('large_driver');
CREATE TRIGGER trg_sync_worker_role_presence AFTER UPDATE OF available,status,suspended_until ON public.worker_profiles
 FOR EACH ROW EXECUTE FUNCTION public.sync_provider_role_presence_from_profile('worker');

DROP INDEX IF EXISTS public.uq_one_active_request_per_provider;
DROP INDEX IF EXISTS public.uq_one_active_taxi_per_provider;
CREATE UNIQUE INDEX uq_one_active_request_per_provider_role ON public.service_requests(provider_id,provider_role)
 WHERE provider_id IS NOT NULL AND provider_role IS NOT NULL AND status IN ('accepted','in_progress');

