DROP POLICY IF EXISTS "Provider sees own offers" ON public.request_offers;
CREATE POLICY "Provider sees own offers" ON public.request_offers FOR SELECT TO authenticated
 USING ((provider_id=(SELECT auth.uid()) AND provider_role IS NOT NULL AND public.has_role((SELECT auth.uid()),provider_role::public.app_role))
  OR public.has_provider_ops_access((SELECT auth.uid())));

DROP POLICY IF EXISTS "Driver sees offered taxi request" ON public.service_requests;
CREATE POLICY "Driver sees offered taxi request" ON public.service_requests FOR SELECT TO authenticated
 USING (type='taxi'::public.request_type AND status IN ('pending'::public.request_status,'searching'::public.request_status)
  AND EXISTS (SELECT 1 FROM public.request_offers o WHERE o.request_id=service_requests.id AND o.provider_id=(SELECT auth.uid())
   AND o.provider_role=CASE WHEN service_requests.vehicle_category='large'::public.vehicle_category THEN 'large_driver' ELSE 'driver' END
   AND public.has_role((SELECT auth.uid()),o.provider_role::public.app_role)));

DROP POLICY IF EXISTS "Workers see offered service requests" ON public.service_requests;
CREATE POLICY "Workers see offered service requests" ON public.service_requests FOR SELECT TO authenticated
 USING (type='service'::public.request_type AND status IN ('pending'::public.request_status,'searching'::public.request_status)
  AND public.has_role((SELECT auth.uid()),'worker'::public.app_role) AND service_id IS NOT NULL
  AND EXISTS (SELECT 1 FROM public.worker_profiles wp JOIN public.worker_services ws ON ws.worker_id=wp.user_id
   WHERE wp.user_id=(SELECT auth.uid()) AND ws.service_id=service_requests.service_id AND wp.status='approved' AND wp.available=true
    AND (wp.suspended_until IS NULL OR wp.suspended_until<=now()) AND (service_requests.level_required IS NULL OR wp.level=service_requests.level_required))
  AND EXISTS (SELECT 1 FROM public.request_offers o WHERE o.request_id=service_requests.id AND o.provider_id=(SELECT auth.uid()) AND o.provider_role='worker'));

DROP POLICY IF EXISTS "Provider updates assigned request" ON public.service_requests;
CREATE POLICY "Provider updates assigned request" ON public.service_requests FOR UPDATE TO authenticated
 USING (provider_id=(SELECT auth.uid()) AND provider_role IS NOT NULL AND public.has_role((SELECT auth.uid()),provider_role::public.app_role))
 WITH CHECK (provider_id=(SELECT auth.uid()) AND provider_role IS NOT NULL AND public.has_role((SELECT auth.uid()),provider_role::public.app_role));

DROP POLICY IF EXISTS "Owner writes own live location" ON public.live_locations;
CREATE POLICY "Owner writes own live location" ON public.live_locations FOR INSERT TO authenticated
 WITH CHECK (
  user_id=(SELECT auth.uid())
  AND EXISTS (SELECT 1 FROM public.service_requests r
   WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
    AND (
     (r.customer_id=(SELECT auth.uid()) AND live_locations.role='customer' AND live_locations.provider_role IS NULL)
     OR
     (r.provider_id=(SELECT auth.uid()) AND live_locations.role='provider' AND live_locations.provider_role=r.provider_role
      AND public.has_role((SELECT auth.uid()),r.provider_role::public.app_role))
    )
  )
 );

DROP POLICY IF EXISTS "Owner updates own live location" ON public.live_locations;
CREATE POLICY "Owner updates own live location" ON public.live_locations FOR UPDATE TO authenticated
 USING (
  user_id=(SELECT auth.uid())
  AND EXISTS (SELECT 1 FROM public.service_requests r
   WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
    AND (r.customer_id=(SELECT auth.uid()) OR r.provider_id=(SELECT auth.uid()))
  )
 )
 WITH CHECK (
  user_id=(SELECT auth.uid())
  AND EXISTS (SELECT 1 FROM public.service_requests r
   WHERE r.id=live_locations.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
    AND (
     (r.customer_id=(SELECT auth.uid()) AND live_locations.role='customer' AND live_locations.provider_role IS NULL)
     OR
     (r.provider_id=(SELECT auth.uid()) AND live_locations.role='provider' AND live_locations.provider_role=r.provider_role
      AND public.has_role((SELECT auth.uid()),r.provider_role::public.app_role))
    )
  )
 );

DROP POLICY IF EXISTS "Provider records own active route points" ON public.trip_location_points;
CREATE POLICY "Provider records own active route points" ON public.trip_location_points FOR INSERT TO authenticated
 WITH CHECK (
  user_id=(SELECT auth.uid())
  AND EXISTS (SELECT 1 FROM public.service_requests r
   WHERE r.id=trip_location_points.request_id AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
    AND (
     (r.customer_id=(SELECT auth.uid()) AND trip_location_points.role='customer' AND trip_location_points.provider_role IS NULL)
     OR
     (r.provider_id=(SELECT auth.uid()) AND trip_location_points.role='provider' AND trip_location_points.provider_role=r.provider_role
      AND public.has_role((SELECT auth.uid()),r.provider_role::public.app_role))
    )
  )
 );

DROP POLICY IF EXISTS "Assigned provider inserts navigation" ON public.request_navigation;
CREATE POLICY "Assigned provider inserts navigation" ON public.request_navigation FOR INSERT TO authenticated
 WITH CHECK (updated_by=auth.uid() AND EXISTS (SELECT 1 FROM public.service_requests r WHERE r.id=request_navigation.request_id
  AND r.provider_id=auth.uid() AND r.provider_role IS NOT NULL AND public.has_role(auth.uid(),r.provider_role::public.app_role)
  AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)));

DROP POLICY IF EXISTS "Assigned provider updates navigation" ON public.request_navigation;
CREATE POLICY "Assigned provider updates navigation" ON public.request_navigation FOR UPDATE TO authenticated
 USING (EXISTS (SELECT 1 FROM public.service_requests r WHERE r.id=request_navigation.request_id
  AND r.provider_id=auth.uid() AND r.provider_role IS NOT NULL AND public.has_role(auth.uid(),r.provider_role::public.app_role)
  AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)))
 WITH CHECK (updated_by=auth.uid() AND EXISTS (SELECT 1 FROM public.service_requests r WHERE r.id=request_navigation.request_id
  AND r.provider_id=auth.uid() AND r.provider_role IS NOT NULL AND public.has_role(auth.uid(),r.provider_role::public.app_role)
  AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)));

