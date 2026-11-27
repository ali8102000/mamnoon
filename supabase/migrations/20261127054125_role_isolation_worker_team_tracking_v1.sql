CREATE OR REPLACE FUNCTION public.sync_worker_team_presence_for_request(_request_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
BEGIN
 UPDATE public.provider_presence_roles p
 SET status=CASE
  WHEN EXISTS(SELECT 1 FROM public.service_requests r WHERE r.id=_request_id AND r.status IN ('accepted','in_progress')) THEN 'in_trip'
  WHEN wp.available AND wp.status='approved' AND (wp.suspended_until IS NULL OR wp.suspended_until<=now()) THEN 'online'
  ELSE 'offline' END
 FROM public.service_request_providers srp
 JOIN public.worker_profiles wp ON wp.user_id=srp.provider_id
 WHERE srp.request_id=_request_id AND p.user_id=srp.provider_id AND p.role='worker';
END $$;
REVOKE ALL ON FUNCTION public.sync_worker_team_presence_for_request(uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.trg_sync_worker_team_presence()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE v_request_id uuid;
BEGIN
 IF TG_TABLE_NAME='service_requests' THEN
  v_request_id:=NEW.id;
 ELSIF TG_OP='DELETE' THEN
  v_request_id:=OLD.request_id;
 ELSE
  v_request_id:=NEW.request_id;
 END IF;
 PERFORM public.sync_worker_team_presence_for_request(v_request_id);
 IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;
REVOKE ALL ON FUNCTION public.trg_sync_worker_team_presence() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS trg_sync_worker_team_presence_request ON public.service_requests;
CREATE TRIGGER trg_sync_worker_team_presence_request
 AFTER INSERT OR UPDATE OF status ON public.service_requests
 FOR EACH ROW EXECUTE FUNCTION public.trg_sync_worker_team_presence();
DROP TRIGGER IF EXISTS trg_sync_worker_team_presence_membership ON public.service_request_providers;
CREATE TRIGGER trg_sync_worker_team_presence_membership
 AFTER INSERT OR UPDATE OR DELETE ON public.service_request_providers
 FOR EACH ROW EXECUTE FUNCTION public.trg_sync_worker_team_presence();

-- Team members are workers for this request only; their own worker presence remains independent of any other role.
DROP POLICY IF EXISTS "Owner writes own live location" ON public.live_locations;
CREATE POLICY "Owner writes own live location" ON public.live_locations FOR INSERT TO authenticated
 WITH CHECK (
  user_id=auth.uid()
  AND EXISTS(SELECT 1 FROM public.service_requests r
   WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
    AND (
     (r.customer_id=auth.uid() AND live_locations.role='customer' AND live_locations.provider_role IS NULL)
     OR
     (live_locations.role='provider' AND live_locations.provider_role=COALESCE(r.provider_role,CASE WHEN r.type='service'::public.request_type THEN 'worker' END)
      AND public.has_role(auth.uid(),'worker'::public.app_role)
      AND public.is_service_request_provider(r.id,auth.uid()))
    )
  )
 );

DROP POLICY IF EXISTS "Owner updates own live location" ON public.live_locations;
CREATE POLICY "Owner updates own live location" ON public.live_locations FOR UPDATE TO authenticated
 USING(user_id=auth.uid() AND EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (r.customer_id=auth.uid() OR public.is_service_request_provider(r.id,auth.uid()))))
 WITH CHECK (
  user_id=auth.uid()
  AND EXISTS(SELECT 1 FROM public.service_requests r
   WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
    AND (
     (r.customer_id=auth.uid() AND live_locations.role='customer' AND live_locations.provider_role IS NULL)
     OR
     (live_locations.role='provider' AND live_locations.provider_role=COALESCE(r.provider_role,CASE WHEN r.type='service'::public.request_type THEN 'worker' END)
      AND public.has_role(auth.uid(),'worker'::public.app_role)
      AND public.is_service_request_provider(r.id,auth.uid()))
    )
  )
 );

DROP POLICY IF EXISTS "Owner deletes own live location" ON public.live_locations;
CREATE POLICY "Owner deletes own live location" ON public.live_locations FOR DELETE TO authenticated
 USING(user_id=auth.uid() AND EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=live_locations.request_id AND (
   (r.customer_id=auth.uid() AND live_locations.role='customer' AND live_locations.provider_role IS NULL)
   OR (live_locations.role='provider'
    AND live_locations.provider_role=COALESCE(r.provider_role,CASE WHEN r.type='service'::public.request_type THEN 'worker' END)
    AND public.has_role(auth.uid(),'worker'::public.app_role)
    AND public.is_service_request_provider(r.id,auth.uid()))
  )));

DROP POLICY IF EXISTS "Provider records own active route points" ON public.trip_location_points;
CREATE POLICY "Provider records own active route points" ON public.trip_location_points FOR INSERT TO authenticated
 WITH CHECK(user_id=auth.uid() AND EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=trip_location_points.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (
    (r.customer_id=auth.uid() AND trip_location_points.role='customer' AND trip_location_points.provider_role IS NULL)
    OR (trip_location_points.role='provider'
     AND trip_location_points.provider_role=COALESCE(r.provider_role,CASE WHEN r.type='service'::public.request_type THEN 'worker' END)
     AND public.has_role(auth.uid(),'worker'::public.app_role)
     AND public.is_service_request_provider(r.id,auth.uid()))
   )));

DROP POLICY IF EXISTS "Assigned provider inserts navigation" ON public.request_navigation;
CREATE POLICY "Assigned provider inserts navigation" ON public.request_navigation FOR INSERT TO authenticated
 WITH CHECK(updated_by=auth.uid() AND EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=request_navigation.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND r.type='service'::public.request_type AND public.has_role(auth.uid(),'worker'::public.app_role)
   AND public.is_service_request_provider(r.id,auth.uid())));

DROP POLICY IF EXISTS "Assigned provider updates navigation" ON public.request_navigation;
CREATE POLICY "Assigned provider updates navigation" ON public.request_navigation FOR UPDATE TO authenticated
 USING(EXISTS(SELECT 1 FROM public.service_requests r WHERE r.id=request_navigation.request_id
  AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
  AND ((r.provider_id=auth.uid() AND r.provider_role IS NOT NULL AND public.has_role(auth.uid(),r.provider_role::public.app_role))
   OR (r.type='service'::public.request_type AND public.has_role(auth.uid(),'worker'::public.app_role) AND public.is_service_request_provider(r.id,auth.uid())))))
 WITH CHECK(updated_by=auth.uid() AND EXISTS(SELECT 1 FROM public.service_requests r WHERE r.id=request_navigation.request_id
  AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
  AND ((r.provider_id=auth.uid() AND r.provider_role IS NOT NULL AND public.has_role(auth.uid(),r.provider_role::public.app_role))
   OR (r.type='service'::public.request_type AND public.has_role(auth.uid(),'worker'::public.app_role) AND public.is_service_request_provider(r.id,auth.uid())))));

DROP POLICY IF EXISTS "Provider updates assigned request" ON public.service_requests;
CREATE POLICY "Provider updates assigned request" ON public.service_requests FOR UPDATE TO authenticated
 USING((provider_id=auth.uid() AND provider_role IS NOT NULL AND public.has_role(auth.uid(),provider_role::public.app_role))
  OR (type='service'::public.request_type AND public.has_role(auth.uid(),'worker'::public.app_role) AND public.is_service_request_provider(id,auth.uid())))
 WITH CHECK((provider_id=auth.uid() AND provider_role IS NOT NULL AND public.has_role(auth.uid(),provider_role::public.app_role))
  OR (type='service'::public.request_type AND public.has_role(auth.uid(),'worker'::public.app_role) AND public.is_service_request_provider(id,auth.uid())));

DROP POLICY IF EXISTS "Trip parties receive private tracking broadcasts" ON realtime.messages;
CREATE POLICY "Trip parties receive private tracking broadcasts" ON realtime.messages FOR SELECT TO authenticated
 USING(realtime.topic() ~ '^trip_tracking:[0-9a-fA-F-]{36}$' AND EXISTS(
  SELECT 1 FROM public.service_requests r WHERE r.id::text=split_part(realtime.topic(),':',2)
   AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (auth.uid()=r.customer_id OR auth.uid()=r.provider_id
    OR (r.type='service'::public.request_type AND public.has_role(auth.uid(),'worker'::public.app_role)
      AND public.is_service_request_provider(r.id,auth.uid()))
  )));
DROP POLICY IF EXISTS "Assigned provider publishes trip broadcasts" ON realtime.messages;
CREATE POLICY "Assigned provider publishes trip broadcasts" ON realtime.messages FOR INSERT TO authenticated
 WITH CHECK(realtime.topic() ~ '^trip_tracking:[0-9a-fA-F-]{36}$' AND EXISTS(
  SELECT 1 FROM public.service_requests r WHERE r.id::text=split_part(realtime.topic(),':',2)
   AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND ((r.provider_id=auth.uid() AND r.provider_role IS NOT NULL AND public.has_role(auth.uid(),r.provider_role::public.app_role))
    OR (r.type='service'::public.request_type AND public.has_role(auth.uid(),'worker'::public.app_role)
      AND public.is_service_request_provider(r.id,auth.uid()))
  )));

