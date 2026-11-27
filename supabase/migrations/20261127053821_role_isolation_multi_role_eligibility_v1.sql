DO $$
DECLARE v_def text;
BEGIN
 v_def:=pg_get_functiondef('public.accept_large_vehicle_offer'::regproc);
 v_def:=regexp_replace(v_def,
  'WHERE sr\.provider_id = o\.provider_id[[:space:]]+AND sr\.status IN',
  'WHERE sr.provider_id = o.provider_id AND sr.provider_role = ''large_driver'' AND sr.status IN',
  'g');
 EXECUTE v_def;

 v_def:=pg_get_functiondef('public.admin_create_provider_mission'::regproc);
 v_def:=replace(v_def,
  '    and (p_provider_type<>''driver'' or not exists(select 1 from public.user_roles other_role where other_role.user_id=ur.user_id and other_role.role::text=''large_driver''))',
  '');
 EXECUTE v_def;

 v_def:=pg_get_functiondef('public.admin_governorate_user_stats'::regproc);
 v_def:=replace(v_def,
  $old$coalesce('driver' = any(r.roles), false) and not (
        coalesce('large_driver' = any(r.roles), false)
        or coalesce(np.vehicle_category::text = 'large', false)
        or coalesce(np.vehicle_type in ('kia_cargo', 'kia_passenger'), false)
      ) as is_taxi_driver,$old$,
  $new$coalesce('driver' = any(r.roles), false) and dp.user_id is not null as is_taxi_driver,$new$);
 EXECUTE v_def;
END $$;

