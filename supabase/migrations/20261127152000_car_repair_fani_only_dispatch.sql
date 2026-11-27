-- A car-repair request is always a technician-level request, never an expert request.
DO $migration$
DECLARE
  v_def text;
  v_anchor text := $anchor$  IF q.next_at > now() THEN RETURN 0; END IF;$anchor$;
  v_guard text := $guard$  IF (SELECT s.slug FROM public.services s WHERE s.id = r.service_id) = 'car_repair'
     AND COALESCE(r.level_required::text, '') <> 'fani' THEN
    DELETE FROM public.service_dispatch_queue WHERE request_id = _request_id;
    RETURN 0;
  END IF;
$guard$;
BEGIN
  SELECT pg_get_functiondef('public.advance_service_dispatch(uuid)'::regprocedure)
    INTO v_def;
  IF position(v_anchor in v_def) = 0 THEN
    RAISE EXCEPTION 'advance_service_dispatch anchor missing; refusing unsafe fani-only guard';
  END IF;
  IF position('COALESCE(r.level_required::text' in v_def) > 0 THEN
    RAISE NOTICE 'Car repair fani-only guard already present';
    RETURN;
  END IF;
  v_def := replace(v_def, v_anchor, v_anchor || E'\n' || v_guard);
  EXECUTE v_def;
END
$migration$;
