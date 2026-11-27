DO $$
DECLARE v_def text;
BEGIN
 v_def:=pg_get_functiondef('public.refresh_taxi_pricing_monitor'::regproc);
 v_def:=replace(v_def,'FROM public.provider_presence pp','FROM public.provider_presence_roles pp');
 v_def:=replace(v_def,'WHERE pp.updated_at > now()-interval ''5 minutes''',
  'WHERE pp.role=''driver'' AND pp.status=''online'' AND pp.updated_at > now()-interval ''5 minutes''');
 v_def:=replace(v_def,'WHERE ar.provider_id=dp.user_id AND ar.status IN',
  'WHERE ar.provider_id=dp.user_id AND ar.provider_role=''driver'' AND ar.status IN');
 EXECUTE v_def;
END $$;

