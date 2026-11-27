DO $$
DECLARE v_def text;
BEGIN
 v_def:=pg_get_functiondef('public.advance_service_dispatch(uuid)'::regprocedure);
 v_def:=replace(v_def,'FROM public.provider_presence pp','FROM public.provider_presence_roles pp');
 v_def:=replace(v_def,'WHERE pp.updated_at > now() - interval ''5 minutes''',
  'WHERE pp.role=''worker'' AND pp.status=''online'' AND pp.updated_at > now() - interval ''5 minutes''');
 v_def:=replace(v_def,'WHERE active.provider_id = wp.user_id
          AND active.status IN',
  'WHERE active.provider_id = wp.user_id AND active.provider_role=''worker''
          AND active.status IN');
 v_def:=replace(v_def,'WHERE srp_active.provider_id = wp.user_id
          AND active_team_request.status IN',
  'WHERE srp_active.provider_id = wp.user_id AND active_team_request.provider_role=''worker''
          AND active_team_request.status IN');
 EXECUTE v_def;
END $$;

CREATE OR REPLACE FUNCTION public.get_taxi_demand_multiplier(_lat numeric,_lng numeric,_category text DEFAULT NULL)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE v_drivers integer:=0; v_waiting integer:=0; v_ratio numeric; v_origin extensions.geography;
BEGIN
 IF _lat IS NULL OR _lng IS NULL OR _lat NOT BETWEEN -90 AND 90 OR _lng NOT BETWEEN -180 AND 180 THEN
  RAISE EXCEPTION 'موقع الانطلاق غير صالح';
 END IF;
 IF _category IS NOT NULL AND _category NOT IN ('economy','premium','luxury') THEN
  RAISE EXCEPTION 'فئة السيارة غير صالحة';
 END IF;
 v_origin:=extensions.st_setsrid(extensions.st_makepoint(_lng::double precision,_lat::double precision),4326)::extensions.geography;
 SELECT count(*)::integer INTO v_drivers
 FROM public.driver_profiles dp
 JOIN public.provider_presence_roles pp ON pp.user_id=dp.user_id AND pp.role='driver'
 WHERE pp.status='online' AND pp.updated_at>now()-interval '5 minutes'
  AND pp.accuracy_m IS NOT NULL AND pp.accuracy_m<=100
  AND dp.available AND dp.status='approved'
  AND (_category IS NULL OR dp.vehicle_category::text=_category)
  AND (dp.suspended_until IS NULL OR dp.suspended_until<=now())
  AND extensions.st_dwithin(pp.location,v_origin,5055)
  AND NOT EXISTS(SELECT 1 FROM public.service_requests active WHERE active.provider_id=dp.user_id
   AND active.provider_role='driver' AND active.status IN ('accepted','in_progress'))
  AND NOT EXISTS(SELECT 1 FROM public.user_blocks b WHERE b.user_id=dp.user_id AND (b.expires_at IS NULL OR b.expires_at>now()));
 SELECT count(*)::integer INTO v_waiting
 FROM public.service_requests sr
 WHERE sr.type='taxi' AND sr.status IN ('pending','searching') AND sr.provider_id IS NULL
  AND sr.created_at>now()-interval '15 minutes'
  AND (_category IS NULL OR sr.vehicle_category::text=_category)
  AND sr.pickup_location IS NOT NULL AND extensions.st_dwithin(sr.pickup_location,v_origin,5055)
  AND 6371*acos(least(1.0,greatest(-1.0,
   cos(radians(_lat::double precision))*cos(radians(sr.pickup_lat::double precision))*
   cos(radians(sr.pickup_lng::double precision)-radians(_lng::double precision))+
   sin(radians(_lat::double precision))*sin(radians(sr.pickup_lat::double precision))
  )))<=5;
 v_ratio:=v_drivers::numeric/greatest(v_waiting+1,1);
 IF v_ratio>=3 THEN RETURN 0.80;
 ELSIF v_ratio>=2 THEN RETURN 0.90;
 ELSIF v_ratio>=1.25 THEN RETURN 1.00;
 ELSIF v_ratio>=0.75 THEN RETURN 1.10;
 ELSIF v_ratio>=0.50 THEN RETURN 1.25;
 ELSIF v_ratio>=0.25 THEN RETURN 1.40;
 ELSE RETURN 1.50;
 END IF;
END $$;

CREATE OR REPLACE FUNCTION public.get_taxi_high_demand_areas(p_category text DEFAULT NULL)
RETURNS TABLE(zone_lat numeric,zone_lng numeric,waiting_requests integer,online_drivers integer,demand_ratio numeric,demand_level text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions AS $$
DECLARE v_uid uuid:=auth.uid();
BEGIN
 IF v_uid IS NULL OR NOT public.has_role(v_uid,'driver') THEN RAISE EXCEPTION 'taxi_driver_only'; END IF;
 RETURN QUERY
 WITH demand AS (
  SELECT floor(sr.pickup_lat::numeric*100)::integer gy,floor(sr.pickup_lng::numeric*100)::integer gx,count(*)::integer waiting
  FROM public.service_requests sr
  WHERE sr.type='taxi' AND sr.status IN ('pending','searching') AND sr.created_at>now()-interval '30 minutes'
   AND sr.pickup_lat IS NOT NULL AND sr.pickup_lng IS NOT NULL
   AND (p_category IS NULL OR sr.vehicle_category::text=p_category)
  GROUP BY 1,2 HAVING count(*)>=2
 ), drivers AS (
  SELECT floor(pp.lat*100)::integer gy,floor(pp.lng*100)::integer gx,count(DISTINCT pp.user_id)::integer online
  FROM public.provider_presence_roles pp
  JOIN public.driver_profiles dp ON dp.user_id=pp.user_id AND dp.available AND dp.status='approved'
  JOIN public.user_roles ur ON ur.user_id=pp.user_id AND ur.role='driver'
  WHERE pp.role='driver' AND pp.status='online' AND pp.updated_at>now()-interval '5 minutes'
   AND (p_category IS NULL OR dp.vehicle_category::text=p_category)
  GROUP BY 1,2
 )
 SELECT round(((d.gy+0.5)/100.0)::numeric,3),round(((d.gx+0.5)/100.0)::numeric,3),
  d.waiting,coalesce(v.online,0),round(d.waiting::numeric/greatest(coalesce(v.online,0),1),2),
  CASE WHEN d.waiting::numeric/greatest(coalesce(v.online,0),1)>=2 THEN 'high' ELSE 'medium' END
 FROM demand d LEFT JOIN drivers v USING(gy,gx)
 ORDER BY d.waiting::numeric/greatest(coalesce(v.online,0),1) DESC,d.waiting DESC LIMIT 30;
END $$;

CREATE OR REPLACE FUNCTION public.cleanup_disabled_provider_role_presence()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_governorate text;
BEGIN
 SELECT coalesce(nullif(lower(trim(p.governorate_key)),''),public.infer_governorate_key(NEW.lat::numeric,NEW.lng::numeric))
 INTO v_governorate FROM public.profiles p WHERE p.id=NEW.user_id;
 IF NOT public.regional_services_enabled(v_governorate) THEN
  IF NEW.role='driver' THEN
   UPDATE public.driver_profiles SET available=false WHERE user_id=NEW.user_id;
  ELSIF NEW.role='large_driver' THEN
   UPDATE public.naqil_profiles SET available=false WHERE user_id=NEW.user_id;
  ELSE
   UPDATE public.worker_profiles SET available=false WHERE user_id=NEW.user_id;
  END IF;
  DELETE FROM public.provider_presence_roles WHERE user_id=NEW.user_id AND role=NEW.role;
 END IF;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.cleanup_disabled_provider_role_presence() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS trg_cleanup_disabled_provider_role_presence ON public.provider_presence_roles;
CREATE TRIGGER trg_cleanup_disabled_provider_role_presence
 AFTER INSERT OR UPDATE OF lat,lng,status ON public.provider_presence_roles
 FOR EACH ROW EXECUTE FUNCTION public.cleanup_disabled_provider_role_presence();

