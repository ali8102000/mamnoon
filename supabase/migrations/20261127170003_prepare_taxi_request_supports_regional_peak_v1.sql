do $$
declare v_def text;
begin
 v_def:=pg_get_functiondef('public.prepare_taxi_request()'::regprocedure);
 v_def:=replace(v_def,
 $old$    COALESCE(NEW.taxi_auto_percent,0)
  );$old$,
 $new$    COALESCE(NEW.taxi_auto_percent,0),
    COALESCE(NEW.regional_peak_percent,0)
  );$new$);
 v_def:=replace(v_def,
 $old$  NEW.taxi_auto_percent := COALESCE((v_quote->>'autoPercent')::numeric,0);$old$,
 $new$  NEW.taxi_auto_percent := COALESCE((v_quote->>'autoPercent')::numeric,0);
  NEW.regional_peak_percent := COALESCE((v_quote->>'regionalPeakPercent')::numeric,0);$new$);
 if position('COALESCE(NEW.regional_peak_percent,0)' in v_def)=0 or position('v_quote->>''regionalPeakPercent''' in v_def)=0 then
  raise exception 'prepare_taxi_request_regional_peak_rewrite_failed';
 end if;
 execute v_def;
end $$;