DROP POLICY IF EXISTS "Owner writes own live location" ON public.live_locations;
CREATE POLICY "Owner writes own live location" ON public.live_locations FOR INSERT TO authenticated
 WITH CHECK(user_id=auth.uid() AND EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (
    (r.customer_id=auth.uid() AND live_locations.role='customer' AND live_locations.provider_role IS NULL)
    OR
    (r.provider_id=auth.uid() AND live_locations.role='provider' AND live_locations.provider_role=r.provider_role
      AND r.provider_role IS NOT NULL AND public.has_role(auth.uid(),r.provider_role::public.app_role))
    OR
    (r.type='service'::public.request_type AND live_locations.role='provider' AND live_locations.provider_role='worker'
      AND public.has_role(auth.uid(),'worker'::public.app_role) AND public.is_service_request_provider(r.id,auth.uid()))
   )));

DROP POLICY IF EXISTS "Owner updates own live location" ON public.live_locations;
CREATE POLICY "Owner updates own live location" ON public.live_locations FOR UPDATE TO authenticated
 USING(user_id=auth.uid() AND EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (r.customer_id=auth.uid() OR public.is_service_request_provider(r.id,auth.uid()))))
 WITH CHECK(user_id=auth.uid() AND EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (
    (r.customer_id=auth.uid() AND live_locations.role='customer' AND live_locations.provider_role IS NULL)
    OR
    (r.provider_id=auth.uid() AND live_locations.role='provider' AND live_locations.provider_role=r.provider_role
      AND r.provider_role IS NOT NULL AND public.has_role(auth.uid(),r.provider_role::public.app_role))
    OR
    (r.type='service'::public.request_type AND live_locations.role='provider' AND live_locations.provider_role='worker'
      AND public.has_role(auth.uid(),'worker'::public.app_role) AND public.is_service_request_provider(r.id,auth.uid()))
   )));

DROP POLICY IF EXISTS "Owner deletes own live location" ON public.live_locations;
CREATE POLICY "Owner deletes own live location" ON public.live_locations FOR DELETE TO authenticated
 USING(user_id=auth.uid() AND EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=live_locations.request_id AND (
   (r.customer_id=auth.uid() AND live_locations.role='customer' AND live_locations.provider_role IS NULL)
   OR
   (r.provider_id=auth.uid() AND live_locations.role='provider' AND live_locations.provider_role=r.provider_role
    AND r.provider_role IS NOT NULL AND public.has_role(auth.uid(),r.provider_role::public.app_role))
   OR
   (r.type='service'::public.request_type AND live_locations.role='provider' AND live_locations.provider_role='worker'
    AND public.has_role(auth.uid(),'worker'::public.app_role) AND public.is_service_request_provider(r.id,auth.uid()))
  )));

DROP POLICY IF EXISTS "Provider records own active route points" ON public.trip_location_points;
CREATE POLICY "Provider records own active route points" ON public.trip_location_points FOR INSERT TO authenticated
 WITH CHECK(user_id=auth.uid() AND EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=trip_location_points.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (
    (r.customer_id=auth.uid() AND trip_location_points.role='customer' AND trip_location_points.provider_role IS NULL)
    OR
    (r.provider_id=auth.uid() AND trip_location_points.role='provider' AND trip_location_points.provider_role=r.provider_role
      AND r.provider_role IS NOT NULL AND public.has_role(auth.uid(),r.provider_role::public.app_role))
    OR
    (r.type='service'::public.request_type AND trip_location_points.role='provider' AND trip_location_points.provider_role='worker'
      AND public.has_role(auth.uid(),'worker'::public.app_role) AND public.is_service_request_provider(r.id,auth.uid()))
   )));

DROP POLICY IF EXISTS "Assigned provider inserts navigation" ON public.request_navigation;
CREATE POLICY "Assigned provider inserts navigation" ON public.request_navigation FOR INSERT TO authenticated
 WITH CHECK(updated_by=auth.uid() AND EXISTS(SELECT 1 FROM public.service_requests r
  WHERE r.id=request_navigation.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
   AND (
    (r.provider_id=auth.uid() AND r.provider_role IS NOT NULL AND public.has_role(auth.uid(),r.provider_role::public.app_role))
    OR (r.type='service'::public.request_type AND public.has_role(auth.uid(),'worker'::public.app_role)
      AND public.is_service_request_provider(r.id,auth.uid()))
   )));

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

