DROP POLICY IF EXISTS "Assigned provider publishes trip broadcasts" ON realtime.messages;
CREATE POLICY "Assigned provider publishes trip broadcasts"
ON realtime.messages FOR INSERT TO authenticated
WITH CHECK (
 realtime.topic() ~ '^trip_tracking:[0-9a-fA-F-]{36}$'
 AND EXISTS (
  SELECT 1 FROM public.service_requests r
  WHERE r.id::text=split_part(realtime.topic(),':',2)
   AND r.provider_id=auth.uid()
   AND r.provider_role IS NOT NULL
   AND public.has_role(auth.uid(),r.provider_role::public.app_role)
   AND r.status IN ('accepted'::public.request_status,'in_progress'::public.request_status)
 )
);

