do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.refresh_regional_peak_pricing_monitor()'::regprocedure);
 v_def:=replace(v_def,'where r.setting_id=z.id and r.status=''pending'' and r.created_at>now()-interval ''30 minutes''','where r.setting_id=z.id and r.created_at>now()-interval ''30 minutes''');
 if position('r.setting_id=z.id and r.created_at>now()-interval ''30 minutes''' in v_def)=0 then raise exception 'regional_peak_notification_cooldown_rewrite_failed'; end if;
 execute v_def;
end $$;