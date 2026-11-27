do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.calculate_taxi_quote_internal(text,boolean,numeric,numeric,text,integer,boolean,numeric)'::regprocedure);
 v_def:=replace(v_def,'p_auto_percent numeric)','p_auto_percent numeric, p_regional_peak_percent numeric)');
 v_def:=replace(v_def,'v_auto_enabled boolean := false;','v_auto_enabled boolean := false;'||chr(10)||'  v_regional_peak_percent numeric := 0;');
 v_def:=replace(v_def,
 $old$  IF p_auto_percent IS NULL OR p_auto_percent::text IN ('NaN','Infinity','-Infinity') OR p_auto_percent < -50 OR p_auto_percent > 200 THEN
    RAISE EXCEPTION 'invalid_auto_pricing_percent';
  END IF;$old$,
 $new$  IF p_auto_percent IS NULL OR p_auto_percent::text IN ('NaN','Infinity','-Infinity') OR p_auto_percent < -50 OR p_auto_percent > 200 THEN
    RAISE EXCEPTION 'invalid_auto_pricing_percent';
  END IF;
  IF p_regional_peak_percent IS NULL OR p_regional_peak_percent::text IN ('NaN','Infinity','-Infinity') OR p_regional_peak_percent < 0 OR p_regional_peak_percent > 100 THEN
    RAISE EXCEPTION 'invalid_regional_peak_percent';
  END IF;$new$);
 v_def:=replace(v_def,
 $old$  v_auto_percent := CASE WHEN COALESCE(v_auto_enabled,false)
    THEN greatest(-50,least(200,p_auto_percent)) ELSE 0 END;$old$,
 $new$  v_auto_percent := CASE WHEN COALESCE(v_auto_enabled,false)
    THEN greatest(-50,least(200,p_auto_percent)) ELSE 0 END;
  v_regional_peak_percent := greatest(0,least(100,p_regional_peak_percent));$new$);
 v_def:=replace(v_def,'v_peak_percent + v_regional_percent + v_auto_percent) / 100.0','v_peak_percent + v_regional_percent + v_auto_percent + v_regional_peak_percent) / 100.0');
 v_def:=replace(v_def,'''autoPercent'',v_auto_percent,','''autoPercent'',v_auto_percent,'||chr(10)||'    ''regionalPeakPercent'',v_regional_peak_percent,');
 v_def:=replace(v_def,'v_peak_percent + v_regional_percent + v_auto_percent,','v_peak_percent + v_regional_percent + v_auto_percent + v_regional_peak_percent,');
 if position('p_regional_peak_percent' in v_def)=0 or position('regionalPeakPercent' in v_def)=0 then raise exception 'regional_peak_quote_function_rewrite_failed'; end if;
 execute v_def;
end $$;
revoke all on function public.calculate_taxi_quote_internal(text,boolean,numeric,numeric,text,integer,boolean,numeric,numeric) from public,anon,authenticated;
grant execute on function public.calculate_taxi_quote_internal(text,boolean,numeric,numeric,text,integer,boolean,numeric,numeric) to service_role;