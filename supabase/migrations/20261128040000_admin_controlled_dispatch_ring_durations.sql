ALTER TABLE public.regional_dispatch_zone_settings
  ADD COLUMN IF NOT EXISTS ring1_duration_seconds integer NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS ring2_duration_seconds integer NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS ring3_duration_seconds integer NOT NULL DEFAULT 60;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='regional_dispatch_ring_durations_valid') THEN
    ALTER TABLE public.regional_dispatch_zone_settings
      ADD CONSTRAINT regional_dispatch_ring_durations_valid
      CHECK (ring1_duration_seconds BETWEEN 5 AND 3600 AND ring2_duration_seconds BETWEEN 5 AND 3600 AND ring3_duration_seconds BETWEEN 5 AND 3600);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.get_regional_dispatch_ring_duration(text,integer,text,text)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
 SELECT CASE ((greatest(coalesce($2,0),0) % 3)+1)
   WHEN 1 THEN s.ring1_duration_seconds WHEN 2 THEN s.ring2_duration_seconds ELSE s.ring3_duration_seconds END
 FROM public.regional_dispatch_zone_settings s
 WHERE s.dispatch_type=$1 AND (
   (s.governorate_key=coalesce(nullif(lower(trim($3)),''),'all') AND s.category_key=coalesce(nullif(lower(trim($4)),''),'all'))
   OR (s.governorate_key=coalesce(nullif(lower(trim($3)),''),'all') AND s.category_key='all')
   OR (s.governorate_key='all' AND s.category_key=coalesce(nullif(lower(trim($4)),''),'all'))
   OR (s.governorate_key='all' AND s.category_key='all'))
 ORDER BY CASE
   WHEN s.governorate_key=coalesce(nullif(lower(trim($3)),''),'all') AND s.category_key=coalesce(nullif(lower(trim($4)),''),'all') THEN 1
   WHEN s.governorate_key=coalesce(nullif(lower(trim($3)),''),'all') AND s.category_key='all' THEN 2
   WHEN s.governorate_key='all' AND s.category_key=coalesce(nullif(lower(trim($4)),''),'all') THEN 3 ELSE 4 END
 LIMIT 1;
$;
REVOKE ALL ON FUNCTION public.get_regional_dispatch_ring_duration(text,integer,text,text) FROM PUBLIC,anon,authenticated;

DROP FUNCTION IF EXISTS public.admin_get_dispatch_zone_settings();
CREATE FUNCTION public.admin_get_dispatch_zone_settings()
RETURNS TABLE(governorate_key text,dispatch_type text,category_key text,
 ring1_min_km numeric,ring1_max_km numeric,ring2_min_km numeric,ring2_max_km numeric,
 ring3_min_km numeric,ring3_max_km numeric,ring1_duration_seconds integer,
 ring2_duration_seconds integer,ring3_duration_seconds integer,updated_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'forbidden'; END IF;
 RETURN QUERY SELECT s.governorate_key,s.dispatch_type,s.category_key,
  s.ring1_min_km,s.ring1_max_km,s.ring2_min_km,s.ring2_max_km,s.ring3_min_km,s.ring3_max_km,
  s.ring1_duration_seconds,s.ring2_duration_seconds,s.ring3_duration_seconds,s.updated_at
 FROM public.regional_dispatch_zone_settings s
 WHERE public.admin_has_permission('zones.manage',
  CASE WHEN s.governorate_key='all' THEN 'global' ELSE 'governorate' END,
  CASE WHEN s.governorate_key='all' THEN NULL ELSE s.governorate_key END)
 ORDER BY CASE s.governorate_key WHEN 'all' THEN 0 ELSE 1 END,s.governorate_key,
  CASE s.dispatch_type WHEN 'taxi' THEN 1 WHEN 'large_driver' THEN 2 ELSE 3 END,s.category_key;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_get_dispatch_zone_settings() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_get_dispatch_zone_settings() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_update_dispatch_zone_settings(
 p_governorate_key text,p_dispatch_type text,p_category_key text,
 p_ring1_max_km numeric,p_ring2_max_km numeric,p_ring3_max_km numeric,
 p_ring1_duration_seconds integer,p_ring2_duration_seconds integer,p_ring3_duration_seconds integer)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_key text:=lower(trim(coalesce(p_governorate_key,''))); v_category text:=lower(trim(coalesce(p_category_key,'all')));
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'forbidden'; END IF;
 IF v_key NOT IN ('all','baghdad','basra','nineveh','erbil','sulaymaniyah','duhok','kirkuk','najaf','karbala','babil','anbar','diyala','saladin','wasit','dhiqar','maysan','muthanna','qadisiyah')
  OR p_dispatch_type NOT IN ('taxi','large_driver','technician')
  OR (v_category<>'all' AND (p_dispatch_type<>'technician' OR NOT EXISTS(SELECT 1 FROM public.services s WHERE s.slug=v_category)))
  OR p_ring1_max_km<=0 OR p_ring2_max_km<=p_ring1_max_km OR p_ring3_max_km<=p_ring2_max_km OR p_ring3_max_km>55
  OR p_ring1_duration_seconds NOT BETWEEN 5 AND 3600 OR p_ring2_duration_seconds NOT BETWEEN 5 AND 3600 OR p_ring3_duration_seconds NOT BETWEEN 5 AND 3600
 THEN RAISE EXCEPTION 'invalid_dispatch_zone_or_duration'; END IF;
 IF NOT public.admin_has_permission('zones.manage',
  CASE WHEN v_key='all' THEN 'global' ELSE 'governorate' END,
  CASE WHEN v_key='all' THEN NULL ELSE v_key END)
 THEN RAISE EXCEPTION 'missing_dispatch_zone_permission'; END IF;
 INSERT INTO public.regional_dispatch_zone_settings(
  governorate_key,dispatch_type,category_key,ring1_min_km,ring1_max_km,ring2_min_km,ring2_max_km,ring3_min_km,ring3_max_km,
  ring1_duration_seconds,ring2_duration_seconds,ring3_duration_seconds,updated_at,updated_by)
 VALUES(v_key,p_dispatch_type,v_category,0,p_ring1_max_km,p_ring1_max_km,p_ring2_max_km,p_ring2_max_km,p_ring3_max_km,
  p_ring1_duration_seconds,p_ring2_duration_seconds,p_ring3_duration_seconds,now(),auth.uid())
 ON CONFLICT(governorate_key,dispatch_type,category_key) DO UPDATE SET
  ring1_min_km=0,ring1_max_km=excluded.ring1_max_km,ring2_min_km=excluded.ring2_min_km,ring2_max_km=excluded.ring2_max_km,
  ring3_min_km=excluded.ring3_min_km,ring3_max_km=excluded.ring3_max_km,
  ring1_duration_seconds=excluded.ring1_duration_seconds,ring2_duration_seconds=excluded.ring2_duration_seconds,
  ring3_duration_seconds=excluded.ring3_duration_seconds,updated_at=now(),updated_by=auth.uid();
 RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_update_dispatch_zone_settings(text,text,text,numeric,numeric,numeric,integer,integer,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_update_dispatch_zone_settings(text,text,text,numeric,numeric,numeric,integer,integer,integer) TO authenticated;

DO $$
DECLARE v_def text;
BEGIN
 v_def:=pg_get_functiondef('public.advance_taxi_dispatch(uuid)'::regprocedure);
 IF position('v_zone integer;' in v_def)=0 THEN RAISE EXCEPTION 'advance_taxi_dispatch declaration shape changed'; END IF;
 v_def:=replace(v_def,'v_zone integer;','v_zone integer;'||chr(10)||'  v_ring_seconds integer := 60;');
 v_def:=replace(v_def,
  'FROM public.get_regional_dispatch_ring(''large_driver'', q.stage, r.governorate_key, ''all'');',
  'FROM public.get_regional_dispatch_ring(''large_driver'', q.stage, r.governorate_key, ''all'');'||chr(10)||
  '    SELECT public.get_regional_dispatch_ring_duration(''large_driver'', q.stage, r.governorate_key, ''all'') INTO v_ring_seconds;');
 v_def:=replace(v_def,
  'FROM public.get_regional_dispatch_ring(''taxi'', q.stage, r.governorate_key, ''all'');',
  'FROM public.get_regional_dispatch_ring(''taxi'', q.stage, r.governorate_key, ''all'');'||chr(10)||
  '  SELECT public.get_regional_dispatch_ring_duration(''taxi'', q.stage, r.governorate_key, ''all'') INTO v_ring_seconds;');
 v_def:=replace(v_def,'next_at = now() + interval ''60 seconds'',
  'next_at = now() + make_interval(secs => greatest(coalesce(v_ring_seconds,60),1))');
 EXECUTE v_def;

 v_def:=pg_get_functiondef('public.advance_service_dispatch(uuid)'::regprocedure);
 IF position('v_zone integer;' in v_def)=0 THEN RAISE EXCEPTION 'advance_service_dispatch declaration shape changed'; END IF;
 v_def:=replace(v_def,'v_zone integer;','v_zone integer;'||chr(10)||'  v_ring_seconds integer := 60;');
 v_def:=replace(v_def,
  'FROM public.get_regional_dispatch_ring(''technician'', q.stage, r.governorate_key, (select slug from public.services where id = r.service_id));',
  'FROM public.get_regional_dispatch_ring(''technician'', q.stage, r.governorate_key, (select slug from public.services where id = r.service_id));'||chr(10)||
  '  SELECT public.get_regional_dispatch_ring_duration(''technician'', q.stage, r.governorate_key, (select slug from public.services where id = r.service_id)) INTO v_ring_seconds;');
 v_def:=replace(v_def,'next_at = now() + interval ''60 seconds'',
  'next_at = now() + make_interval(secs => greatest(coalesce(v_ring_seconds,60),1))');
 EXECUTE v_def;
END $$;
