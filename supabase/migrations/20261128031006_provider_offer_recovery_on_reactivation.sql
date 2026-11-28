CREATE OR REPLACE FUNCTION public.recover_available_provider_offers(p_provider_role text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_role text := lower(trim(coalesce(p_provider_role, '')));
  v_row record;
  r public.service_requests%ROWTYPE;
  v_stage integer;
  v_dispatch_type text;
  v_category_key text;
  v_max_radius numeric;
  v_lat double precision;
  v_lng double precision;
  v_distance numeric;
  v_service_radius numeric;
  v_service_slug text;
  v_offer_id uuid;
  v_count integer := 0;
  v_affected integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  IF v_role NOT IN ('driver', 'large_driver', 'worker') THEN
    RAISE EXCEPTION 'invalid_provider_role';
  END IF;

  IF NOT public.has_role(v_uid, v_role::public.app_role) THEN
    RAISE EXCEPTION 'provider_role_required';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text || ':' || v_role || ':offer-recovery', 0));

  IF v_role = 'driver' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.driver_profiles p
      WHERE p.user_id = v_uid AND p.available = true AND p.status = 'approved'
        AND p.vehicle_category IN ('economy', 'premium', 'luxury')
        AND (p.suspended_until IS NULL OR p.suspended_until <= now())
    ) THEN
      RETURN 0;
    END IF;
    v_dispatch_type := 'taxi';
    v_category_key := 'all';
  ELSIF v_role = 'large_driver' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.naqil_profiles p
      WHERE p.user_id = v_uid AND p.available = true AND p.status = 'approved'
        AND p.vehicle_category = 'large'::public.vehicle_category
        AND (p.suspended_until IS NULL OR p.suspended_until <= now())
    ) THEN
      RETURN 0;
    END IF;
    v_dispatch_type := 'large_driver';
    v_category_key := 'all';
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM public.worker_profiles p
      WHERE p.user_id = v_uid AND p.available = true AND p.status = 'approved'
        AND (p.suspended_until IS NULL OR p.suspended_until <= now())
    ) THEN
      RETURN 0;
    END IF;
    v_dispatch_type := 'technician';
    v_category_key := 'all';
  END IF;

  SELECT pp.lat, pp.lng
    INTO v_lat, v_lng
  FROM public.provider_presence_roles pp
  WHERE pp.user_id = v_uid
    AND pp.role = v_role
    AND pp.status = 'online'
    AND pp.updated_at > now() - interval '5 minutes'
    AND pp.accuracy_m IS NOT NULL
    AND pp.accuracy_m <= 100
  LIMIT 1;

  IF v_lat IS NULL OR v_lng IS NULL THEN
    RETURN 0;
  END IF;

  FOR v_row IN
    SELECT sr.id, sr.created_at
    FROM public.service_requests sr
    WHERE sr.status IN ('pending', 'searching')
      AND sr.provider_id IS NULL
      AND (
        (v_role = 'worker' AND sr.type = 'service'
          AND EXISTS (SELECT 1 FROM public.service_dispatch_queue q WHERE q.request_id = sr.id))
        OR
        (v_role = 'driver' AND sr.type = 'taxi'
          AND sr.vehicle_category::text IS DISTINCT FROM 'large'
          AND EXISTS (SELECT 1 FROM public.taxi_dispatch_queue q WHERE q.request_id = sr.id))
        OR
        (v_role = 'large_driver' AND sr.type = 'taxi'
          AND sr.vehicle_category::text = 'large'
          AND EXISTS (SELECT 1 FROM public.taxi_dispatch_queue q WHERE q.request_id = sr.id))
      )
    ORDER BY sr.created_at DESC
    LIMIT 30
  LOOP
    SELECT * INTO r
    FROM public.service_requests
    WHERE id = v_row.id
    FOR UPDATE;

    IF NOT FOUND OR r.status NOT IN ('pending', 'searching') OR r.provider_id IS NOT NULL THEN
      CONTINUE;
    END IF;

    IF v_role = 'worker' THEN
      SELECT q.stage INTO v_stage
      FROM public.service_dispatch_queue q
      WHERE q.request_id = r.id
      FOR UPDATE;
    ELSE
      SELECT q.stage INTO v_stage
      FROM public.taxi_dispatch_queue q
      WHERE q.request_id = r.id
      FOR UPDATE;
    END IF;

    IF v_stage IS NULL OR v_stage >= 6 THEN
      CONTINUE;
    END IF;

    IF v_role = 'worker' THEN
      SELECT s.slug INTO v_service_slug
      FROM public.services s
      WHERE s.id = r.service_id;

      SELECT max(ring.max_km) INTO v_max_radius
      FROM generate_series(0, greatest(v_stage - 1, 0)) AS stages(stage)
      CROSS JOIN LATERAL public.get_regional_dispatch_ring(
        'technician', stages.stage, r.governorate_key, coalesce(v_service_slug, 'all')
      ) AS ring;
    ELSIF v_role = 'large_driver' THEN
      SELECT max(ring.max_km) INTO v_max_radius
      FROM generate_series(0, greatest(v_stage - 1, 0)) AS stages(stage)
      CROSS JOIN LATERAL public.get_regional_dispatch_ring(
        'large_driver', stages.stage, r.governorate_key, 'all'
      ) AS ring;
    ELSE
      SELECT max(ring.max_km) INTO v_max_radius
      FROM generate_series(0, greatest(v_stage - 1, 0)) AS stages(stage)
      CROSS JOIN LATERAL public.get_regional_dispatch_ring(
        'taxi', stages.stage, r.governorate_key, 'all'
      ) AS ring;
    END IF;

    IF v_max_radius IS NULL OR v_max_radius <= 0 THEN
      CONTINUE;
    END IF;

    v_distance := NULL;

    IF v_role = 'driver' THEN
      SELECT d.distance_km INTO v_distance
      FROM public.find_nearby_drivers(
        r.pickup_lat, r.pickup_lng, r.vehicle_category::text, v_max_radius, 1000
      ) d
      WHERE d.user_id = v_uid
      LIMIT 1;
    ELSIF v_role = 'large_driver' THEN
      SELECT d.distance_km INTO v_distance
      FROM public.find_nearby_drivers(
        r.pickup_lat, r.pickup_lng, 'large', v_max_radius, 1000
      ) d
      JOIN public.naqil_profiles np ON np.user_id = d.user_id
      WHERE d.user_id = v_uid
        AND (r.vehicle_type IS NULL OR np.vehicle_type = r.vehicle_type)
      LIMIT 1;
    ELSE
      SELECT
        (6371 * acos(least(1.0, greatest(-1.0,
          cos(radians(r.pickup_lat::double precision)) * cos(radians(pp.lat)) *
          cos(radians(pp.lng) - radians(r.pickup_lng::double precision)) +
          sin(radians(r.pickup_lat::double precision)) * sin(radians(pp.lat))
        ))))::numeric,
        least(coalesce(wp.service_radius_km, 25), 55)
      INTO v_distance, v_service_radius
      FROM public.worker_profiles wp
      JOIN public.worker_services ws
        ON ws.worker_id = wp.user_id AND ws.service_id = r.service_id
      JOIN public.provider_presence_roles pp
        ON pp.user_id = wp.user_id AND pp.role = 'worker'
      WHERE wp.user_id = v_uid
        AND wp.available = true
        AND wp.status = 'approved'
        AND (wp.suspended_until IS NULL OR wp.suspended_until <= now())
        AND wp.level = r.level_required
        AND pp.status = 'online'
        AND pp.updated_at > now() - interval '5 minutes'
        AND pp.accuracy_m IS NOT NULL AND pp.accuracy_m <= 100
        AND r.pickup_lat IS NOT NULL AND r.pickup_lng IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public.service_requests active
          WHERE active.provider_id = wp.user_id
            AND active.provider_role = 'worker'
            AND active.status IN ('accepted', 'in_progress')
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.service_request_providers srp
          JOIN public.service_requests active_team ON active_team.id = srp.request_id
          WHERE srp.provider_id = wp.user_id
            AND active_team.provider_role = 'worker'
            AND active_team.status IN ('pending', 'searching', 'accepted', 'in_progress')
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.user_blocks b
          WHERE b.user_id = wp.user_id
            AND (b.expires_at IS NULL OR b.expires_at > now())
        )
      LIMIT 1;

      IF v_distance IS NOT NULL AND (v_distance > v_service_radius OR v_distance > v_max_radius) THEN
        v_distance := NULL;
      END IF;
      IF r.service_id IS NULL
        OR coalesce((SELECT sum(srp.team_size) FROM public.service_request_providers srp WHERE srp.request_id = r.id), 0)
          >= greatest(coalesce(r.workers_count, 1), 1)
        OR r.staffing_search_paused_at IS NOT NULL
        OR (SELECT s.slug FROM public.services s WHERE s.id = r.service_id) = 'car_repair'
           AND coalesce(r.level_required::text, '') <> 'fani'
      THEN
        v_distance := NULL;
      END IF;
    END IF;

    IF v_distance IS NULL THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.request_offers o
      WHERE o.request_id = r.id
        AND o.provider_id = v_uid
        AND o.status IN ('pending', 'accepted', 'rejected')
    ) THEN
      CONTINUE;
    END IF;

    INSERT INTO public.request_offers(
      request_id, provider_id, provider_role, distance_km, status, sent_at, expires_at
    )
    VALUES (
      r.id, v_uid, v_role, v_distance, 'pending', now(), now() + interval '60 seconds'
    )
    ON CONFLICT (request_id, provider_id) DO UPDATE
    SET provider_role = EXCLUDED.provider_role,
        distance_km = EXCLUDED.distance_km,
        status = 'pending',
        sent_at = now(),
        expires_at = now() + interval '60 seconds',
        responded_at = NULL,
        proposed_price = NULL,
        offer_message = NULL
    WHERE public.request_offers.status IN ('expired', 'cancelled')
      AND public.request_offers.proposed_price IS NULL
    RETURNING id INTO v_offer_id;

    GET DIAGNOSTICS v_affected = ROW_COUNT;
    IF v_affected > 0 THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$function$


REVOKE ALL ON FUNCTION public.recover_available_provider_offers(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.recover_available_provider_offers(text) TO authenticated;
