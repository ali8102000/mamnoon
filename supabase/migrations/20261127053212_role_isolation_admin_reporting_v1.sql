DO $$
DECLARE v_def text;
BEGIN
 v_def:=pg_get_functiondef('public.admin_create_provider_mission'::regproc);
 v_def:=replace(v_def,
  'or (p_provider_type=''large_driver'' and exists(select 1 from public.driver_profiles dp where dp.user_id=ur.user_id and dp.status=''approved''))',
  'or (p_provider_type=''large_driver'' and exists(select 1 from public.naqil_profiles np where np.user_id=ur.user_id and np.status=''approved'' and np.vehicle_category=''large''::public.vehicle_category))');
 EXECUTE v_def;

 v_def:=pg_get_functiondef('public.admin_governorate_user_stats'::regproc);
 v_def:=replace(v_def,'coalesce(dp.vehicle_category::text = ''large'', false)','coalesce(np.vehicle_category::text = ''large'', false)');
 v_def:=replace(v_def,'coalesce(dp.vehicle_type in (''kia_cargo'', ''kia_passenger''), false)','coalesce(np.vehicle_type in (''kia_cargo'', ''kia_passenger''), false)');
 v_def:=replace(v_def,'or dp.user_id is not null','or dp.user_id is not null or np.user_id is not null');
 v_def:=replace(v_def,'left join public.driver_profiles dp on dp.user_id = p.id',
  'left join public.driver_profiles dp on dp.user_id = p.id
    left join public.naqil_profiles np on np.user_id = p.id');
 EXECUTE v_def;
END $$;

