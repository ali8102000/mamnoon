DO $$
DECLARE v_def text;
BEGIN
 v_def:=pg_get_functiondef('public.notify_taxi_drivers_on_new_demand()'::regprocedure);
 v_def:=replace(v_def,
  'join public.provider_presence pp on pp.user_id = dp.user_id',
  'join public.provider_presence_roles pp on pp.user_id = dp.user_id and pp.role = ''driver'' and pp.status = ''online''');
 EXECUTE v_def;

 v_def:=pg_get_functiondef('public.notify_taxi_driver_high_demand()'::regprocedure);
 v_def:=replace(v_def,
  'BEGIN IF NOT EXISTS(SELECT 1 FROM public.user_roles',
  'BEGIN IF TG_TABLE_NAME = ''provider_presence_roles'' AND COALESCE(to_jsonb(NEW)->>''role'','''') <> ''driver'' THEN RETURN NEW; END IF; IF NOT EXISTS(SELECT 1 FROM public.user_roles');
 EXECUTE v_def;
END $$;

DROP TRIGGER IF EXISTS trg_notify_taxi_driver_high_demand_role ON public.provider_presence_roles;
CREATE TRIGGER trg_notify_taxi_driver_high_demand_role
 AFTER INSERT OR UPDATE OF lat,lng,updated_at ON public.provider_presence_roles
 FOR EACH ROW WHEN (NEW.role='driver')
 EXECUTE FUNCTION public.notify_taxi_driver_high_demand();

