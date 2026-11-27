CREATE OR REPLACE VIEW public.provider_role_profiles_presence AS
 SELECT user_id,'driver'::text AS role,vehicle_category::text AS vehicle_category,status,available,suspended_until,service_radius_km
 FROM public.driver_profiles
 UNION ALL
 SELECT user_id,'large_driver'::text AS role,vehicle_category::text AS vehicle_category,status,available,suspended_until,service_radius_km
 FROM public.naqil_profiles;

DO $$
DECLARE v_def text;
BEGIN
 v_def:=pg_get_functiondef('public.refresh_category_peak_pricing_monitor()'::regprocedure);
 v_def:=replace(v_def,
  'join public.provider_presence pp on pp.user_id=wp.user_id',
  'join public.provider_presence_roles pp on pp.user_id=wp.user_id and pp.role=''worker''');
 v_def:=replace(v_def,
  'from public.driver_profiles dp
    join public.provider_presence pp on pp.user_id=dp.user_id',
  'from public.provider_role_profiles_presence dp
    join public.provider_presence_roles pp on pp.user_id=dp.user_id and pp.role=dp.role');
 v_def:=replace(v_def,
  'where active.provider_id=wp.user_id and lower(active.status::text)',
  'where active.provider_id=wp.user_id and active.provider_role=''worker'' and lower(active.status::text)');
 v_def:=replace(v_def,
  'where active.provider_id=dp.user_id and lower(active.status::text)',
  'where active.provider_id=dp.user_id and active.provider_role=dp.role and lower(active.status::text)');
 v_def:=replace(v_def,
  'where srp.provider_id=wp.user_id
          and lower(active_team.status::text)',
  'where srp.provider_id=wp.user_id and active_team.provider_role=''worker''
          and lower(active_team.status::text)');
 EXECUTE v_def;
END $$;

