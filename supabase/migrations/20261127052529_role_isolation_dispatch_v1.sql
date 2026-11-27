CREATE OR REPLACE FUNCTION public.grant_provider_role_safe(_role public.app_role)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'unauthorized'; END IF;
 IF _role NOT IN ('driver','large_driver','worker') THEN RAISE EXCEPTION 'invalid_provider_role'; END IF;
 IF _role='driver' AND NOT EXISTS(SELECT 1 FROM public.driver_profiles p WHERE p.user_id=auth.uid()
   AND p.vehicle_category IN ('economy','premium','luxury') AND p.status='approved') THEN
   RAISE EXCEPTION 'approved_taxi_profile_required';
 END IF;
 IF _role='large_driver' AND NOT EXISTS(SELECT 1 FROM public.naqil_profiles p WHERE p.user_id=auth.uid()
   AND p.vehicle_category='large'::public.vehicle_category AND p.status='approved') THEN
   RAISE EXCEPTION 'approved_naqil_profile_required';
 END IF;
 IF _role='worker' AND NOT EXISTS(SELECT 1 FROM public.worker_profiles p WHERE p.user_id=auth.uid() AND p.status='approved') THEN
   RAISE EXCEPTION 'approved_worker_profile_required';
 END IF;
 INSERT INTO public.user_roles(user_id,role) VALUES(auth.uid(),_role) ON CONFLICT(user_id,role) DO NOTHING;
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.grant_provider_role_safe(public.app_role) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.grant_provider_role_safe(public.app_role) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_provider_status(
 p_user_id uuid,p_type text,p_status text,p_suspended_until timestamptz DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_role public.app_role; v_updated integer; v_governorate text; v_permission text;
BEGIN
 IF p_status IS NULL OR p_status NOT IN ('approved','suspended','rejected','pending') THEN RAISE EXCEPTION 'invalid_status'; END IF;
 IF p_type IS NULL OR p_type NOT IN ('driver','large_driver','worker') THEN RAISE EXCEPTION 'invalid_type'; END IF;
 IF p_status='suspended' AND p_suspended_until IS NOT NULL AND p_suspended_until<=now() THEN RAISE EXCEPTION 'invalid_suspension_expiry'; END IF;
 SELECT governorate_key INTO v_governorate FROM public.profiles WHERE id=p_user_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'provider_unavailable'; END IF;
 v_permission:=CASE WHEN p_status='suspended' THEN 'providers.suspend' ELSE 'providers.verify' END;
 IF auth.uid() IS NULL OR NOT (
   public.has_admin_access(auth.uid()) OR
   public.admin_has_permission(v_permission,CASE WHEN v_governorate IS NULL THEN 'global' ELSE 'governorate' END,v_governorate)
 ) THEN RAISE EXCEPTION 'provider_unavailable'; END IF;

 IF p_type='driver' THEN
  v_role:='driver';
  UPDATE public.driver_profiles SET status=p_status,
   suspended_until=CASE WHEN p_status='suspended' THEN p_suspended_until ELSE NULL END,
   available=CASE WHEN p_status='approved' THEN available ELSE false END
  WHERE user_id=p_user_id AND vehicle_category IN ('economy','premium','luxury');
  GET DIAGNOSTICS v_updated=ROW_COUNT;
 ELSIF p_type='large_driver' THEN
  v_role:='large_driver';
  UPDATE public.naqil_profiles SET status=p_status,
   suspended_until=CASE WHEN p_status='suspended' THEN p_suspended_until ELSE NULL END,
   available=CASE WHEN p_status='approved' THEN available ELSE false END
  WHERE user_id=p_user_id AND vehicle_category='large'::public.vehicle_category;
  GET DIAGNOSTICS v_updated=ROW_COUNT;
 ELSE
  v_role:='worker';
  UPDATE public.worker_profiles SET status=p_status,
   suspended_until=CASE WHEN p_status='suspended' THEN p_suspended_until ELSE NULL END,
   available=CASE WHEN p_status='approved' THEN available ELSE false END
  WHERE user_id=p_user_id;
  GET DIAGNOSTICS v_updated=ROW_COUNT;
 END IF;
 IF v_updated=0 THEN RAISE EXCEPTION 'provider_unavailable'; END IF;
 IF p_status='approved' THEN
  INSERT INTO public.user_roles(user_id,role) VALUES(p_user_id,v_role) ON CONFLICT(user_id,role) DO NOTHING;
 ELSIF p_status IN ('rejected','pending') THEN
  DELETE FROM public.user_roles WHERE user_id=p_user_id AND role=v_role;
 END IF;
 PERFORM public.log_admin_action('set_provider_status',p_type,p_user_id::text,
  jsonb_build_object('status',p_status,'suspended_until',p_suspended_until,'granted_role',CASE WHEN p_status='approved' THEN v_role::text ELSE NULL END));
END $$;
REVOKE ALL ON FUNCTION public.admin_set_provider_status(uuid,text,text,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_set_provider_status(uuid,text,text,timestamptz) TO authenticated;

CREATE OR REPLACE FUNCTION public.accept_service_request(_request_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE r public.service_requests%ROWTYPE; v_customer uuid; v_role text; v_eligible boolean:=false;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'unauthorized'; END IF;
 SELECT * INTO r FROM public.service_requests WHERE id=_request_id FOR UPDATE;
 IF NOT FOUND OR r.status NOT IN ('pending','searching') OR r.provider_id IS NOT NULL THEN RAISE EXCEPTION 'request_unavailable'; END IF;
 v_role:=CASE WHEN r.type::text='service' THEN 'worker'
   WHEN r.type::text='taxi' AND r.vehicle_category='large'::public.vehicle_category THEN 'large_driver'
   WHEN r.type::text='taxi' THEN 'driver' ELSE NULL END;
 IF v_role IS NULL OR NOT public.has_role(auth.uid(),v_role::public.app_role) THEN RAISE EXCEPTION 'provider_role_required'; END IF;
 IF EXISTS(SELECT 1 FROM public.user_blocks b WHERE b.user_id=auth.uid() AND (b.expires_at IS NULL OR b.expires_at>now())) THEN RAISE EXCEPTION 'user_blocked'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':'||v_role,0));
 IF EXISTS(SELECT 1 FROM public.service_requests a WHERE a.provider_id=auth.uid() AND a.provider_role=v_role AND a.status IN ('accepted','in_progress')) THEN
  RAISE EXCEPTION 'لديك طلب نشط بالفعل لهذا الدور';
 END IF;
 PERFORM 1 FROM public.request_offers o WHERE o.request_id=_request_id AND o.provider_id=auth.uid()
  AND o.provider_role=v_role AND o.status='pending' AND o.expires_at>now() FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'request_offer_expired'; END IF;

 IF v_role='driver' THEN
  SELECT EXISTS(SELECT 1 FROM public.driver_profiles p WHERE p.user_id=auth.uid() AND p.status='approved' AND p.available=true
   AND (p.suspended_until IS NULL OR p.suspended_until<=now())
   AND p.vehicle_category IN ('economy','premium','luxury')
   AND CASE p.vehicle_category::text WHEN 'economy' THEN 1 WHEN 'premium' THEN 2 WHEN 'luxury' THEN 3 ELSE 0 END
       >= CASE r.vehicle_category::text WHEN 'economy' THEN 1 WHEN 'premium' THEN 2 WHEN 'luxury' THEN 3 ELSE 99 END) INTO v_eligible;
 ELSIF v_role='large_driver' THEN
  SELECT EXISTS(SELECT 1 FROM public.naqil_profiles p WHERE p.user_id=auth.uid() AND p.vehicle_category='large'::public.vehicle_category
   AND p.status='approved' AND p.available=true AND (p.suspended_until IS NULL OR p.suspended_until<=now())
   AND (r.vehicle_type IS NULL OR p.vehicle_type=r.vehicle_type)) INTO v_eligible;
 ELSE
  SELECT EXISTS(SELECT 1 FROM public.worker_profiles p WHERE p.user_id=auth.uid() AND p.status='approved' AND p.available=true
   AND (p.suspended_until IS NULL OR p.suspended_until<=now())
   AND (r.level_required IS NULL OR p.level=r.level_required)
   AND EXISTS(SELECT 1 FROM public.worker_services ws WHERE ws.worker_id=p.user_id AND ws.service_id=r.service_id)) INTO v_eligible;
 END IF;
 IF NOT v_eligible THEN RAISE EXCEPTION 'provider_profile_not_eligible'; END IF;

 PERFORM set_config('mamnoon.allow_provider_request_transition','true',true);
 UPDATE public.service_requests sr SET provider_id=auth.uid(),provider_role=v_role,status='accepted',accepted_at=now(),updated_at=now()
 WHERE sr.id=_request_id AND sr.status IN ('pending','searching') AND sr.provider_id IS NULL
 RETURNING sr.customer_id INTO v_customer;
 PERFORM set_config('mamnoon.allow_provider_request_transition','false',true);
 IF v_customer IS NULL THEN RAISE EXCEPTION 'request_unavailable'; END IF;

 INSERT INTO public.chats(request_id,customer_id,provider_id) VALUES(_request_id,v_customer,auth.uid())
 ON CONFLICT(request_id) DO UPDATE SET provider_id=EXCLUDED.provider_id,updated_at=now();
 UPDATE public.request_offers SET status=CASE WHEN provider_id=auth.uid() THEN 'accepted' ELSE 'cancelled' END,responded_at=now()
 WHERE request_id=_request_id AND status='pending';
 INSERT INTO public.notifications(user_id,type,title,body,link,data)
 VALUES(v_customer,'request_accepted','تم قبول طلبك','مقدّم الخدمة قبل طلبك ويمكنك متابعة التفاصيل الآن.',
  '/request/'||_request_id,jsonb_build_object('request_id',_request_id,'provider_id',auth.uid(),'provider_role',v_role));
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.accept_service_request(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.accept_service_request(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.accept_large_vehicle_request(_request_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE r public.service_requests%ROWTYPE; v_customer uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(),'large_driver') THEN RAISE EXCEPTION 'large_driver_role_required'; END IF;
 IF EXISTS(SELECT 1 FROM public.user_blocks b WHERE b.user_id=auth.uid() AND (b.expires_at IS NULL OR b.expires_at>now())) THEN RAISE EXCEPTION 'user_blocked'; END IF;
 SELECT * INTO r FROM public.service_requests WHERE id=_request_id FOR UPDATE;
 IF NOT FOUND OR r.type::text<>'taxi' OR r.vehicle_category<>'large'::public.vehicle_category
  OR r.status::text NOT IN ('pending','searching') OR r.provider_id IS NOT NULL THEN RAISE EXCEPTION 'request_unavailable'; END IF;
 IF r.customer_id=auth.uid() THEN RAISE EXCEPTION 'cannot_accept_own_request'; END IF;
 IF COALESCE(r.customer_price,r.customer_payable,r.price_estimate,0)<=0 THEN RAISE EXCEPTION 'customer_price_missing'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.request_offers o WHERE o.request_id=_request_id AND o.provider_id=auth.uid()
  AND o.provider_role='large_driver' AND o.status IN ('pending','rejected','expired')) THEN RAISE EXCEPTION 'request_offer_unavailable'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.naqil_profiles p WHERE p.user_id=auth.uid() AND p.vehicle_category='large'::public.vehicle_category
  AND p.status='approved' AND p.available=true AND (p.suspended_until IS NULL OR p.suspended_until<=now())
  AND (r.vehicle_type IS NULL OR p.vehicle_type=r.vehicle_type)) THEN RAISE EXCEPTION 'large_driver_no_longer_eligible'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':large_driver',0));
 IF EXISTS(SELECT 1 FROM public.service_requests sr WHERE sr.provider_id=auth.uid() AND sr.provider_role='large_driver'
  AND sr.status IN ('accepted','in_progress')) THEN RAISE EXCEPTION 'provider_has_active_request'; END IF;
 PERFORM set_config('mamnoon.allow_provider_request_transition','true',true);
 UPDATE public.service_requests sr SET provider_id=auth.uid(),provider_role='large_driver',status='accepted',accepted_at=now(),updated_at=now()
 WHERE sr.id=_request_id AND sr.status IN ('pending','searching') AND sr.provider_id IS NULL
 RETURNING sr.customer_id INTO v_customer;
 PERFORM set_config('mamnoon.allow_provider_request_transition','false',true);
 IF v_customer IS NULL THEN RAISE EXCEPTION 'request_unavailable'; END IF;
 INSERT INTO public.chats(request_id,customer_id,provider_id) VALUES(_request_id,v_customer,auth.uid())
 ON CONFLICT(request_id) DO UPDATE SET provider_id=EXCLUDED.provider_id,updated_at=now();
 UPDATE public.request_offers SET status=CASE WHEN provider_id=auth.uid() THEN 'accepted' ELSE 'cancelled' END,responded_at=now()
 WHERE request_id=_request_id AND status IN ('pending','rejected','expired');
 INSERT INTO public.notifications(user_id,type,title,body,link,data)
 VALUES(v_customer,'request_accepted','تم قبول طلب السيارة الكبيرة','قبل صاحب السيارة أجرتك المحددة، ويمكنك متابعة تفاصيل الرحلة الآن.',
  '/request/'||_request_id,jsonb_build_object('request_id',_request_id,'provider_id',auth.uid(),'provider_role','large_driver',
   'accepted_customer_price',COALESCE(r.customer_price,r.customer_payable,r.price_estimate)));
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.accept_large_vehicle_request(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.accept_large_vehicle_request(uuid) TO authenticated;

-- These RPCs are exclusively for the large-vehicle role; move all profile lookups to naqil_profiles.
DO $$
DECLARE v_def text;
BEGIN
 v_def:=pg_get_functiondef('public.accept_large_vehicle_offer(uuid)'::regprocedure);
 v_def:=replace(v_def,'public.driver_profiles','public.naqil_profiles');
 v_def:=replace(v_def,'sr.provider_id = o.provider_id AND sr.status IN','sr.provider_id = o.provider_id AND sr.provider_role = ''large_driver'' AND sr.status IN');
 EXECUTE v_def;

 v_def:=pg_get_functiondef('public.submit_large_vehicle_offer(uuid,integer,text)'::regprocedure);
 v_def:=replace(v_def,'public.driver_profiles','public.naqil_profiles');
 v_def:=replace(v_def,'sr.provider_id = auth.uid() AND sr.status IN','sr.provider_id = auth.uid() AND sr.provider_role = ''large_driver'' AND sr.status IN');
 EXECUTE v_def;

 v_def:=pg_get_functiondef('public.retry_large_vehicle_dispatch(uuid)'::regprocedure);
 v_def:=replace(v_def,'public.driver_profiles','public.naqil_profiles');
 EXECUTE v_def;
END $$;

CREATE OR REPLACE FUNCTION public.find_nearby_drivers(
 _lat numeric,_lng numeric,_category text,_radius_km numeric DEFAULT 5,_limit integer DEFAULT 10
) RETURNS TABLE(user_id uuid,distance_km numeric,rating_avg numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,extensions AS $$
 WITH origin AS (
  SELECT extensions.st_setsrid(extensions.st_makepoint(_lng::double precision,_lat::double precision),4326)::extensions.geography AS point
 ), eligible AS (
  SELECT p.user_id,p.rating_avg,p.service_radius_km,pp.lat,pp.lng,pp.updated_at,'driver'::text AS role
  FROM public.driver_profiles p JOIN public.provider_presence_roles pp ON pp.user_id=p.user_id AND pp.role='driver'
  WHERE _category IN ('economy','premium','luxury') AND p.available=true AND p.status='approved'
   AND p.vehicle_category IN ('economy','premium','luxury') AND (p.suspended_until IS NULL OR p.suspended_until<=now())
   AND CASE p.vehicle_category::text WHEN 'economy' THEN 1 WHEN 'premium' THEN 2 WHEN 'luxury' THEN 3 ELSE 0 END
      >= CASE _category WHEN 'economy' THEN 1 WHEN 'premium' THEN 2 WHEN 'luxury' THEN 3 ELSE 99 END
   AND pp.status='online' AND pp.updated_at>now()-interval '5 minutes'
  UNION ALL
  SELECT p.user_id,p.rating_avg,p.service_radius_km,pp.lat,pp.lng,pp.updated_at,'large_driver'::text
  FROM public.naqil_profiles p JOIN public.provider_presence_roles pp ON pp.user_id=p.user_id AND pp.role='large_driver'
  WHERE _category='large' AND p.available=true AND p.status='approved'
   AND p.vehicle_category='large'::public.vehicle_category AND (p.suspended_until IS NULL OR p.suspended_until<=now())
   AND pp.status='online' AND pp.updated_at>now()-interval '5 minutes'
 ), ranked AS (
  SELECT e.user_id,e.rating_avg,e.role,e.service_radius_km,
   (6371*acos(least(1.0,greatest(-1.0,
    cos(radians(_lat::double precision))*cos(radians(e.lat))*cos(radians(e.lng)-radians(_lng::double precision))
    +sin(radians(_lat::double precision))*sin(radians(e.lat))
   ))))::numeric AS distance_km
  FROM eligible e CROSS JOIN origin o
  WHERE extensions.st_dwithin(
   (SELECT extensions.st_setsrid(extensions.st_makepoint(e.lng,e.lat),4326)::extensions.geography),
   o.point,(least(greatest(coalesce(_radius_km,5),0.1),55)*1000*1.01)+5)
   AND NOT EXISTS(SELECT 1 FROM public.service_requests sr WHERE sr.provider_id=e.user_id
    AND sr.provider_role=e.role AND sr.status IN ('accepted','in_progress'))
   AND NOT EXISTS(SELECT 1 FROM public.user_blocks b WHERE b.user_id=e.user_id AND (b.expires_at IS NULL OR b.expires_at>now()))
 )
 SELECT r.user_id,r.distance_km,r.rating_avg FROM ranked r
 WHERE r.distance_km<=least(greatest(coalesce(_radius_km,5),0.1),55)
  AND (_category<>'large' OR r.distance_km<=coalesce(r.service_radius_km,25))
 ORDER BY r.distance_km ASC,r.rating_avg DESC NULLS LAST
 LIMIT least(greatest(coalesce(_limit,10),1),1000);
$$;
REVOKE ALL ON FUNCTION public.find_nearby_drivers(numeric,numeric,text,numeric,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.find_nearby_drivers(numeric,numeric,text,numeric,integer) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.find_nearby_provider_pins(
 _lat numeric,_lng numeric,_type text,_category text DEFAULT NULL,_service_id uuid DEFAULT NULL,_radius_km numeric DEFAULT 5,_limit integer DEFAULT 30
) RETURNS TABLE(pin_id text,lat numeric,lng numeric,heading numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,extensions AS $$
 WITH origin AS (SELECT extensions.st_setsrid(extensions.st_makepoint(_lng::double precision,_lat::double precision),4326)::extensions.geography point)
 SELECT md5(pp.user_id::text||':'||pp.role),round(pp.lat::numeric,3),round(pp.lng::numeric,3),pp.heading::numeric
 FROM public.provider_presence_roles pp CROSS JOIN origin o
 WHERE auth.uid() IS NOT NULL AND _lat BETWEEN -90 AND 90 AND _lng BETWEEN -180 AND 180
  AND _type IN ('taxi','service') AND pp.status='online' AND pp.updated_at>now()-interval '5 minutes'
  AND extensions.st_dwithin(pp.location,o.point,(least(greatest(coalesce(_radius_km,5),0.1),25)*1000*1.01)+5)
  AND (
   (_type='taxi' AND _category='large' AND pp.role='large_driver'
    AND EXISTS(SELECT 1 FROM public.naqil_profiles p WHERE p.user_id=pp.user_id AND p.available AND p.status='approved'
      AND p.vehicle_category='large'::public.vehicle_category AND (p.suspended_until IS NULL OR p.suspended_until<=now())))
   OR
   (_type='taxi' AND _category IS DISTINCT FROM 'large' AND pp.role='driver'
    AND EXISTS(SELECT 1 FROM public.driver_profiles p WHERE p.user_id=pp.user_id AND p.available AND p.status='approved'
      AND p.vehicle_category IN ('economy','premium','luxury') AND (p.suspended_until IS NULL OR p.suspended_until<=now())
      AND (_category IS NULL OR p.vehicle_category::text=_category)))
   OR
   (_type='service' AND pp.role='worker'
    AND EXISTS(SELECT 1 FROM public.worker_profiles p WHERE p.user_id=pp.user_id AND p.available AND p.status='approved'
      AND (p.suspended_until IS NULL OR p.suspended_until<=now())
      AND (_service_id IS NULL OR EXISTS(SELECT 1 FROM public.worker_services ws WHERE ws.worker_id=pp.user_id AND ws.service_id=_service_id))))
  )
  AND 6371*acos(least(1.0,greatest(-1.0,
   cos(radians(_lat::double precision))*cos(radians(pp.lat))*cos(radians(pp.lng)-radians(_lng::double precision))
   +sin(radians(_lat::double precision))*sin(radians(pp.lat))
  )))<=least(greatest(coalesce(_radius_km,5),0.1),25)
 ORDER BY pp.updated_at DESC LIMIT least(greatest(coalesce(_limit,30),1),30);
$$;
REVOKE ALL ON FUNCTION public.find_nearby_provider_pins(numeric,numeric,text,text,uuid,numeric,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.find_nearby_provider_pins(numeric,numeric,text,text,uuid,numeric,integer) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.find_nearby_provider_map_pins(
 _lat numeric,_lng numeric,_type text,_category text DEFAULT NULL,_service_id uuid DEFAULT NULL,_radius_km numeric DEFAULT 5,_limit integer DEFAULT 30
) RETURNS TABLE(pin_id text,lat numeric,lng numeric,heading numeric,model_type text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,extensions AS $$
 WITH origin AS (SELECT extensions.st_setsrid(extensions.st_makepoint(_lng::double precision,_lat::double precision),4326)::extensions.geography point)
 SELECT md5(pp.user_id::text||':'||pp.role),round(pp.lat::numeric,3),round(pp.lng::numeric,3),pp.heading::numeric,
  CASE WHEN pp.role='worker' THEN 'worker' WHEN pp.role='large_driver' THEN COALESCE(np.map_model_type,'large_vehicle')
   ELSE COALESCE(dp.map_model_type,'taxi') END
 FROM public.provider_presence_roles pp CROSS JOIN origin o
 LEFT JOIN public.driver_profiles dp ON dp.user_id=pp.user_id AND pp.role='driver'
 LEFT JOIN public.naqil_profiles np ON np.user_id=pp.user_id AND pp.role='large_driver'
 WHERE auth.uid() IS NOT NULL AND _lat BETWEEN -90 AND 90 AND _lng BETWEEN -180 AND 180
  AND _type IN ('taxi','service') AND pp.status='online' AND pp.updated_at>now()-interval '5 minutes'
  AND extensions.st_dwithin(pp.location,o.point,(least(greatest(coalesce(_radius_km,5),0.1),25)*1000*1.01)+5)
  AND (
   (_type='taxi' AND _category='large' AND pp.role='large_driver' AND np.available AND np.status='approved'
    AND np.vehicle_category='large'::public.vehicle_category AND (np.suspended_until IS NULL OR np.suspended_until<=now()))
   OR
   (_type='taxi' AND _category IS DISTINCT FROM 'large' AND pp.role='driver' AND dp.available AND dp.status='approved'
    AND dp.vehicle_category IN ('economy','premium','luxury') AND (dp.suspended_until IS NULL OR dp.suspended_until<=now())
    AND (_category IS NULL OR dp.vehicle_category::text=_category))
   OR
   (_type='service' AND pp.role='worker' AND EXISTS(SELECT 1 FROM public.worker_profiles wp WHERE wp.user_id=pp.user_id
    AND wp.available AND wp.status='approved' AND (wp.suspended_until IS NULL OR wp.suspended_until<=now())
    AND (_service_id IS NULL OR EXISTS(SELECT 1 FROM public.worker_services ws WHERE ws.worker_id=wp.user_id AND ws.service_id=_service_id))))
  )
  AND 6371*acos(least(1.0,greatest(-1.0,
   cos(radians(_lat::double precision))*cos(radians(pp.lat))*cos(radians(pp.lng)-radians(_lng::double precision))
   +sin(radians(_lat::double precision))*sin(radians(pp.lat))
  )))<=least(greatest(coalesce(_radius_km,5),0.1),25)
 ORDER BY pp.updated_at DESC LIMIT least(greatest(coalesce(_limit,30),1),30);
$$;
REVOKE ALL ON FUNCTION public.find_nearby_provider_map_pins(numeric,numeric,text,text,uuid,numeric,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.find_nearby_provider_map_pins(numeric,numeric,text,text,uuid,numeric,integer) TO authenticated,service_role;

