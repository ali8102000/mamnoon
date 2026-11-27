-- Keep provider-side request visibility bound to the assigned role.
-- Customers retain access to their own requests; team workers retain access
-- only when they are members of that service request under the worker role.
DROP POLICY IF EXISTS "Parties see own requests" ON public.service_requests;

CREATE POLICY "Parties see own requests"
ON public.service_requests
FOR SELECT
TO authenticated
USING (
  customer_id = (SELECT auth.uid())
  OR (
    provider_id = (SELECT auth.uid())
    AND provider_role IS NOT NULL
    AND has_role((SELECT auth.uid()), provider_role::public.app_role)
  )
  OR (
    type = 'service'::public.request_type
    AND provider_role = 'worker'
    AND has_role((SELECT auth.uid()), 'worker'::public.app_role)
    AND is_service_request_provider(id, (SELECT auth.uid()))
  )
);
