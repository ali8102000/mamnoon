DROP POLICY IF EXISTS "Owner deletes own live location" ON public.live_locations;
CREATE POLICY "Owner deletes own live location" ON public.live_locations
FOR DELETE TO authenticated
USING (
 user_id=auth.uid()
 AND EXISTS (
  SELECT 1 FROM public.service_requests r
  WHERE r.id=live_locations.request_id
   AND (
    (r.customer_id=auth.uid() AND live_locations.role='customer' AND live_locations.provider_role IS NULL)
    OR
    (r.provider_id=auth.uid() AND live_locations.role='provider'
      AND live_locations.provider_role=r.provider_role
      AND r.provider_role IS NOT NULL
      AND public.has_role(auth.uid(),r.provider_role::public.app_role))
   )
 )
);

