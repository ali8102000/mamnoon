-- Six distinct dispatch rings with independent timers per province and service category.
ALTER TABLE public.regional_dispatch_zone_settings
  ADD COLUMN IF NOT EXISTS ring4_min_km numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ring4_max_km numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ring5_min_km numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ring5_max_km numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ring6_min_km numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ring6_max_km numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ring4_duration_seconds integer NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS ring5_duration_seconds integer NOT NULL DEFAULT 60,
  ADD COLUMN IF NOT EXISTS ring6_duration_seconds integer NOT NULL DEFAULT 60;

UPDATE public.regional_dispatch_zone_settings s
SET ring1_min_km=0,
    ring1_max_km=CASE WHEN s.dispatch_type='taxi' THEN round(s.ring3_max_km/5,2) ELSE round(s.ring3_max_km*5/55,2) END,
    ring2_min_km=CASE WHEN s.dispatch_type='taxi' THEN round(s.ring3_max_km/5,2) ELSE round(s.ring3_max_km*5/55,2) END,
    ring2_max_km=CASE WHEN s.dispatch_type='taxi' THEN round(s.ring3_max_km*2/5,2) ELSE round(s.ring3_max_km*10/55,2) END,
    ring3_min_km=CASE WHEN s.dispatch_type='taxi' THEN round(s.ring3_max_km*2/5,2) ELSE round(s.ring3_max_km*10/55,2) END,
    ring3_max_km=CASE WHEN s.dispatch_type='taxi' THEN round(s.ring3_max_km*3/5,2) ELSE round(s.ring3_max_km*20/55,2) END,
    ring4_min_km=CASE WHEN s.dispatch_type='taxi' THEN round(s.ring3_max_km*3/5,2) ELSE round(s.ring3_max_km*20/55,2) END,
    ring4_max_km=CASE WHEN s.dispatch_type='taxi' THEN round(s.ring3_max_km*4/5,2) ELSE round(s.ring3_max_km*30/55,2) END,
    ring5_min_km=CASE WHEN s.dispatch_type='taxi' THEN round(s.ring3_max_km*4/5,2) ELSE round(s.ring3_max_km*30/55,2) END,
    ring5_max_km=CASE WHEN s.dispatch_type='taxi' THEN round(s.ring3_max_km*4.5/5,2) ELSE round(s.ring3_max_km*40/55,2) END,
    ring6_min_km=CASE WHEN s.dispatch_type='taxi' THEN round(s.ring3_max_km*4.5/5,2) ELSE round(s.ring3_max_km*40/55,2) END,
    ring6_max_km=s.ring3_max_km,
    ring4_duration_seconds=60,ring5_duration_seconds=60,ring6_duration_seconds=60;

DO $$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='regional_dispatch_ring4_6_valid') THEN
  ALTER TABLE public.regional_dispatch_zone_settings ADD CONSTRAINT regional_dispatch_ring4_6_valid CHECK (
   ring4_min_km>=ring3_max_km AND ring4_max_km>ring4_min_km AND
   ring5_min_km=ring4_max_km AND ring5_max_km>ring5_min_km AND
   ring6_min_km=ring5_max_km AND ring6_max_km>ring6_min_km AND ring6_max_km<=55 AND
   ring4_duration_seconds BETWEEN 5 AND 3600 AND ring5_duration_seconds BETWEEN 5 AND 3600 AND ring6_duration_seconds BETWEEN 5 AND 3600
  );
 END IF;
END $$;

CREATE OR REPLACE FUNCTION public.get_regional_dispatch_ring(p_dispatch_type text,p_stage integer,p_governorate_key text,p_category_key text)
RETURNS TABLE(min_km numeric,max_km numeric) LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
 SELECT
  CASE ((greatest(coalesce(p_stage,0),0)%6)+1)
   WHEN 1 THEN s.ring1_min_km WHEN 2 THEN s.ring2_min_km WHEN 3 THEN s.ring3_min_km
   WHEN 4 THEN s.ring4_min_km WHEN 5 THEN s.ring5_min_km ELSE s.ring6_min_km END,
  CASE ((greatest(coalesce(p_stage,0),0)%6)+1)
   WHEN 1 THEN s.ring1_max_km WHEN 2 THEN s.ring2_max_km WHEN 3 THEN s.ring3_max_km
   WHEN 4 THEN s.ring4_max_km WHEN 5 THEN s.ring5_max_km ELSE s.ring6_max_km END
 FROM public.regional_dispatch_zone_settings s
 WHERE s.dispatch_type=p_dispatch_type AND (
  (s.governorate_key=coalesce(nullif(lower(trim(p_governorate_key)),''),'all') AND s.category_key=coalesce(nullif(lower(trim(p_category_key)),''),'all'))
  OR (s.governorate_key=coalesce(nullif(lower(trim(p_governorate_key)),''),'all') AND s.category_key='all')
  OR (s.governorate_key='all' AND s.category_key=coalesce(nullif(lower(trim(p_category_key)),''),'all'))
  OR (s.governorate_key='all' AND s.category_key='all'))
 ORDER BY CASE
  WHEN s.governorate_key=coalesce(nullif(lower(trim(p_governorate_key)),''),'all') AND s.category_key=coalesce(nullif(lower(trim(p_category_key)),''),'all') THEN 1
  WHEN s.governorate_key=coalesce(nullif(lower(trim(p_governorate_key)),''),'all') AND s.category_key='all' THEN 2
  WHEN s.governorate_key='all' AND s.category_key=coalesce(nullif(lower(trim(p_category_key)),''),'all') THEN 3 ELSE 4 END
 LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.get_regional_dispatch_ring_duration(p_dispatch_type text,p_stage integer,p_governorate_key text,p_category_key text)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
 SELECT CASE ((greatest(coalesce(p_stage,0),0)%6)+1)
  WHEN 1 THEN s.ring1_duration_seconds WHEN 2 THEN s.ring2_duration_seconds WHEN 3 THEN s.ring3_duration_seconds
  WHEN 4 THEN s.ring4_duration_seconds WHEN 5 THEN s.ring5_duration_seconds ELSE s.ring6_duration_seconds END
 FROM public.regional_dispatch_zone_settings s
 WHERE s.dispatch_type=p_dispatch_type AND (
  (s.governorate_key=coalesce(nullif(lower(trim(p_governorate_key)),''),'all') AND s.category_key=coalesce(nullif(lower(trim(p_category_key)),''),'all'))
  OR (s.governorate_key=coalesce(nullif(lower(trim(p_governorate_key)),''),'all') AND s.category_key='all')
  OR (s.governorate_key='all' AND s.category_key=coalesce(nullif(lower(trim(p_category_key)),''),'all'))
  OR (s.governorate_key='all' AND s.category_key='all'))
 ORDER BY CASE
  WHEN s.governorate_key=coalesce(nullif(lower(trim(p_governorate_key)),''),'all') AND s.category_key=coalesce(nullif(lower(trim(p_category_key)),''),'all') THEN 1
  WHEN s.governorate_key=coalesce(nullif(lower(trim(p_governorate_key)),''),'all') AND s.category_key='all' THEN 2
  WHEN s.governorate_key='all' AND s.category_key=coalesce(nullif(lower(trim(p_category_key)),''),'all') THEN 3 ELSE 4 END
 LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.get_regional_dispatch_ring(text,integer,text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.get_regional_dispatch_ring_duration(text,integer,text,text) FROM PUBLIC,anon,authenticated;

DROP FUNCTION IF EXISTS public.admin_get_dispatch_zone_settings();
CREATE FUNCTION public.admin_get_dispatch_zone_settings()
RETURNS TABLE(governorate_key text,dispatch_type text,category_key text,
 ring1_min_km numeric,ring1_max_km numeric,ring2_min_km numeric,ring2_max_km numeric,
 ring3_min_km numeric,ring3_max_km numeric,ring4_min_km numeric,ring4_max_km numeric,
 ring5_min_km numeric,ring5_max_km numeric,ring6_min_km numeric,ring6_max_km numeric,
 ring1_duration_seconds integer,ring2_duration_seconds integer,ring3_duration_seconds integer,
 ring4_duration_seconds integer,ring5_duration_seconds integer,ring6_duration_seconds integer,updated_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'forbidden'; END IF;
 RETURN QUERY SELECT s.governorate_key,s.dispatch_type,s.category_key,
  s.ring1_min_km,s.ring1_max_km,s.ring2_min_km,s.ring2_max_km,s.ring3_min_km,s.ring3_max_km,
  s.ring4_min_km,s.ring4_max_km,s.ring5_min_km,s.ring5_max_km,s.ring6_min_km,s.ring6_max_km,
  s.ring1_duration_seconds,s.ring2_duration_seconds,s.ring3_duration_seconds,
  s.ring4_duration_seconds,s.ring5_duration_seconds,s.ring6_duration_seconds,s.updated_at
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
 p_ring4_max_km numeric,p_ring5_max_km numeric,p_ring6_max_km numeric,
 p_ring1_duration_seconds integer,p_ring2_duration_seconds integer,p_ring3_duration_seconds integer,
 p_ring4_duration_seconds integer,p_ring5_duration_seconds integer,p_ring6_duration_seconds integer)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_key text:=lower(trim(coalesce(p_governorate_key,''))); v_category text:=lower(trim(coalesce(p_category_key,'all')));
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'forbidden'; END IF;
 IF v_key NOT IN ('all','baghdad','basra','nineveh','erbil','sulaymaniyah','duhok','kirkuk','najaf','karbala','babil','anbar','diyala','saladin','wasit','dhiqar','maysan','muthanna','qadisiyah')
  OR p_dispatch_type NOT IN ('taxi','large_driver','technician')
  OR (v_category<>'all' AND (p_dispatch_type<>'technician' OR NOT EXISTS(SELECT 1 FROM public.services s WHERE s.slug=v_category)))
  OR p_ring1_max_km<=0 OR p_ring2_max_km<=p_ring1_max_km OR p_ring3_max_km<=p_ring2_max_km
  OR p_ring4_max_km<=p_ring3_max_km OR p_ring5_max_km<=p_ring4_max_km OR p_ring6_max_km<=p_ring5_max_km OR p_ring6_max_km>55
  OR p_ring1_duration_seconds NOT BETWEEN 5 AND 3600 OR p_ring2_duration_seconds NOT BETWEEN 5 AND 3600
  OR p_ring3_duration_seconds NOT BETWEEN 5 AND 3600 OR p_ring4_duration_seconds NOT BETWEEN 5 AND 3600
  OR p_ring5_duration_seconds NOT BETWEEN 5 AND 3600 OR p_ring6_duration_seconds NOT BETWEEN 5 AND 3600
 THEN RAISE EXCEPTION 'invalid_dispatch_zone_or_duration'; END IF;
 IF NOT public.admin_has_permission('zones.manage',
  CASE WHEN v_key='all' THEN 'global' ELSE 'governorate' END,
  CASE WHEN v_key='all' THEN NULL ELSE v_key END)
 THEN RAISE EXCEPTION 'missing_dispatch_zone_permission'; END IF;
 INSERT INTO public.regional_dispatch_zone_settings(governorate_key,dispatch_type,category_key,
  ring1_min_km,ring1_max_km,ring2_min_km,ring2_max_km,ring3_min_km,ring3_max_km,
  ring4_min_km,ring4_max_km,ring5_min_km,ring5_max_km,ring6_min_km,ring6_max_km,
  ring1_duration_seconds,ring2_duration_seconds,ring3_duration_seconds,ring4_duration_seconds,ring5_duration_seconds,ring6_duration_seconds,updated_at,updated_by)
 VALUES(v_key,p_dispatch_type,v_category,
  0,p_ring1_max_km,p_ring1_max_km,p_ring2_max_km,p_ring2_max_km,p_ring3_max_km,
  p_ring3_max_km,p_ring4_max_km,p_ring4_max_km,p_ring5_max_km,p_ring5_max_km,p_ring6_max_km,
  p_ring1_duration_seconds,p_ring2_duration_seconds,p_ring3_duration_seconds,p_ring4_duration_seconds,p_ring5_duration_seconds,p_ring6_duration_seconds,now(),auth.uid())
 ON CONFLICT(governorate_key,dispatch_type,category_key) DO UPDATE SET
  ring1_min_km=excluded.ring1_min_km,ring1_max_km=excluded.ring1_max_km,ring2_min_km=excluded.ring2_min_km,ring2_max_km=excluded.ring2_max_km,
  ring3_min_km=excluded.ring3_min_km,ring3_max_km=excluded.ring3_max_km,ring4_min_km=excluded.ring4_min_km,ring4_max_km=excluded.ring4_max_km,
  ring5_min_km=excluded.ring5_min_km,ring5_max_km=excluded.ring5_max_km,ring6_min_km=excluded.ring6_min_km,ring6_max_km=excluded.ring6_max_km,
  ring1_duration_seconds=excluded.ring1_duration_seconds,ring2_duration_seconds=excluded.ring2_duration_seconds,ring3_duration_seconds=excluded.ring3_duration_seconds,
  ring4_duration_seconds=excluded.ring4_duration_seconds,ring5_duration_seconds=excluded.ring5_duration_seconds,ring6_duration_seconds=excluded.ring6_duration_seconds,
  updated_at=now(),updated_by=auth.uid();
 RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_update_dispatch_zone_settings(text,text,text,numeric,numeric,numeric,numeric,numeric,numeric,integer,integer,integer,integer,integer,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_update_dispatch_zone_settings(text,text,text,numeric,numeric,numeric,numeric,numeric,numeric,integer,integer,integer,integer,integer,integer) TO authenticated;

SELECT cron.alter_job(22,schedule:='1 second');
