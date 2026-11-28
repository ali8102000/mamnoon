ALTER TABLE public.regional_dispatch_zone_settings
  DROP CONSTRAINT IF EXISTS regional_dispatch_zone_settings_ranges_check,
  DROP CONSTRAINT IF EXISTS regional_dispatch_ring4_6_valid;

ALTER TABLE public.regional_dispatch_zone_settings
  ADD CONSTRAINT regional_dispatch_rings_independent_valid CHECK (
    ring1_min_km >= 0 AND ring1_max_km > ring1_min_km AND ring1_max_km <= 55 AND
    ring2_min_km >= 0 AND ring2_max_km > ring2_min_km AND ring2_max_km <= 55 AND
    ring3_min_km >= 0 AND ring3_max_km > ring3_min_km AND ring3_max_km <= 55 AND
    ring4_min_km >= 0 AND ring4_max_km > ring4_min_km AND ring4_max_km <= 55 AND
    ring5_min_km >= 0 AND ring5_max_km > ring5_min_km AND ring5_max_km <= 55 AND
    ring6_min_km >= 0 AND ring6_max_km > ring6_min_km AND ring6_max_km <= 55
  );

CREATE OR REPLACE FUNCTION public.admin_update_dispatch_zone_settings(
  p_governorate_key text,p_dispatch_type text,p_category_key text,
  p_ring1_min_km numeric,p_ring1_max_km numeric,
  p_ring2_min_km numeric,p_ring2_max_km numeric,
  p_ring3_min_km numeric,p_ring3_max_km numeric,
  p_ring4_min_km numeric,p_ring4_max_km numeric,
  p_ring5_min_km numeric,p_ring5_max_km numeric,
  p_ring6_min_km numeric,p_ring6_max_km numeric,
  p_ring1_duration_seconds integer,p_ring2_duration_seconds integer,
  p_ring3_duration_seconds integer,p_ring4_duration_seconds integer,
  p_ring5_duration_seconds integer,p_ring6_duration_seconds integer
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_key text:=lower(trim(coalesce(p_governorate_key,''))); v_category text:=lower(trim(coalesce(p_category_key,'all')));
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'forbidden'; END IF;
 IF v_key NOT IN ('all','baghdad','basra','nineveh','erbil','sulaymaniyah','duhok','kirkuk','najaf','karbala','babil','anbar','diyala','saladin','wasit','dhiqar','maysan','muthanna','qadisiyah')
 OR p_dispatch_type NOT IN ('taxi','large_driver','technician')
 OR (v_category<>'all' AND (p_dispatch_type<>'technician' OR NOT EXISTS(SELECT 1 FROM public.services s WHERE s.slug=v_category)))
 OR p_ring1_min_km<0 OR p_ring1_max_km<=p_ring1_min_km OR p_ring1_max_km>55
 OR p_ring2_min_km<0 OR p_ring2_max_km<=p_ring2_min_km OR p_ring2_max_km>55
 OR p_ring3_min_km<0 OR p_ring3_max_km<=p_ring3_min_km OR p_ring3_max_km>55
 OR p_ring4_min_km<0 OR p_ring4_max_km<=p_ring4_min_km OR p_ring4_max_km>55
 OR p_ring5_min_km<0 OR p_ring5_max_km<=p_ring5_min_km OR p_ring5_max_km>55
 OR p_ring6_min_km<0 OR p_ring6_max_km<=p_ring6_min_km OR p_ring6_max_km>55
 OR p_ring1_duration_seconds NOT BETWEEN 5 AND 3600 OR p_ring2_duration_seconds NOT BETWEEN 5 AND 3600
 OR p_ring3_duration_seconds NOT BETWEEN 5 AND 3600 OR p_ring4_duration_seconds NOT BETWEEN 5 AND 3600
 OR p_ring5_duration_seconds NOT BETWEEN 5 AND 3600 OR p_ring6_duration_seconds NOT BETWEEN 5 AND 3600
 THEN RAISE EXCEPTION 'invalid_dispatch_zone_or_duration'; END IF;
 IF NOT public.admin_has_permission('zones.manage',CASE WHEN v_key='all' THEN 'global' ELSE 'governorate' END,CASE WHEN v_key='all' THEN NULL ELSE v_key END)
 THEN RAISE EXCEPTION 'missing_dispatch_zone_permission'; END IF;
 INSERT INTO public.regional_dispatch_zone_settings(
 governorate_key,dispatch_type,category_key,
 ring1_min_km,ring1_max_km,ring2_min_km,ring2_max_km,ring3_min_km,ring3_max_km,
 ring4_min_km,ring4_max_km,ring5_min_km,ring5_max_km,ring6_min_km,ring6_max_km,
 ring1_duration_seconds,ring2_duration_seconds,ring3_duration_seconds,ring4_duration_seconds,ring5_duration_seconds,ring6_duration_seconds,updated_at,updated_by
 ) VALUES (
 v_key,p_dispatch_type,v_category,
 p_ring1_min_km,p_ring1_max_km,p_ring2_min_km,p_ring2_max_km,p_ring3_min_km,p_ring3_max_km,
 p_ring4_min_km,p_ring4_max_km,p_ring5_min_km,p_ring5_max_km,p_ring6_min_km,p_ring6_max_km,
 p_ring1_duration_seconds,p_ring2_duration_seconds,p_ring3_duration_seconds,p_ring4_duration_seconds,p_ring5_duration_seconds,p_ring6_duration_seconds,now(),auth.uid()
 )
 ON CONFLICT(governorate_key,dispatch_type,category_key) DO UPDATE SET
 ring1_min_km=excluded.ring1_min_km,ring1_max_km=excluded.ring1_max_km,
 ring2_min_km=excluded.ring2_min_km,ring2_max_km=excluded.ring2_max_km,
 ring3_min_km=excluded.ring3_min_km,ring3_max_km=excluded.ring3_max_km,
 ring4_min_km=excluded.ring4_min_km,ring4_max_km=excluded.ring4_max_km,
 ring5_min_km=excluded.ring5_min_km,ring5_max_km=excluded.ring5_max_km,
 ring6_min_km=excluded.ring6_min_km,ring6_max_km=excluded.ring6_max_km,
 ring1_duration_seconds=excluded.ring1_duration_seconds,ring2_duration_seconds=excluded.ring2_duration_seconds,
 ring3_duration_seconds=excluded.ring3_duration_seconds,ring4_duration_seconds=excluded.ring4_duration_seconds,
 ring5_duration_seconds=excluded.ring5_duration_seconds,ring6_duration_seconds=excluded.ring6_duration_seconds,
 updated_at=now(),updated_by=auth.uid();
 RETURN true;
END; $function$;

GRANT EXECUTE ON FUNCTION public.admin_update_dispatch_zone_settings(text,text,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,integer,integer,integer,integer,integer,integer) TO authenticated;
