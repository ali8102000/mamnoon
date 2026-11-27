do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.admin_save_regional_peak_pricing(text,text,text,text,double precision,double precision,numeric,numeric,numeric,text,boolean)'::regprocedure);
 v_def:=replace(v_def,'active_percent=case when excluded.enabled then regional_peak_pricing_settings.active_percent else 0 end','active_percent=0');
 v_def:=replace(v_def,'manual_override_until=case when excluded.enabled then regional_peak_pricing_settings.manual_override_until else null end','manual_override_until=null');
 if position('active_percent=0' in v_def)=0 or position('manual_override_until=null' in v_def)=0 then raise exception 'regional_peak_save_reset_rewrite_failed'; end if;
 execute v_def;
end $$;