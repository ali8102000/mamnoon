CREATE OR REPLACE FUNCTION public.cancel_request_urgency(_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  r public.service_requests%ROWTYPE;
  v_base numeric;
  v_restored numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT *
  INTO r
  FROM public.service_requests
  WHERE id = _request_id
  FOR UPDATE;

  IF NOT FOUND OR r.customer_id <> auth.uid() THEN
    RAISE EXCEPTION 'request_not_found_or_forbidden';
  END IF;

  IF r.status::text NOT IN ('pending', 'searching') OR r.provider_id IS NOT NULL THEN
    RAISE EXCEPTION 'urgency_can_only_be_cancelled_while_searching';
  END IF;

  IF COALESCE(r.urgency_multiplier, 1) <= 1
     AND NOT COALESCE(r.taxi_urgency_enabled, false) THEN
    RAISE EXCEPTION 'request_urgency_not_active';
  END IF;

  IF r.type::text = 'taxi' AND r.vehicle_category::text <> 'large' THEN
    v_base := COALESCE(r.urgency_base_price, r.price_estimate);
  ELSE
    v_base := COALESCE(r.urgency_base_price, r.customer_price);
  END IF;

  IF v_base IS NULL OR v_base <= 0 THEN
    RAISE EXCEPTION 'request_original_price_not_available';
  END IF;

  v_restored := GREATEST(v_base - COALESCE(r.coupon_discount, 0), 0);

  PERFORM pg_catalog.set_config('mamnoon.allow_request_urgency', 'true', true);

  UPDATE public.service_requests
  SET
    price_estimate = CASE
      WHEN type::text = 'taxi' AND vehicle_category::text <> 'large' THEN v_base
      ELSE price_estimate
    END,
    customer_price = CASE
      WHEN type::text = 'service' OR vehicle_category::text = 'large' THEN v_base::integer
      ELSE customer_price
    END,
    customer_payable = v_restored,
    urgency_base_price = NULL,
    urgency_multiplier = 1,
    urgency_percent = 0,
    urgency_amount = 0,
    taxi_urgency_enabled = false,
    taxi_urgency_percent = 0
  WHERE id = _request_id;

  PERFORM pg_catalog.set_config('mamnoon.allow_request_urgency', 'false', true);

  INSERT INTO public.notifications(user_id, type, title, body, link, data)
  SELECT
    o.provider_id,
    'urgent_request_cancelled',
    'تم إلغاء رفع أجرة الطلب',
    'أعاد الزبون الأجرة إلى السعر الأصلي: ' || pg_catalog.to_char(v_base, 'FM999,999,999') || ' د.ع.',
    '/request/' || r.id,
    pg_catalog.jsonb_build_object('request_id', r.id, 'price_iqd', v_base, 'urgency_cancelled', true)
  FROM public.request_offers o
  WHERE o.request_id = _request_id
    AND o.status = 'pending'
    AND o.expires_at > pg_catalog.now();

  RETURN pg_catalog.jsonb_build_object(
    'request_id', _request_id,
    'price', v_base,
    'customer_payable', v_restored,
    'urgency_multiplier', 1,
    'cancelled', true
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.cancel_request_urgency(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_request_urgency(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.cancel_request_urgency(uuid) TO authenticated;
