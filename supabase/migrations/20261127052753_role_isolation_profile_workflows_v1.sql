DO $$
DECLARE v_def text; v_old text; v_new text;
BEGIN
 v_def:=pg_get_functiondef('public.admin_review_provider_change_request(uuid,text,text)'::regprocedure);
 v_old:=$old$UPDATE public.driver_profiles
      SET vehicle_make=CASE WHEN v_vehicle ? 'vehicle_make' THEN v_vehicle->>'vehicle_make' ELSE vehicle_make END,
          vehicle_model=CASE WHEN v_vehicle ? 'vehicle_model' THEN v_vehicle->>'vehicle_model' ELSE vehicle_model END,
          vehicle_year=CASE WHEN v_vehicle ? 'vehicle_year' THEN (v_vehicle->>'vehicle_year')::integer ELSE vehicle_year END,
          vehicle_plate=CASE WHEN v_vehicle ? 'vehicle_plate' THEN v_vehicle->>'vehicle_plate' ELSE vehicle_plate END,
          vehicle_color=CASE WHEN v_vehicle ? 'vehicle_color' THEN v_vehicle->>'vehicle_color' ELSE vehicle_color END,
          vehicle_category=CASE WHEN v_vehicle ? 'vehicle_category' THEN (v_vehicle->>'vehicle_category')::public.vehicle_category ELSE vehicle_category END,
          vehicle_type=CASE WHEN v_vehicle ? 'vehicle_type' THEN v_vehicle->>'vehicle_type' ELSE vehicle_type END,
          updated_at=now()
      WHERE user_id=r.user_id AND status='approved' AND ((r.provider_type='driver' AND vehicle_category::text<>'large') OR (r.provider_type='large_driver' AND vehicle_category::text='large'));
      IF NOT FOUND THEN RAISE EXCEPTION 'approved_driver_profile_not_found'; END IF;$old$;
 v_new:=$new$IF r.provider_type='large_driver' THEN
        UPDATE public.naqil_profiles
        SET vehicle_make=CASE WHEN v_vehicle ? 'vehicle_make' THEN v_vehicle->>'vehicle_make' ELSE vehicle_make END,
            vehicle_model=CASE WHEN v_vehicle ? 'vehicle_model' THEN v_vehicle->>'vehicle_model' ELSE vehicle_model END,
            vehicle_year=CASE WHEN v_vehicle ? 'vehicle_year' THEN (v_vehicle->>'vehicle_year')::integer ELSE vehicle_year END,
            vehicle_plate=CASE WHEN v_vehicle ? 'vehicle_plate' THEN v_vehicle->>'vehicle_plate' ELSE vehicle_plate END,
            vehicle_color=CASE WHEN v_vehicle ? 'vehicle_color' THEN v_vehicle->>'vehicle_color' ELSE vehicle_color END,
            vehicle_type=CASE WHEN v_vehicle ? 'vehicle_type' THEN v_vehicle->>'vehicle_type' ELSE vehicle_type END,
            updated_at=now()
        WHERE user_id=r.user_id AND status='approved' AND vehicle_category='large'::public.vehicle_category;
      ELSE
        UPDATE public.driver_profiles
        SET vehicle_make=CASE WHEN v_vehicle ? 'vehicle_make' THEN v_vehicle->>'vehicle_make' ELSE vehicle_make END,
            vehicle_model=CASE WHEN v_vehicle ? 'vehicle_model' THEN v_vehicle->>'vehicle_model' ELSE vehicle_model END,
            vehicle_year=CASE WHEN v_vehicle ? 'vehicle_year' THEN (v_vehicle->>'vehicle_year')::integer ELSE vehicle_year END,
            vehicle_plate=CASE WHEN v_vehicle ? 'vehicle_plate' THEN v_vehicle->>'vehicle_plate' ELSE vehicle_plate END,
            vehicle_color=CASE WHEN v_vehicle ? 'vehicle_color' THEN v_vehicle->>'vehicle_color' ELSE vehicle_color END,
            vehicle_category=CASE WHEN v_vehicle ? 'vehicle_category' THEN (v_vehicle->>'vehicle_category')::public.vehicle_category ELSE vehicle_category END,
            vehicle_type=CASE WHEN v_vehicle ? 'vehicle_type' THEN v_vehicle->>'vehicle_type' ELSE vehicle_type END,
            updated_at=now()
        WHERE user_id=r.user_id AND status='approved'
          AND vehicle_category IN ('economy','premium','luxury');
      END IF;
      IF NOT FOUND THEN RAISE EXCEPTION 'approved_driver_profile_not_found'; END IF;$new$;
 IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'provider_change_vehicle_update_block_not_found'; END IF;
 v_def:=replace(v_def,v_old,v_new);
 v_def:=replace(v_def,
  $fallback$IF r.provider_type='large_driver' AND NOT EXISTS (SELECT 1 FROM public.provider_verifications WHERE user_id=r.user_id AND provider_type='large_driver') THEN
        v_verification_type := 'driver';
      END IF;$fallback$,
  '');
 EXECUTE v_def;
END $$;

CREATE OR REPLACE FUNCTION public.submit_provider_profile_change_request(_provider_type text,_profile_update jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE v_id uuid; v_name text; v_approved boolean:=false;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'unauthorized'; END IF;
 IF _provider_type NOT IN ('worker','driver','large_driver') OR NOT public.has_role(auth.uid(),_provider_type::public.app_role)
 THEN RAISE EXCEPTION 'approved_provider_role_required'; END IF;
 IF _profile_update IS NULL OR jsonb_typeof(_profile_update) IS DISTINCT FROM 'object'
  OR (_profile_update-'full_name')<>'{}'::jsonb OR NOT (_profile_update?'full_name') THEN RAISE EXCEPTION 'invalid_profile_update'; END IF;
 v_name:=trim(coalesce(_profile_update->>'full_name',''));
 IF length(v_name) NOT BETWEEN 2 AND 80 THEN RAISE EXCEPTION 'invalid_full_name'; END IF;
 IF _provider_type='worker' THEN
  SELECT EXISTS(SELECT 1 FROM public.worker_profiles WHERE user_id=auth.uid() AND status='approved') INTO v_approved;
 ELSIF _provider_type='driver' THEN
  SELECT EXISTS(SELECT 1 FROM public.driver_profiles WHERE user_id=auth.uid() AND status='approved'
   AND vehicle_category IN ('economy','premium','luxury')) INTO v_approved;
 ELSE
  SELECT EXISTS(SELECT 1 FROM public.naqil_profiles WHERE user_id=auth.uid() AND status='approved'
   AND vehicle_category='large'::public.vehicle_category) INTO v_approved;
 END IF;
 IF NOT v_approved THEN RAISE EXCEPTION 'approved_provider_profile_required'; END IF;
 IF EXISTS(SELECT 1 FROM public.provider_change_requests WHERE user_id=auth.uid() AND provider_type=_provider_type
  AND status='pending' AND requested_data?'profile_update') THEN RAISE EXCEPTION 'profile_change_request_already_pending'; END IF;
 INSERT INTO public.provider_change_requests(user_id,provider_type,requested_data)
 VALUES(auth.uid(),_provider_type,jsonb_build_object('profile_update',jsonb_build_object('full_name',v_name)))
 RETURNING id INTO v_id;
 RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.submit_provider_profile_change_request(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.submit_provider_profile_change_request(text,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_provider_service_radius(p_radius_km integer,p_role text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_uid uuid:=auth.uid(); v_rows integer:=0;
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'unauthorized'; END IF;
 IF p_radius_km IS NULL OR p_radius_km<1 OR p_radius_km>55 THEN RAISE EXCEPTION 'invalid_radius'; END IF;
 IF p_role NOT IN ('driver','large_driver','worker') OR NOT public.has_role(v_uid,p_role::public.app_role)
 THEN RAISE EXCEPTION 'provider_role_required'; END IF;
 IF p_role='driver' THEN
  UPDATE public.driver_profiles SET service_radius_km=p_radius_km,updated_at=now()
  WHERE user_id=v_uid AND status='approved' AND vehicle_category IN ('economy','premium','luxury');
 ELSIF p_role='large_driver' THEN
  UPDATE public.naqil_profiles SET service_radius_km=p_radius_km,updated_at=now()
  WHERE user_id=v_uid AND status='approved' AND vehicle_category='large'::public.vehicle_category;
 ELSE
  UPDATE public.worker_profiles SET service_radius_km=p_radius_km,updated_at=now()
  WHERE user_id=v_uid AND status='approved';
 END IF;
 GET DIAGNOSTICS v_rows=ROW_COUNT;
 IF v_rows=0 THEN RAISE EXCEPTION 'provider_profile_not_found'; END IF;
 RETURN p_radius_km;
END $$;
REVOKE ALL ON FUNCTION public.set_provider_service_radius(integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_provider_service_radius(integer,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_provider_service_radius(p_radius_km integer)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_roles text[];
BEGIN
 SELECT array_agg(role) INTO v_roles FROM public.user_roles
 WHERE user_id=auth.uid() AND role IN ('driver','large_driver','worker');
 IF coalesce(array_length(v_roles,1),0)<>1 THEN RAISE EXCEPTION 'provider_role_required'; END IF;
 RETURN public.set_provider_service_radius(p_radius_km,v_roles[1]);
END $$;
REVOKE ALL ON FUNCTION public.set_provider_service_radius(integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_provider_service_radius(integer) TO authenticated;

DO $$
DECLARE v_def text;
BEGIN
 v_def:=pg_get_functiondef('public.advance_taxi_dispatch(uuid)'::regprocedure);
 v_def:=replace(v_def,
  'FROM public.find_nearby_drivers(r.pickup_lat, r.pickup_lng, ''large'', v_radius, 1000) d
      JOIN public.driver_profiles dp ON dp.user_id = d.user_id',
  'FROM public.find_nearby_drivers(r.pickup_lat, r.pickup_lng, ''large'', v_radius, 1000) d
      JOIN public.naqil_profiles dp ON dp.user_id = d.user_id');
 EXECUTE v_def;
END $$;

