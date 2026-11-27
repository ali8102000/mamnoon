alter table public.service_requests
  add column if not exists regional_peak_percent numeric not null default 0
  check (regional_peak_percent between 0 and 100);

create or replace function public.apply_regional_peak_to_fixed_request()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_category text; v_percent numeric:=0; v_zone record; v_base numeric; v_new_price numeric;
begin
 if new.type::text='taxi' and new.vehicle_category::text='large' then
  v_category:='taxi:large';
 elsif new.type::text='service' and new.pricing_mode='fixed' and new.service_id is not null then
  select 'service:'||slug into v_category from public.services where id=new.service_id;
 else return new; end if;
 if v_category is null or new.governorate_key is null or new.pickup_lat is null or new.pickup_lng is null then return new; end if;
 select s.* into v_zone from public.regional_peak_pricing_settings s
 where s.governorate_key=new.governorate_key and s.category_key=v_category and s.enabled=true and s.active_percent>0
  and (s.mode='auto' or (s.mode='notify' and s.manual_override_until>now()))
  and 6371.0088*2*asin(sqrt(least(1,greatest(0,power(sin(radians(new.pickup_lat::float8-s.center_lat)/2),2)+cos(radians(s.center_lat))*cos(radians(new.pickup_lat::float8))*power(sin(radians(new.pickup_lng::float8-s.center_lng)/2),2)))))<=s.radius_km
 order by s.radius_km asc limit 1;
 if not found then return new; end if;
 v_percent:=greatest(0,least(100,v_zone.active_percent));v_base:=coalesce(new.customer_price::numeric,new.price_estimate,0);
 if v_base<=0 or v_percent<=0 then return new; end if;
 v_new_price:=round((v_base*(1+v_percent/100))/250)*250;
 if new.type::text='taxi' and new.vehicle_category::text='large' and v_new_price>50000 then return new; end if;
 if new.customer_price is not null then new.customer_price:=round(v_new_price)::integer; end if;
 if new.price_estimate is not null then new.price_estimate:=v_new_price; end if;
 if new.customer_payable is not null then new.customer_payable:=greatest(v_new_price-coalesce(new.coupon_discount,0),0); end if;
 new.regional_peak_percent:=v_percent;
 if new.type::text='taxi' then new.taxi_peak_percent:=greatest(coalesce(new.taxi_peak_percent,0),v_percent); end if;
 new.fare_breakdown:=coalesce(new.fare_breakdown,'{}'::jsonb)||jsonb_build_object('regionalPeakPercent',v_percent,'regionalPeakCity',v_zone.city_name,'regionalPeakNeighborhood',v_zone.neighborhood_name,'regionalPeakRadiusKm',v_zone.radius_km);
 return new;
end $$;
drop trigger if exists zz_apply_regional_peak_to_request on public.service_requests;
create trigger zz_apply_regional_peak_to_request before insert on public.service_requests for each row execute function public.apply_regional_peak_to_fixed_request();
revoke all on function public.apply_regional_peak_to_fixed_request() from public,anon,authenticated;