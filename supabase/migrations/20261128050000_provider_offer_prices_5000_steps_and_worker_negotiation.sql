/* Production migration: provider offers are selected in fixed 5,000 IQD increments; service negotiation uses worker offers. */
CREATE OR REPLACE FUNCTION public.guard_request_offer_proposed_price()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog','public'
AS $$
DECLARE v_role text;
BEGIN
  SELECT ur.role::text INTO v_role FROM public.user_roles ur
  WHERE ur.user_id=NEW.provider_id AND ur.role::text IN ('large_driver','worker') LIMIT 1;
  IF NEW.proposed_price IS NOT NULL AND v_role IN ('large_driver','worker') THEN
    IF NEW.proposed_price < 5000 OR NEW.proposed_price > 500000 OR NEW.proposed_price % 5000 <> 0 THEN
      RAISE EXCEPTION 'سعر العرض يجب أن يكون من 5000 إلى 500000 دينار ومن مضاعفات 5000';
    END IF;
  ELSIF NEW.proposed_price IS NOT NULL AND
    (NEW.proposed_price < 250 OR NEW.proposed_price > 50000 OR NEW.proposed_price % 250 <> 0) THEN
    RAISE EXCEPTION 'سعر العرض غير صالح';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_large_vehicle_offer(_request_id uuid, _price integer, _message text DEFAULT NULL::text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE r public.service_requests%ROWTYPE; v_offer uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'large_driver') THEN RAISE EXCEPTION 'large_driver_role_required'; END IF;
  IF _price IS NULL OR _price < 5000 OR _price > 500000 OR _price % 5000 <> 0 THEN RAISE EXCEPTION 'invalid_offer_price'; END IF;
  IF EXISTS (SELECT 1 FROM public.user_blocks b WHERE b.user_id=auth.uid() AND (b.expires_at IS NULL OR b.expires_at>now())) THEN RAISE EXCEPTION 'user_blocked'; END IF;
  SELECT * INTO r FROM public.service_requests WHERE id=_request_id FOR UPDATE;
  IF NOT FOUND OR r.type::text<>'taxi' OR r.vehicle_category::text<>'large' OR r.status::text NOT IN ('pending','searching') OR r.provider_id IS NOT NULL THEN RAISE EXCEPTION 'request_unavailable'; END IF;
  IF r.customer_id=auth.uid() THEN RAISE EXCEPTION 'cannot_offer_on_own_request'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.naqil_profiles dp WHERE dp.user_id=auth.uid() AND dp.available=true AND dp.status='approved' AND dp.vehicle_category::text='large' AND (r.vehicle_type IS NULL OR dp.vehicle_type=r.vehicle_type) AND (dp.suspended_until IS NULL OR dp.suspended_until<=now())) THEN RAISE EXCEPTION 'driver_vehicle_not_eligible'; END IF;
  IF EXISTS (SELECT 1 FROM public.service_requests sr WHERE sr.provider_id=auth.uid() AND sr.provider_role='large_driver' AND sr.status IN ('accepted','in_progress')) THEN RAISE EXCEPTION 'provider_has_active_request'; END IF;
  UPDATE public.request_offers SET proposed_price=_price,offer_message=NULLIF(LEFT(TRIM(COALESCE(_message,'')),500),''),status='pending',sent_at=now(),expires_at=now()+interval '24 hours',responded_at=NULL
  WHERE request_id=_request_id AND provider_id=auth.uid() AND provider_role='large_driver' AND status IN ('pending','rejected','expired') RETURNING id INTO v_offer;
  IF v_offer IS NULL THEN RAISE EXCEPTION 'request_offer_expired'; END IF;
  INSERT INTO public.notifications(user_id,type,title,body,link,data)
  VALUES(r.customer_id,'large_vehicle_price_offer','عرض سعر لسيارتك الكبيرة','أرسل صاحب سيارة عرضاً بقيمة '||_price::text||' دينار.','/request/'||r.id::text,jsonb_build_object('request_id',r.id,'offer_id',v_offer,'price_iqd',_price));
  RETURN v_offer;
END;
$$;
REVOKE ALL ON FUNCTION public.submit_large_vehicle_offer(uuid,integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.submit_large_vehicle_offer(uuid,integer,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.submit_worker_service_offer(_request_id uuid,_price integer,_message text DEFAULT NULL::text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog','public'
AS $$
DECLARE r public.service_requests%ROWTYPE; wp public.worker_profiles%ROWTYPE; v_offer uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(),'worker') THEN RAISE EXCEPTION 'worker_role_required'; END IF;
  IF _price IS NULL OR _price<5000 OR _price>500000 OR _price%5000<>0 THEN RAISE EXCEPTION 'invalid_offer_price'; END IF;
  IF EXISTS(SELECT 1 FROM public.user_blocks b WHERE b.user_id=auth.uid() AND (b.expires_at IS NULL OR b.expires_at>now())) THEN RAISE EXCEPTION 'user_blocked'; END IF;
  SELECT * INTO r FROM public.service_requests WHERE id=_request_id FOR UPDATE;
  IF NOT FOUND OR r.type::text<>'service' OR r.pricing_mode<>'negotiable' OR r.status::text NOT IN ('pending','searching') OR r.provider_id IS NOT NULL THEN RAISE EXCEPTION 'service_offer_unavailable'; END IF;
  IF r.customer_id=auth.uid() THEN RAISE EXCEPTION 'cannot_offer_on_own_request'; END IF;
  SELECT * INTO wp FROM public.worker_profiles WHERE user_id=auth.uid() AND status='approved' AND available=true AND (suspended_until IS NULL OR suspended_until<=now()) AND (r.level_required IS NULL OR level=r.level_required) AND EXISTS(SELECT 1 FROM public.worker_services ws WHERE ws.worker_id=auth.uid() AND ws.service_id=r.service_id) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'worker_not_eligible'; END IF;
  IF coalesce(wp.team_size,1)<greatest(coalesce(r.workers_count,1),1) THEN RAISE EXCEPTION 'worker_team_capacity_insufficient'; END IF;
  IF EXISTS(SELECT 1 FROM public.service_requests sr WHERE sr.provider_id=auth.uid() AND sr.provider_role='worker' AND sr.status IN ('pending','searching','accepted','in_progress'))
    OR EXISTS(SELECT 1 FROM public.service_request_providers srp JOIN public.service_requests sr ON sr.id=srp.request_id WHERE srp.provider_id=auth.uid() AND sr.status IN ('pending','searching','accepted','in_progress')) THEN RAISE EXCEPTION 'provider_has_active_request'; END IF;
  UPDATE public.request_offers SET proposed_price=_price,offer_message=NULLIF(LEFT(TRIM(COALESCE(_message,'')),500),''),status='pending',sent_at=now(),expires_at=now()+interval '24 hours',responded_at=NULL
  WHERE request_id=_request_id AND provider_id=auth.uid() AND provider_role='worker' AND status IN ('pending','rejected','expired') RETURNING id INTO v_offer;
  IF v_offer IS NULL THEN RAISE EXCEPTION 'request_offer_expired'; END IF;
  INSERT INTO public.notifications(user_id,type,title,body,link,data)
  VALUES(r.customer_id,'worker_service_price_offer','عرض سعر لخدمتك','أرسل الفني عرضاً بقيمة '||_price::text||' دينار.','/request/'||r.id::text,jsonb_build_object('request_id',r.id,'offer_id',v_offer,'price_iqd',_price,'provider_role','worker'));
  RETURN v_offer;
END;
$$;
REVOKE ALL ON FUNCTION public.submit_worker_service_offer(uuid,integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.submit_worker_service_offer(uuid,integer,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.accept_worker_service_offer(_offer_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog','public'
AS $$
DECLARE o public.request_offers%ROWTYPE; r public.service_requests%ROWTYPE; wp public.worker_profiles%ROWTYPE; v_customer uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'unauthorized'; END IF;
  SELECT * INTO o FROM public.request_offers WHERE id=_offer_id FOR UPDATE;
  IF NOT FOUND OR o.proposed_price IS NULL OR o.provider_role<>'worker' OR o.status<>'pending' OR o.expires_at<=now() THEN RAISE EXCEPTION 'offer_unavailable'; END IF;
  SELECT * INTO r FROM public.service_requests WHERE id=o.request_id FOR UPDATE;
  IF NOT FOUND OR r.customer_id<>auth.uid() OR r.type::text<>'service' OR r.pricing_mode<>'negotiable' OR r.status::text NOT IN ('pending','searching') OR r.provider_id IS NOT NULL THEN RAISE EXCEPTION 'request_unavailable'; END IF;
  PERFORM pg_advisory_xact_lock(91840060);
  SELECT * INTO wp FROM public.worker_profiles WHERE user_id=o.provider_id AND status='approved' AND available=true AND (suspended_until IS NULL OR suspended_until<=now()) AND (r.level_required IS NULL OR level=r.level_required) AND EXISTS(SELECT 1 FROM public.worker_services ws WHERE ws.worker_id=o.provider_id AND ws.service_id=r.service_id) FOR UPDATE;
  IF NOT FOUND OR NOT public.has_role(o.provider_id,'worker') THEN RAISE EXCEPTION 'worker_not_eligible'; END IF;
  IF coalesce(wp.team_size,1)<greatest(coalesce(r.workers_count,1),1) THEN RAISE EXCEPTION 'worker_team_capacity_insufficient'; END IF;
  IF EXISTS(SELECT 1 FROM public.user_blocks b WHERE b.user_id=o.provider_id AND (b.expires_at IS NULL OR b.expires_at>now()))
    OR EXISTS(SELECT 1 FROM public.service_requests sr WHERE sr.provider_id=o.provider_id AND sr.provider_role='worker' AND sr.status IN ('pending','searching','accepted','in_progress'))
    OR EXISTS(SELECT 1 FROM public.service_request_providers srp JOIN public.service_requests sr ON sr.id=srp.request_id WHERE srp.provider_id=o.provider_id AND sr.status IN ('pending','searching','accepted','in_progress')) THEN RAISE EXCEPTION 'worker_no_longer_eligible'; END IF;
  PERFORM set_config('mamnoon.allow_provider_request_transition','true',true);
  UPDATE public.service_requests sr SET provider_id=o.provider_id,provider_role='worker',status='accepted',accepted_at=now(),customer_price=o.proposed_price,customer_payable=o.proposed_price,price_estimate=o.proposed_price,pricing_mode='fixed',updated_at=now()
  WHERE sr.id=r.id AND sr.provider_id IS NULL AND sr.status::text IN ('pending','searching') RETURNING sr.customer_id INTO v_customer;
  PERFORM set_config('mamnoon.allow_provider_request_transition','false',true);
  IF v_customer IS NULL THEN RAISE EXCEPTION 'request_unavailable'; END IF;
  INSERT INTO public.service_request_providers(request_id,provider_id,team_size,accepted_at)
  VALUES(r.id,o.provider_id,greatest(coalesce(r.workers_count,1),1),now())
  ON CONFLICT(request_id,provider_id) DO UPDATE SET team_size=EXCLUDED.team_size,accepted_at=EXCLUDED.accepted_at;
  INSERT INTO public.chats(request_id,customer_id,provider_id) VALUES(r.id,v_customer,o.provider_id)
  ON CONFLICT(request_id) DO UPDATE SET provider_id=EXCLUDED.provider_id,updated_at=now();
  UPDATE public.request_offers SET status=CASE WHEN id=_offer_id THEN 'accepted' ELSE 'cancelled' END,responded_at=now() WHERE request_id=r.id AND status='pending';
  INSERT INTO public.notifications(user_id,type,title,body,link,data)
  VALUES(o.provider_id,'worker_service_offer_accepted','تم قبول عرضك','وافق الزبون على عرضك. افتح الطلب للتواصل والبدء.','/request/'||r.id::text,jsonb_build_object('request_id',r.id,'offer_id',_offer_id,'price_iqd',o.proposed_price));
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.accept_worker_service_offer(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.accept_worker_service_offer(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.reject_worker_service_offer(_offer_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog','public'
AS $$
DECLARE o public.request_offers%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'unauthorized'; END IF;
  SELECT * INTO o FROM public.request_offers WHERE id=_offer_id FOR UPDATE;
  IF NOT FOUND OR o.proposed_price IS NULL OR o.provider_role<>'worker' OR o.status<>'pending' THEN RAISE EXCEPTION 'offer_unavailable'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.service_requests r WHERE r.id=o.request_id AND r.customer_id=auth.uid() AND r.type::text='service' AND r.status::text IN ('pending','searching')) THEN RAISE EXCEPTION 'request_unavailable'; END IF;
  UPDATE public.request_offers SET status='rejected',responded_at=now() WHERE id=_offer_id AND status='pending';
  RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION public.reject_worker_service_offer(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.reject_worker_service_offer(uuid) TO authenticated;
