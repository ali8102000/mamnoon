CREATE OR REPLACE FUNCTION public.guard_worker_team_assignment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 IF EXISTS(
  SELECT 1 FROM public.service_requests r
  WHERE r.provider_id=NEW.provider_id AND r.provider_role='worker'
   AND r.id<>NEW.request_id AND r.status IN ('pending','searching','accepted','in_progress')
 ) OR EXISTS(
  SELECT 1 FROM public.service_request_providers srp
  JOIN public.service_requests r ON r.id=srp.request_id
  WHERE srp.provider_id=NEW.provider_id AND srp.request_id<>NEW.request_id
   AND r.status IN ('pending','searching','accepted','in_progress')
 ) THEN
  RAISE EXCEPTION 'worker_has_active_request';
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_worker_team_assignment() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS trg_guard_worker_team_assignment ON public.service_request_providers;
CREATE TRIGGER trg_guard_worker_team_assignment
 BEFORE INSERT OR UPDATE OF provider_id,request_id ON public.service_request_providers
 FOR EACH ROW EXECUTE FUNCTION public.guard_worker_team_assignment();

CREATE OR REPLACE FUNCTION public.accept_service_request(_request_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE r public.service_requests%ROWTYPE; v_customer uuid; v_role text; v_eligible boolean:=false;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'unauthorized'; END IF;
 SELECT * INTO r FROM public.service_requests WHERE id=_request_id FOR UPDATE;
 IF NOT FOUND OR r.status NOT IN ('pending','searching') OR r.provider_id IS NOT NULL THEN RAISE EXCEPTION 'request_unavailable'; END IF;
 v_role:=CASE WHEN r.type::text='service' THEN 'worker'
   WHEN r.type::text='taxi' AND r.vehicle_category='large'::public.vehicle_category THEN 'large_driver'
   WHEN r.type::text='taxi' THEN 'driver' ELSE NULL END;
 IF v_role IS NULL OR NOT public.has_role(auth.uid(),v_role::public.app_role) THEN RAISE EXCEPTION 'provider_role_required'; END IF;
 IF EXISTS(SELECT 1 FROM public.user_blocks b WHERE b.user_id=auth.uid() AND (b.expires_at IS NULL OR b.expires_at>now())) THEN RAISE EXCEPTION 'user_blocked'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':'||v_role,0));
 IF EXISTS(SELECT 1 FROM public.service_requests a WHERE a.provider_id=auth.uid() AND a.provider_role=v_role AND a.status IN ('accepted','in_progress'))
  OR (v_role='worker' AND EXISTS(SELECT 1 FROM public.service_request_providers srp JOIN public.service_requests ar ON ar.id=srp.request_id
    WHERE srp.provider_id=auth.uid() AND ar.status IN ('pending','searching','accepted','in_progress'))) THEN
  RAISE EXCEPTION 'لديك طلب نشط بالفعل لهذا الدور';
 END IF;
 PERFORM 1 FROM public.request_offers o WHERE o.request_id=_request_id AND o.provider_id=auth.uid()
  AND o.provider_role=v_role AND o.status='pending' AND o.expires_at>now() FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'request_offer_expired'; END IF;

 IF v_role='driver' THEN
  SELECT EXISTS(SELECT 1 FROM public.driver_profiles p WHERE p.user_id=auth.uid() AND p.status='approved' AND p.available=true
   AND (p.suspended_until IS NULL OR p.suspended_until<=now())
   AND p.vehicle_category IN ('economy','premium','luxury')
   AND CASE p.vehicle_category::text WHEN 'economy' THEN 1 WHEN 'premium' THEN 2 WHEN 'luxury' THEN 3 ELSE 0 END
       >= CASE r.vehicle_category::text WHEN 'economy' THEN 1 WHEN 'premium' THEN 2 WHEN 'luxury' THEN 3 ELSE 99 END) INTO v_eligible;
 ELSIF v_role='large_driver' THEN
  SELECT EXISTS(SELECT 1 FROM public.naqil_profiles p WHERE p.user_id=auth.uid() AND p.vehicle_category='large'::public.vehicle_category
   AND p.status='approved' AND p.available=true AND (p.suspended_until IS NULL OR p.suspended_until<=now())
   AND (r.vehicle_type IS NULL OR p.vehicle_type=r.vehicle_type)) INTO v_eligible;
 ELSE
  SELECT EXISTS(SELECT 1 FROM public.worker_profiles p WHERE p.user_id=auth.uid() AND p.status='approved' AND p.available=true
   AND (p.suspended_until IS NULL OR p.suspended_until<=now())
   AND (r.level_required IS NULL OR p.level=r.level_required)
   AND EXISTS(SELECT 1 FROM public.worker_services ws WHERE ws.worker_id=p.user_id AND ws.service_id=r.service_id)) INTO v_eligible;
 END IF;
 IF NOT v_eligible THEN RAISE EXCEPTION 'provider_profile_not_eligible'; END IF;
 PERFORM set_config('mamnoon.allow_provider_request_transition','true',true);
 UPDATE public.service_requests sr SET provider_id=auth.uid(),provider_role=v_role,status='accepted',accepted_at=now(),updated_at=now()
 WHERE sr.id=_request_id AND sr.status IN ('pending','searching') AND sr.provider_id IS NULL
 RETURNING sr.customer_id INTO v_customer;
 PERFORM set_config('mamnoon.allow_provider_request_transition','false',true);
 IF v_customer IS NULL THEN RAISE EXCEPTION 'request_unavailable'; END IF;
 INSERT INTO public.chats(request_id,customer_id,provider_id) VALUES(_request_id,v_customer,auth.uid())
 ON CONFLICT(request_id) DO UPDATE SET provider_id=EXCLUDED.provider_id,updated_at=now();
 UPDATE public.request_offers SET status=CASE WHEN provider_id=auth.uid() THEN 'accepted' ELSE 'cancelled' END,responded_at=now()
 WHERE request_id=_request_id AND status='pending';
 INSERT INTO public.notifications(user_id,type,title,body,link,data)
 VALUES(v_customer,'request_accepted','تم قبول طلبك','مقدّم الخدمة قبل طلبك ويمكنك متابعة التفاصيل الآن.',
  '/request/'||_request_id,jsonb_build_object('request_id',_request_id,'provider_id',auth.uid(),'provider_role',v_role));
 RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.accept_service_request(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.accept_service_request(uuid) TO authenticated;

