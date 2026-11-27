CREATE OR REPLACE FUNCTION public.on_request_completed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
 v_commission numeric:=0;
 v_earning numeric:=0;
 v_pct numeric:=0;
 v_gross numeric:=0;
BEGIN
 IF NEW.status='completed' AND OLD.status IS DISTINCT FROM 'completed' AND NEW.provider_id IS NOT NULL THEN
  IF NEW.provider_role='driver' THEN
   UPDATE public.driver_profiles SET completed_rides=completed_rides+1 WHERE user_id=NEW.provider_id;
  ELSIF NEW.provider_role='large_driver' THEN
   UPDATE public.naqil_profiles SET completed_rides=completed_rides+1 WHERE user_id=NEW.provider_id;
  ELSIF NEW.provider_role='worker' THEN
   UPDATE public.worker_profiles SET completed_jobs=completed_jobs+1 WHERE user_id=NEW.provider_id;
  END IF;

  v_gross:=coalesce(NEW.customer_price::numeric,NEW.price_estimate,0);
  IF v_gross>0 THEN
   IF NEW.type='taxi' AND NEW.vehicle_category IS NOT NULL THEN
    SELECT coalesce(pr.commission_pct,0) INTO v_pct
    FROM public.pricing_rules pr
    WHERE pr.vehicle_category=NEW.vehicle_category::text AND pr.active=true
    ORDER BY pr.updated_at DESC LIMIT 1;
    v_pct:=coalesce(v_pct,0);
   ELSE
    v_pct:=0;
   END IF;
   v_commission:=round(v_gross*v_pct/100);
   v_earning:=v_gross-v_commission;
   INSERT INTO public.driver_wallets(user_id,balance,total_earned,total_commission)
   VALUES(NEW.provider_id,v_earning,v_earning,v_commission)
   ON CONFLICT(user_id) DO UPDATE SET
    balance=public.driver_wallets.balance+EXCLUDED.balance,
    total_earned=public.driver_wallets.total_earned+EXCLUDED.total_earned,
    total_commission=public.driver_wallets.total_commission+EXCLUDED.total_commission,
    updated_at=now();
   INSERT INTO public.transactions(user_id,request_id,type,amount,note)
   VALUES(NEW.provider_id,NEW.id,'earning',v_earning,
    CASE WHEN NEW.provider_role='large_driver' THEN 'كسب من طلب ناقل'
     WHEN NEW.provider_role='driver' THEN 'كسب من طلب سيارة' ELSE 'كسب من طلب خدمة' END);
   IF v_commission>0 THEN
    INSERT INTO public.transactions(user_id,request_id,type,amount,note)
    VALUES(NEW.provider_id,NEW.id,'commission',-v_commission,'عمولة المنصة');
   END IF;
   UPDATE public.service_requests SET commission=v_commission WHERE id=NEW.id;
   INSERT INTO public.notifications(user_id,type,title,body,link)
   VALUES(NEW.provider_id,'earning','أرباح جديدة','تمت إضافة '||v_earning::text||' د.ع إلى محفظتك','/profile');
  END IF;
  INSERT INTO public.notifications(user_id,type,title,body,link)
  VALUES(NEW.customer_id,'request_completed','اكتمل الطلب','يرجى تقييم مقدّم الخدمة','/request/'||NEW.id);
 END IF;
 RETURN NEW;
END $$;

