CREATE TABLE public.naqil_profiles (
  LIKE public.driver_profiles INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING COMMENTS
);
ALTER TABLE public.naqil_profiles
  ADD CONSTRAINT naqil_profiles_pkey PRIMARY KEY (user_id),
  ADD CONSTRAINT naqil_profiles_id_key UNIQUE (id),
  ADD CONSTRAINT naqil_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE,
  ADD CONSTRAINT naqil_profiles_category_only_large CHECK (vehicle_category IS NULL OR vehicle_category = 'large'::public.vehicle_category);

INSERT INTO public.naqil_profiles SELECT * FROM public.driver_profiles
WHERE vehicle_category = 'large'::public.vehicle_category
ON CONFLICT (user_id) DO UPDATE SET
 available=EXCLUDED.available, vehicle_make=EXCLUDED.vehicle_make, vehicle_model=EXCLUDED.vehicle_model,
 vehicle_year=EXCLUDED.vehicle_year, vehicle_plate=EXCLUDED.vehicle_plate, vehicle_color=EXCLUDED.vehicle_color,
 vehicle_category=EXCLUDED.vehicle_category, status=EXCLUDED.status, rating_avg=EXCLUDED.rating_avg,
 ratings_count=EXCLUDED.ratings_count, completed_rides=EXCLUDED.completed_rides, updated_at=EXCLUDED.updated_at,
 suspended_until=EXCLUDED.suspended_until, vehicle_type=EXCLUDED.vehicle_type, service_radius_km=EXCLUDED.service_radius_km,
 performance_tier=EXCLUDED.performance_tier, map_model_type=EXCLUDED.map_model_type;

DELETE FROM public.driver_profiles WHERE vehicle_category = 'large'::public.vehicle_category;
ALTER TABLE public.driver_profiles ADD CONSTRAINT driver_profiles_taxi_category_only
 CHECK (vehicle_category IS NULL OR vehicle_category <> 'large'::public.vehicle_category);
CREATE INDEX naqil_profiles_vehicle_type_dispatch_idx ON public.naqil_profiles(vehicle_type,user_id)
 WHERE vehicle_category = 'large'::public.vehicle_category AND available=true AND status='approved';

ALTER TABLE public.naqil_profiles ENABLE ROW LEVEL SECURITY;
GRANT SELECT,INSERT,UPDATE ON public.naqil_profiles TO authenticated;
CREATE POLICY "Naqil profile visible" ON public.naqil_profiles FOR SELECT TO authenticated
 USING (user_id=(SELECT auth.uid()) OR public.has_provider_ops_access((SELECT auth.uid())) OR public.mamnoon_customer_has_assigned_provider(user_id));
CREATE POLICY "Naqil creates own profile" ON public.naqil_profiles FOR INSERT TO authenticated
 WITH CHECK (user_id=(SELECT auth.uid()));
CREATE POLICY "Naqil updates own profile or staff" ON public.naqil_profiles FOR UPDATE TO authenticated
 USING (user_id=(SELECT auth.uid()) OR public.has_admin_access((SELECT auth.uid())))
 WITH CHECK (user_id=(SELECT auth.uid()) OR public.has_admin_access((SELECT auth.uid())));

DO $$ DECLARE v_def text; BEGIN
 v_def:=pg_get_functiondef('public.guard_provider_status()'::regprocedure);
 v_def:=replace(v_def,'TG_TABLE_NAME = ''driver_profiles''','TG_TABLE_NAME IN (''driver_profiles'',''naqil_profiles'')');
 EXECUTE v_def;
END $$;
CREATE TRIGGER trg_guard_naqil_status BEFORE INSERT OR UPDATE ON public.naqil_profiles
 FOR EACH ROW EXECUTE FUNCTION public.guard_provider_status();
CREATE TRIGGER naqil_profiles_updated_at BEFORE UPDATE ON public.naqil_profiles
 FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE public.provider_presence_roles (
 user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 role text NOT NULL CHECK(role IN ('driver','large_driver','worker')),
 status text NOT NULL DEFAULT 'offline' CHECK(status IN ('online','offline','in_trip')),
 lat double precision NOT NULL CHECK(lat BETWEEN -90 AND 90),
 lng double precision NOT NULL CHECK(lng BETWEEN -180 AND 180),
 heading double precision CHECK(heading IS NULL OR (heading>=0 AND heading<=360)),
 updated_at timestamptz NOT NULL DEFAULT now(),
 location extensions.geography,
 accuracy_m double precision,
 speed_mps double precision,
 PRIMARY KEY(user_id,role)
);
CREATE INDEX provider_presence_roles_location_gist ON public.provider_presence_roles USING gist(location);
CREATE INDEX provider_presence_roles_role_status_updated ON public.provider_presence_roles(role,status,updated_at DESC);
ALTER TABLE public.provider_presence_roles ENABLE ROW LEVEL SECURITY;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.provider_presence_roles TO authenticated;
CREATE POLICY "Read own role presence or ops" ON public.provider_presence_roles FOR SELECT TO authenticated
 USING(user_id=(SELECT auth.uid()) OR public.has_live_ops_access((SELECT auth.uid())));
CREATE POLICY "Insert own approved role presence" ON public.provider_presence_roles FOR INSERT TO authenticated
 WITH CHECK(user_id=(SELECT auth.uid()) AND public.has_role((SELECT auth.uid()),role::public.app_role)
  AND ((role='driver' AND EXISTS(SELECT 1 FROM public.driver_profiles p WHERE p.user_id=(SELECT auth.uid()) AND p.status='approved' AND p.vehicle_category IN ('economy','premium','luxury')))
    OR (role='large_driver' AND EXISTS(SELECT 1 FROM public.naqil_profiles p WHERE p.user_id=(SELECT auth.uid()) AND p.status='approved' AND p.vehicle_category='large'::public.vehicle_category))
    OR (role='worker' AND EXISTS(SELECT 1 FROM public.worker_profiles p WHERE p.user_id=(SELECT auth.uid()) AND p.status='approved'))));
CREATE POLICY "Update own approved role presence" ON public.provider_presence_roles FOR UPDATE TO authenticated
 USING(user_id=(SELECT auth.uid()) AND public.has_role((SELECT auth.uid()),role::public.app_role))
 WITH CHECK(user_id=(SELECT auth.uid()) AND public.has_role((SELECT auth.uid()),role::public.app_role));
CREATE POLICY "Delete own role presence" ON public.provider_presence_roles FOR DELETE TO authenticated
 USING(user_id=(SELECT auth.uid()));

CREATE OR REPLACE FUNCTION public.sync_provider_presence_roles_geography()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,extensions AS $$
BEGIN
 NEW.location:=extensions.st_setsrid(extensions.st_makepoint(NEW.lng,NEW.lat),4326)::extensions.geography;
 NEW.updated_at:=now(); RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.sync_provider_presence_roles_geography() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER sync_provider_presence_roles_geography_before_write
 BEFORE INSERT OR UPDATE OF lat,lng,heading,status ON public.provider_presence_roles
 FOR EACH ROW EXECUTE FUNCTION public.sync_provider_presence_roles_geography();

