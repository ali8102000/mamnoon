CREATE OR REPLACE FUNCTION public.is_request_provider_member(_request_id uuid,_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS(
  SELECT 1 FROM public.service_requests r
  WHERE r.id=_request_id
   AND (
    auth.uid()=r.customer_id OR auth.uid()=r.provider_id
    OR EXISTS(SELECT 1 FROM public.service_request_providers caller WHERE caller.request_id=r.id AND caller.provider_id=auth.uid())
    OR public.has_live_ops_access(auth.uid())
   )
   AND (
    r.provider_id=_user_id
    OR EXISTS(SELECT 1 FROM public.service_request_providers srp WHERE srp.request_id=r.id AND srp.provider_id=_user_id)
   )
 );
$$;

