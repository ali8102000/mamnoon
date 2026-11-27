CREATE OR REPLACE FUNCTION public.is_request_provider_member(_request_id uuid,_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS(SELECT 1 FROM public.service_requests r WHERE r.id=_request_id AND r.provider_id=_user_id)
  OR EXISTS(SELECT 1 FROM public.service_request_providers srp WHERE srp.request_id=_request_id AND srp.provider_id=_user_id);
$$;
REVOKE ALL ON FUNCTION public.is_request_provider_member(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.is_request_provider_member(uuid,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.is_assigned_provider_for_request(_request_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT auth.uid() IS NOT NULL AND public.is_request_provider_member(_request_id,auth.uid());
$$;
REVOKE ALL ON FUNCTION public.is_assigned_provider_for_request(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.is_assigned_provider_for_request(uuid) TO authenticated;

DROP POLICY IF EXISTS "Owner updates own live location" ON public.live_locations;
CREATE POLICY "Owner updates own live location" ON public.live_locations FOR UPDATE TO authenticated
 USING(user_id=auth.uid() AND EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (r.customer_id=auth.uid() OR public.is_assigned_provider_for_request(r.id))))
 WITH CHECK(user_id=auth.uid() AND EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (
    (r.customer_id=auth.uid() AND live_locations.role='customer' AND live_locations.provider_role IS NULL)
    OR (r.provider_id=auth.uid() AND live_locations.role='provider' AND live_locations.provider_role=r.provider_role
      AND r.provider_role IS NOT NULL AND public.has_role(auth.uid(),r.provider_role::public.app_role))
    OR (r.type='service'::public.request_type AND live_locations.role='provider' AND live_locations.provider_role='worker'
      AND public.has_role(auth.uid(),'worker'::public.app_role) AND public.is_service_request_provider(r.id,auth.uid()))
   )));

DROP POLICY IF EXISTS "Parties read live location" ON public.live_locations;
CREATE POLICY "Parties read live location" ON public.live_locations FOR SELECT TO authenticated
 USING (
  EXISTS(SELECT 1 FROM public.service_requests r
   WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
    AND (auth.uid()=r.customer_id OR public.is_assigned_provider_for_request(r.id))
    AND (live_locations.user_id=r.customer_id OR public.is_request_provider_member(r.id,live_locations.user_id)))
  OR
  (public.has_live_ops_access(auth.uid()) AND EXISTS(SELECT 1 FROM public.service_requests r
   WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
    AND (live_locations.user_id=r.customer_id OR public.is_request_provider_member(r.id,live_locations.user_id))))
 );

DROP POLICY IF EXISTS "Trip parties read active route points" ON public.trip_location_points;
CREATE POLICY "Trip parties read active route points" ON public.trip_location_points FOR SELECT TO authenticated
 USING(EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=trip_location_points.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (auth.uid()=r.customer_id OR public.is_assigned_provider_for_request(r.id))
   AND (trip_location_points.user_id=r.customer_id OR public.is_request_provider_member(r.id,trip_location_points.user_id))));

DROP POLICY IF EXISTS "Request parties read navigation" ON public.request_navigation;
CREATE POLICY "Request parties read navigation" ON public.request_navigation FOR SELECT TO authenticated
 USING(EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=request_navigation.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (auth.uid()=r.customer_id OR public.is_assigned_provider_for_request(r.id))));

