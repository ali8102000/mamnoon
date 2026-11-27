DROP POLICY IF EXISTS "Parties read live location" ON public.live_locations;
CREATE POLICY "Parties read live location" ON public.live_locations FOR SELECT TO authenticated
 USING (
  EXISTS(SELECT 1 FROM public.service_requests r
   WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
    AND (auth.uid()=r.customer_id OR public.is_service_request_provider(r.id,auth.uid()))
    AND (live_locations.user_id=r.customer_id OR public.is_service_request_provider(r.id,live_locations.user_id)))
  OR
  (public.has_live_ops_access(auth.uid()) AND EXISTS(SELECT 1 FROM public.service_requests r
   WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
    AND (live_locations.user_id=r.customer_id OR public.is_service_request_provider(r.id,live_locations.user_id))))
 );

DROP POLICY IF EXISTS "Trip parties read active route points" ON public.trip_location_points;
CREATE POLICY "Trip parties read active route points" ON public.trip_location_points FOR SELECT TO authenticated
 USING(EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=trip_location_points.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (auth.uid()=r.customer_id OR public.is_service_request_provider(r.id,auth.uid()))
   AND (trip_location_points.user_id=r.customer_id OR public.is_service_request_provider(r.id,trip_location_points.user_id))));

DROP POLICY IF EXISTS "Request parties read navigation" ON public.request_navigation;
CREATE POLICY "Request parties read navigation" ON public.request_navigation FOR SELECT TO authenticated
 USING(EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=request_navigation.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (auth.uid()=r.customer_id OR public.is_service_request_provider(r.id,auth.uid()))));

