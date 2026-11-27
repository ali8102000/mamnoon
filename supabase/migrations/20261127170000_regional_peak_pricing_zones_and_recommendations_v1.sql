create table if not exists public.regional_peak_pricing_settings (
  id uuid primary key default gen_random_uuid(),
  governorate_key text not null check (governorate_key in ('baghdad','basra','nineveh','erbil','sulaymaniyah','duhok','kirkuk','najaf','karbala','babil','anbar','diyala','saladin','wasit','dhiqar','maysan','muthanna','qadisiyah')),
  city_name text not null,
  neighborhood_name text not null default '',
  category_key text not null,
  center_lat double precision not null check (center_lat between 29 and 38),
  center_lng double precision not null check (center_lng between 38 and 49),
  radius_km numeric not null default 3 check (radius_km between 0.1 and 40),
  min_surcharge_percent numeric not null default 0 check (min_surcharge_percent between 0 and 100),
  max_surcharge_percent numeric not null default 0 check (max_surcharge_percent between 0 and 100),
  mode text not null default 'off' check (mode in ('auto','notify','off')),
  enabled boolean not null default false,
  active_percent numeric not null default 0 check (active_percent between 0 and 100),
  manual_override_until timestamptz,
  observed_providers integer not null default 0,
  active_providers integer not null default 0,
  pending_requests integer not null default 0,
  demand_per_provider numeric not null default 0,
  last_reason text,
  last_calculated_at timestamptz,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint regional_peak_rate_order check (min_surcharge_percent <= max_surcharge_percent),
  constraint regional_peak_off_is_disabled check (mode <> 'off' or enabled = false)
);
create unique index if not exists regional_peak_settings_scope_uq on public.regional_peak_pricing_settings (governorate_key, lower(city_name), lower(neighborhood_name), category_key);
create index if not exists regional_peak_settings_enabled_idx on public.regional_peak_pricing_settings (governorate_key, category_key, enabled, mode) where enabled = true;
alter table public.regional_peak_pricing_settings enable row level security;
revoke all on public.regional_peak_pricing_settings from anon, public;
grant select on public.regional_peak_pricing_settings to authenticated;
drop policy if exists "Admins read regional peak settings" on public.regional_peak_pricing_settings;
create policy "Admins read regional peak settings" on public.regional_peak_pricing_settings for select to authenticated
using (public.admin_has_permission('pricing.peak.edit','governorate',governorate_key));

create table if not exists public.regional_peak_recommendations (
  id uuid primary key default gen_random_uuid(),
  setting_id uuid not null references public.regional_peak_pricing_settings(id) on delete cascade,
  governorate_key text not null,
  city_name text not null,
  neighborhood_name text not null default '',
  category_key text not null,
  center_lat double precision not null,
  center_lng double precision not null,
  radius_km numeric not null,
  suggested_percent numeric not null check (suggested_percent between 0 and 100),
  observed_providers integer not null default 0,
  active_providers integer not null default 0,
  pending_requests integer not null default 0,
  demand_per_provider numeric not null default 0,
  weather jsonb not null default '{}'::jsonb,
  reason text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected','expired')),
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists regional_peak_recommendations_pending_idx on public.regional_peak_recommendations (status, created_at desc);
alter table public.regional_peak_recommendations enable row level security;
revoke all on public.regional_peak_recommendations from anon, public;
grant select on public.regional_peak_recommendations to authenticated;
drop policy if exists "Admins read regional peak recommendations" on public.regional_peak_recommendations;
create policy "Admins read regional peak recommendations" on public.regional_peak_recommendations for select to authenticated
using (public.admin_has_permission('pricing.peak.edit','governorate',governorate_key));

create or replace function public.admin_save_regional_peak_pricing(
 p_governorate_key text,p_city_name text,p_neighborhood_name text,p_category_key text,
 p_center_lat double precision,p_center_lng double precision,p_radius_km numeric,
 p_min_surcharge_percent numeric,p_max_surcharge_percent numeric,p_mode text,p_enabled boolean
) returns public.regional_peak_pricing_settings
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_actor uuid:=auth.uid(); v_row public.regional_peak_pricing_settings%rowtype; v_category text;
begin
 if v_actor is null then raise exception 'unauthorized'; end if;
 if p_governorate_key not in ('baghdad','basra','nineveh','erbil','sulaymaniyah','duhok','kirkuk','najaf','karbala','babil','anbar','diyala','saladin','wasit','dhiqar','maysan','muthanna','qadisiyah') then raise exception 'invalid_governorate'; end if;
 if not public.admin_has_permission('pricing.peak.edit','governorate',p_governorate_key) then raise exception 'missing_pricing_permission'; end if;
 if length(trim(coalesce(p_city_name,''))) not between 1 and 100 or length(trim(coalesce(p_neighborhood_name,'')))>100 then raise exception 'invalid_area_name'; end if;
 if p_center_lat is null or p_center_lng is null or p_center_lat not between 29 and 38 or p_center_lng not between 38 and 49 then raise exception 'invalid_center_coordinates'; end if;
 if p_radius_km is null or p_radius_km not between 0.1 and 40 then raise exception 'invalid_radius'; end if;
 if p_min_surcharge_percent is null or p_max_surcharge_percent is null or p_min_surcharge_percent<0 or p_max_surcharge_percent>100 or p_min_surcharge_percent>p_max_surcharge_percent then raise exception 'invalid_surcharge_bounds'; end if;
 if p_mode not in ('auto','notify','off') or (p_mode='off' and p_enabled) then raise exception 'invalid_mode'; end if;
 v_category:=coalesce(p_category_key,'');
 if v_category not in ('taxi:economy','taxi:premium','taxi:luxury','taxi:large') and not exists(select 1 from public.services where 'service:'||slug=v_category) then raise exception 'invalid_category'; end if;
 insert into public.regional_peak_pricing_settings(governorate_key,city_name,neighborhood_name,category_key,center_lat,center_lng,radius_km,min_surcharge_percent,max_surcharge_percent,mode,enabled,active_percent,manual_override_until,updated_by,updated_at)
 values(p_governorate_key,trim(p_city_name),trim(coalesce(p_neighborhood_name,'')),v_category,p_center_lat,p_center_lng,p_radius_km,p_min_surcharge_percent,p_max_surcharge_percent,p_mode,coalesce(p_enabled,false),0,null,v_actor,now())
 on conflict (governorate_key,lower(city_name),lower(neighborhood_name),category_key)
 do update set center_lat=excluded.center_lat,center_lng=excluded.center_lng,radius_km=excluded.radius_km,min_surcharge_percent=excluded.min_surcharge_percent,max_surcharge_percent=excluded.max_surcharge_percent,mode=excluded.mode,enabled=excluded.enabled,active_percent=case when excluded.enabled then regional_peak_pricing_settings.active_percent else 0 end,manual_override_until=case when excluded.enabled then regional_peak_pricing_settings.manual_override_until else null end,updated_by=v_actor,updated_at=now()
 returning * into v_row;
 insert into public.audit_logs(user_id,action,target_type,target_id,details) values(v_actor,'pricing.peak.regional.settings.updated','regional_peak_pricing_settings',v_row.id::text,to_jsonb(v_row));
 return v_row;
end $$;

create or replace function public.admin_decide_regional_peak_recommendation(p_recommendation_id uuid,p_approve boolean)
returns public.regional_peak_recommendations
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_actor uuid:=auth.uid(); v_rec public.regional_peak_recommendations%rowtype;
begin
 if v_actor is null then raise exception 'unauthorized'; end if;
 select * into v_rec from public.regional_peak_recommendations where id=p_recommendation_id for update;
 if not found then raise exception 'recommendation_not_found'; end if;
 if not public.admin_has_permission('pricing.peak.edit','governorate',v_rec.governorate_key) then raise exception 'missing_pricing_permission'; end if;
 if v_rec.status<>'pending' then raise exception 'recommendation_already_decided'; end if;
 update public.regional_peak_recommendations set status=case when p_approve then 'approved' else 'rejected' end,decided_by=v_actor,decided_at=now() where id=p_recommendation_id returning * into v_rec;
 if p_approve then
  update public.regional_peak_pricing_settings set active_percent=greatest(min_surcharge_percent,least(max_surcharge_percent,v_rec.suggested_percent)),manual_override_until=now()+interval '30 minutes',last_reason='تمت الموافقة الإدارية على توصية الذروة لمدة 30 دقيقة',updated_at=now()
  where id=v_rec.setting_id and enabled=true and mode='notify';
 end if;
 insert into public.audit_logs(user_id,action,target_type,target_id,details) values(v_actor,case when p_approve then 'pricing.peak.recommendation.approved' else 'pricing.peak.recommendation.rejected' end,'regional_peak_recommendations',v_rec.id::text,to_jsonb(v_rec));
 return v_rec;
end $$;

create or replace function public.refresh_regional_peak_pricing_monitor()
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare z record; v_observed integer; v_active integer; v_pending integer; v_ratio numeric; v_suggested numeric; v_weather jsonb; v_rain numeric; v_temp numeric; v_weather_bonus numeric; v_reason text; v_created uuid; v_processed integer:=0; v_role text; v_vehicle text;
begin
 update public.regional_peak_recommendations set status='expired' where status='pending' and created_at<now()-interval '2 hours';
 for z in select * from public.regional_peak_pricing_settings order by radius_km asc loop
  if not z.enabled or z.mode='off' then
   update public.regional_peak_pricing_settings set active_percent=0,manual_override_until=null,last_reason='التسعير متوقف من الإدارة',last_calculated_at=now() where id=z.id and (active_percent<>0 or manual_override_until is not null);
   v_processed:=v_processed+1; continue;
  end if;
  if z.mode='notify' and z.manual_override_until is not null and z.manual_override_until<=now() then
   update public.regional_peak_pricing_settings set active_percent=0,manual_override_until=null,last_reason='انتهت الموافقة المؤقتة وعادت الأجرة الأساسية',updated_at=now() where id=z.id;
  end if;
  v_observed:=0; v_active:=0; v_pending:=0; v_weather:='{}'::jsonb; v_rain:=0; v_temp:=0; v_weather_bonus:=0;
  if left(z.category_key,5)='taxi:' then
   v_vehicle:=split_part(z.category_key,':',2); v_role:=case when v_vehicle='large' then 'large_driver' else 'driver' end;
   select count(distinct p.user_id)::int,count(distinct p.user_id) filter(where p.available=true and pp.status='online')::int into v_observed,v_active
   from public.provider_role_profiles_presence p join public.provider_presence_roles pp on pp.user_id=p.user_id and pp.role=p.role
   where p.role=v_role and p.vehicle_category=v_vehicle and p.status='approved' and (p.suspended_until is null or p.suspended_until<=now())
    and pp.updated_at>now()-interval '5 minutes' and pp.accuracy_m<=100 and pp.lat is not null and pp.lng is not null
    and 6371.0088*2*asin(sqrt(least(1,greatest(0,power(sin(radians(pp.lat-z.center_lat)/2),2)+cos(radians(z.center_lat))*cos(radians(pp.lat))*power(sin(radians(pp.lng-z.center_lng)/2),2)))))<=z.radius_km;
   select count(*)::int into v_pending from public.service_requests sr where sr.type::text='taxi' and sr.vehicle_category::text=v_vehicle and lower(sr.status::text) in ('pending','searching') and sr.created_at>now()-interval '20 minutes'
    and sr.pickup_lat is not null and sr.pickup_lng is not null
    and 6371.0088*2*asin(sqrt(least(1,greatest(0,power(sin(radians(sr.pickup_lat::float8-z.center_lat)/2),2)+cos(radians(z.center_lat))*cos(radians(sr.pickup_lat::float8))*power(sin(radians(sr.pickup_lng::float8-z.center_lng)/2),2)))))<=z.radius_km;
  else
   select count(distinct wp.user_id)::int,count(distinct wp.user_id) filter(where wp.available=true and pp.status='online')::int into v_observed,v_active
   from public.worker_profiles wp join public.worker_services ws on ws.worker_id=wp.user_id join public.services s on s.id=ws.service_id join public.provider_presence_roles pp on pp.user_id=wp.user_id and pp.role='worker'
   where 'service:'||s.slug=z.category_key and wp.status='approved' and (wp.suspended_until is null or wp.suspended_until<=now())
    and pp.updated_at>now()-interval '5 minutes' and pp.accuracy_m<=100 and pp.lat is not null and pp.lng is not null
    and 6371.0088*2*asin(sqrt(least(1,greatest(0,power(sin(radians(pp.lat-z.center_lat)/2),2)+cos(radians(z.center_lat))*cos(radians(pp.lat))*power(sin(radians(pp.lng-z.center_lng)/2),2)))))<=z.radius_km;
   select count(*)::int into v_pending from public.service_requests sr join public.services s on s.id=sr.service_id where sr.type::text='service' and 'service:'||s.slug=z.category_key and lower(sr.status::text) in ('pending','searching') and sr.created_at>now()-interval '20 minutes'
    and sr.pickup_lat is not null and sr.pickup_lng is not null
    and 6371.0088*2*asin(sqrt(least(1,greatest(0,power(sin(radians(sr.pickup_lat::float8-z.center_lat)/2),2)+cos(radians(z.center_lat))*cos(radians(sr.pickup_lat::float8))*power(sin(radians(sr.pickup_lng::float8-z.center_lng)/2),2)))))<=z.radius_km;
  end if;
  select jsonb_build_object('temperature_c',o.temperature_c,'rain_mm',o.rain_mm,'condition_text',o.condition_text,'observed_at',o.observed_at,'provider',o.provider,'fresh',o.is_fresh) into v_weather
  from public.taxi_peak_weather_observations o where o.governorate_key=z.governorate_key and o.is_fresh=true and o.fetched_at>now()-interval '45 minutes' order by o.fetched_at desc limit 1;
  v_weather:=coalesce(v_weather,'{}'::jsonb); v_rain:=coalesce((v_weather->>'rain_mm')::numeric,0); v_temp:=coalesce((v_weather->>'temperature_c')::numeric,0);
  v_weather_bonus:=case when v_rain>=2 then 5 when v_temp>=42 then 3 else 0 end;
  v_ratio:=coalesce(v_pending,0)::numeric/greatest(coalesce(v_active,0),1); v_suggested:=0; v_reason:='الطلب والتوفر متوازنان؛ لا توجد زيادة مطلوبة';
  if v_observed=0 then v_reason:='بيانات GPS غير كافية أو قديمة؛ لا تُطبّق أي زيادة';
  elsif v_pending=0 or v_ratio<0.75 then v_reason:='لا يوجد ضغط طلب كافٍ؛ الأجرة الأساسية مستمرة';
  elsif v_ratio<1.5 then v_suggested:=z.min_surcharge_percent+((z.max_surcharge_percent-z.min_surcharge_percent)*((v_ratio-0.75)/0.75)); v_reason:='الطلبات تقترب من عدد مقدمي الخدمة؛ زيادة تدريجية مقترحة';
  else v_suggested:=z.max_surcharge_percent; v_reason:='الطلبات تتجاوز التوفر المحلي؛ ضغط مرتفع'; end if;
  if v_suggested>0 then v_suggested:=least(z.max_surcharge_percent,v_suggested+v_weather_bonus); end if;
  v_suggested:=round(greatest(0,least(z.max_surcharge_percent,v_suggested)),2);
  update public.regional_peak_pricing_settings set observed_providers=coalesce(v_observed,0),active_providers=coalesce(v_active,0),pending_requests=coalesce(v_pending,0),demand_per_provider=round(v_ratio,3),
   last_reason=case when v_weather_bonus>0 and v_suggested>0 then v_reason||'، مع تأثير الطقس للمحافظة' else v_reason end,last_calculated_at=now(),
   active_percent=case when mode='auto' then v_suggested when mode='notify' and manual_override_until is not null and manual_override_until>now() then active_percent else 0 end,updated_at=now()
   where id=z.id;
  if z.mode='notify' and v_suggested>0 and v_observed>0 and not exists(select 1 from public.regional_peak_recommendations r where r.setting_id=z.id and r.status='pending' and r.created_at>now()-interval '30 minutes') then
   insert into public.regional_peak_recommendations(setting_id,governorate_key,city_name,neighborhood_name,category_key,center_lat,center_lng,radius_km,suggested_percent,observed_providers,active_providers,pending_requests,demand_per_provider,weather,reason)
   values(z.id,z.governorate_key,z.city_name,z.neighborhood_name,z.category_key,z.center_lat,z.center_lng,z.radius_km,v_suggested,v_observed,v_active,v_pending,round(v_ratio,3),v_weather,v_reason) returning id into v_created;
   insert into public.notifications(user_id,type,title,body,link,data)
   select distinct ur.user_id,'regional_peak_recommendation','توصية ذروة جديدة · '||z.city_name||case when z.neighborhood_name<>'' then ' · '||z.neighborhood_name else '' end,
    'ضغط طلب على '||z.category_key||'. النسبة المقترحة '||v_suggested::text||'%؛ المتاحون '||v_active::text||' والطلبات '||v_pending::text||'. راجع التوصية في لوحة الإدارة.',
    '/admin',jsonb_build_object('recommendation_id',v_created,'governorate_key',z.governorate_key,'city_name',z.city_name,'neighborhood_name',z.neighborhood_name,'category_key',z.category_key,'suggested_percent',v_suggested,'center_lat',z.center_lat,'center_lng',z.center_lng)
   from public.user_roles ur where ur.role::text in ('super_admin','admin');
  end if;
  v_processed:=v_processed+1;
 end loop;
 return v_processed;
end $$;

revoke all on function public.admin_save_regional_peak_pricing(text,text,text,text,double precision,double precision,numeric,numeric,numeric,text,boolean) from public,anon;
grant execute on function public.admin_save_regional_peak_pricing(text,text,text,text,double precision,double precision,numeric,numeric,numeric,text,boolean) to authenticated;
revoke all on function public.admin_decide_regional_peak_recommendation(uuid,boolean) from public,anon;
grant execute on function public.admin_decide_regional_peak_recommendation(uuid,boolean) to authenticated;
revoke all on function public.refresh_regional_peak_pricing_monitor() from public,anon,authenticated;
grant execute on function public.refresh_regional_peak_pricing_monitor() to service_role;
do $$ begin
 if exists(select 1 from cron.job where jobname='mamnoon-regional-peak-monitor') then perform cron.unschedule((select jobid from cron.job where jobname='mamnoon-regional-peak-monitor' limit 1)); end if;
 perform cron.schedule('mamnoon-regional-peak-monitor','* * * * *','select public.refresh_regional_peak_pricing_monitor();');
end $$;
