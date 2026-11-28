-- Personal coupon issuance: one unique, account-bound code per recipient.
alter table public.coupons
  add column if not exists distribution_template boolean not null default false,
  add column if not exists source_coupon_id uuid references public.coupons(id) on delete set null,
  add column if not exists issued_to_user_id uuid references public.profiles(id) on delete set null,
  add column if not exists category_key text not null default 'taxi';

alter table public.coupons drop constraint if exists coupons_category_key_check;
alter table public.coupons add constraint coupons_category_key_check
  check (category_key in ('taxi','large_vehicle','technician','mixed'));

create index if not exists coupons_distribution_template_idx
  on public.coupons(distribution_template, created_at desc);
create index if not exists coupons_source_coupon_idx
  on public.coupons(source_coupon_id, created_at desc)
  where source_coupon_id is not null;
create index if not exists coupons_issued_to_user_idx
  on public.coupons(issued_to_user_id)
  where issued_to_user_id is not null;

create or replace function public.sync_coupon_category_key()
returns trigger
language plpgsql
set search_path=public
as $function$
begin
  new.category_key := case
    when cardinality(new.applicable_request_types)=1 and new.applicable_request_types @> array['service']::text[] then 'technician'
    when cardinality(new.applicable_request_types)=1 and new.applicable_request_types @> array['taxi']::text[]
         and new.applicable_vehicle_categories = array['large']::text[] then 'large_vehicle'
    when cardinality(new.applicable_request_types)=1 and new.applicable_request_types @> array['taxi']::text[] then 'taxi'
    else 'mixed'
  end;
  return new;
end;
$function$;

drop trigger if exists sync_coupon_category_key_before_write on public.coupons;
create trigger sync_coupon_category_key_before_write
before insert or update of applicable_request_types,applicable_vehicle_categories,applicable_service_slugs
on public.coupons
for each row execute function public.sync_coupon_category_key();

update public.coupons
set category_key = case
  when cardinality(applicable_request_types)=1 and applicable_request_types @> array['service']::text[] then 'technician'
  when cardinality(applicable_request_types)=1 and applicable_request_types @> array['taxi']::text[]
       and applicable_vehicle_categories = array['large']::text[] then 'large_vehicle'
  when cardinality(applicable_request_types)=1 and applicable_request_types @> array['taxi']::text[] then 'taxi'
  else 'mixed'
end;

-- Existing one-recipient coupons are already private; mark their owner.
update public.coupons c
set issued_to_user_id = a.user_id
from public.coupon_assignments a
where a.coupon_id = c.id
  and c.issued_to_user_id is null
  and (select count(*) from public.coupon_assignments x where x.coupon_id=c.id)=1;

-- Convert legacy shared coupons into separate personal codes for every still-unredeemed recipient.
do $migration$
declare
  v_coupon public.coupons%rowtype;
  v_assignment record;
  v_new_id uuid;
  v_code text;
begin
  for v_coupon in
    select c.*
    from public.coupons c
    where (select count(*) from public.coupon_assignments a where a.coupon_id=c.id) > 1
    for update
  loop
    for v_assignment in
      select a.user_id, a.assigned_by, a.assigned_at
      from public.coupon_assignments a
      where a.coupon_id=v_coupon.id
        and not exists (
          select 1 from public.coupon_redemptions r
          where r.coupon_id=v_coupon.id and r.user_id=a.user_id
        )
    loop
      loop
        v_code := 'MN' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
        insert into public.coupons(
          code,type,value,max_uses,used_count,min_amount,expires_at,active,
          applicable_request_types,applicable_vehicle_categories,applicable_service_slugs,
          distribution_template,source_coupon_id,issued_to_user_id,category_key
        ) values (
          v_code,v_coupon.type,v_coupon.value,1,0,v_coupon.min_amount,v_coupon.expires_at,v_coupon.active,
          v_coupon.applicable_request_types,v_coupon.applicable_vehicle_categories,v_coupon.applicable_service_slugs,
          false,v_coupon.id,v_assignment.user_id,v_coupon.category_key
        )
        on conflict (code) do nothing
        returning id into v_new_id;
        exit when v_new_id is not null;
      end loop;

      insert into public.coupon_assignments(coupon_id,user_id,assigned_by,assigned_at)
      values(v_new_id,v_assignment.user_id,v_assignment.assigned_by,v_assignment.assigned_at);

      delete from public.coupon_assignments
      where coupon_id=v_coupon.id and user_id=v_assignment.user_id;

      insert into public.notifications(user_id,type,title,body,link,data)
      values(
        v_assignment.user_id,'coupon_received','تم تخصيص كوبون خاص إلك من ممنون 🎁',
        'رمزك الشخصي الجديد: '||v_code||' — هذا الرمز مرتبط بحسابك فقط.',
        '/coupons',
        jsonb_build_object('coupon_id',v_new_id,'code',v_code,'source','legacy_coupon_migration')
      );
    end loop;

    update public.coupons set active=false,updated_at=now()
    where id=v_coupon.id;
  end loop;
end;
$migration$;

-- Unassigned coupons become administrator-managed distribution templates.
update public.coupons c
set distribution_template=true
where c.source_coupon_id is null
  and not exists(select 1 from public.coupon_assignments a where a.coupon_id=c.id)
  and not exists(select 1 from public.coupon_redemptions r where r.coupon_id=c.id);

create or replace function public.admin_save_coupon_v3(
  p_id uuid,
  p_code text,
  p_type text,
  p_value numeric,
  p_max_uses integer,
  p_expires_at timestamptz,
  p_active boolean,
  p_min_amount numeric,
  p_category_key text
) returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_id uuid;
  v_request_types text[];
  v_vehicle_categories text[];
begin
  if auth.uid() is null or not (
    public.has_admin_access(auth.uid())
    or public.admin_has_permission('promotions.manage','global',null)
  ) then raise exception 'missing_promotions_manage_permission'; end if;

  if p_category_key not in ('taxi','large_vehicle','technician') then
    raise exception 'invalid_coupon_category';
  end if;

  if p_id is not null and not exists(
    select 1 from public.coupons where id=p_id and distribution_template=true
  ) then raise exception 'coupon_template_not_found'; end if;

  v_id:=public.admin_save_coupon(
    p_id,p_code,p_type,p_value,p_max_uses,p_expires_at,p_active,p_min_amount
  );

  if p_category_key='taxi' then
    v_request_types:=array['taxi']::text[];
    v_vehicle_categories:=array['economy','premium','luxury']::text[];
  elsif p_category_key='large_vehicle' then
    v_request_types:=array['taxi']::text[];
    v_vehicle_categories:=array['large']::text[];
  else
    v_request_types:=array['service']::text[];
    v_vehicle_categories:='{}'::text[];
  end if;

  update public.coupons
  set category_key=p_category_key,
      applicable_request_types=v_request_types,
      applicable_vehicle_categories=v_vehicle_categories,
      applicable_service_slugs='{}'::text[],
      distribution_template=true,
      issued_to_user_id=null,
      source_coupon_id=null,
      updated_at=now()
  where id=v_id;

  return v_id;
end;
$function$;
revoke all on function public.admin_save_coupon_v3(uuid,text,text,numeric,integer,timestamptz,boolean,numeric,text) from public,anon;
grant execute on function public.admin_save_coupon_v3(uuid,text,text,numeric,integer,timestamptz,boolean,numeric,text) to authenticated;

create or replace function public.admin_coupon_audience_count(p_target text)
returns integer
language plpgsql
security definer
set search_path=public
as $function$
declare v_count integer;
begin
  if not (public.has_admin_access(auth.uid()) or public.admin_has_permission('promotions.read','global',null)) then
    raise exception 'missing_promotions_read_permission';
  end if;
  if p_target not in ('customers','single','customers_1','customers_2','customers_3','customers_4','customers_5') then
    raise exception 'invalid_coupon_audience';
  end if;
  if p_target='single' then return 1; end if;
  with activity as (
    select customer_id,count(*)::integer as request_count
    from public.service_requests
    where created_at>=now()-interval '7 days' and status::text<>'cancelled'
    group by customer_id
  )
  select count(*)::integer into v_count
  from public.profiles p
  left join activity a on a.customer_id=p.id
  where exists(select 1 from public.user_roles r where r.user_id=p.id and r.role='customer')
    and not exists(select 1 from public.user_roles r where r.user_id=p.id and r.role in ('driver','worker','large_driver'))
    and case p_target
      when 'customers' then true
      when 'customers_1' then coalesce(a.request_count,0)=1
      when 'customers_2' then coalesce(a.request_count,0)=2
      when 'customers_3' then coalesce(a.request_count,0)=3
      when 'customers_4' then coalesce(a.request_count,0)=4
      when 'customers_5' then coalesce(a.request_count,0)>=5
      else false
    end;
  return coalesce(v_count,0);
end;
$function$;

create or replace function public.admin_distribute_coupon(
  p_coupon_id uuid,
  p_target text default 'customers',
  p_single_user_id uuid default null
) returns integer
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_template public.coupons%rowtype;
  v_target record;
  v_new_id uuid;
  v_code text;
  v_count integer:=0;
begin
  if auth.uid() is null or not (
    public.has_admin_access(auth.uid())
    or public.admin_has_permission('promotions.manage','global',null)
  ) then raise exception 'missing_promotions_manage_permission'; end if;

  if p_target not in ('customers','single','customers_1','customers_2','customers_3','customers_4','customers_5') then
    raise exception 'invalid_coupon_audience';
  end if;
  if p_target='single' and p_single_user_id is null then raise exception 'حدد حساب الزبون'; end if;

  select * into v_template
  from public.coupons
  where id=p_coupon_id and distribution_template=true
    and active=true and (expires_at is null or expires_at>now())
    and used_count<max_uses
  for update;
  if not found then raise exception 'الكوبون متوقف أو منتهي أو وصل الحد الأعلى للتوزيع'; end if;

  if p_target='single' and (
    not exists(select 1 from public.user_roles r where r.user_id=p_single_user_id and r.role='customer')
    or exists(select 1 from public.user_roles r where r.user_id=p_single_user_id and r.role in ('driver','worker','large_driver'))
  ) then raise exception 'المستخدم المحدد ليس حساب زبون مؤهلاً'; end if;

  for v_target in
    with activity as (
      select customer_id,count(*)::integer as request_count
      from public.service_requests
      where created_at>=now()-interval '7 days' and status::text<>'cancelled'
      group by customer_id
    )
    select p.id,p.full_name
    from public.profiles p
    left join activity a on a.customer_id=p.id
    where exists(select 1 from public.user_roles r where r.user_id=p.id and r.role='customer')
      and not exists(select 1 from public.user_roles r where r.user_id=p.id and r.role in ('driver','worker','large_driver'))
      and case p_target
        when 'customers' then true
        when 'single' then p.id=p_single_user_id
        when 'customers_1' then coalesce(a.request_count,0)=1
        when 'customers_2' then coalesce(a.request_count,0)=2
        when 'customers_3' then coalesce(a.request_count,0)=3
        when 'customers_4' then coalesce(a.request_count,0)=4
        when 'customers_5' then coalesce(a.request_count,0)>=5
        else false
      end
    order by p.created_at,p.id
  loop
    exit when v_template.used_count>=v_template.max_uses;
    if exists(
      select 1 from public.coupon_assignments a
      join public.coupons issued on issued.id=a.coupon_id
      where issued.source_coupon_id=v_template.id and a.user_id=v_target.id
    ) then continue; end if;

    v_new_id:=null;
    loop
      v_code:='MN'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
      insert into public.coupons(
        code,type,value,max_uses,used_count,min_amount,expires_at,active,
        applicable_request_types,applicable_vehicle_categories,applicable_service_slugs,
        distribution_template,source_coupon_id,issued_to_user_id,category_key
      ) values (
        v_code,v_template.type,v_template.value,1,0,v_template.min_amount,v_template.expires_at,true,
        v_template.applicable_request_types,v_template.applicable_vehicle_categories,v_template.applicable_service_slugs,
        false,v_template.id,v_target.id,v_template.category_key
      )
      on conflict(code) do nothing
      returning id into v_new_id;
      exit when v_new_id is not null;
    end loop;

    insert into public.coupon_assignments(coupon_id,user_id,assigned_by)
    values(v_new_id,v_target.id,auth.uid());

    insert into public.notifications(user_id,type,title,body,link,data)
    values(
      v_target.id,'coupon_received','وصلك كوبون شخصي من ممنون 🎁',
      'رمزك الخاص: '||v_code||' — هذا الرمز مرتبط بحسابك فقط ولا يعمل بحساب آخر.',
      '/coupons',
      jsonb_build_object('coupon_id',v_new_id,'code',v_code,'category',v_template.category_key,
        'type',v_template.type,'value',v_template.value,'expires_at',v_template.expires_at)
    );

    v_count:=v_count+1;
    v_template.used_count:=v_template.used_count+1;
  end loop;

  update public.coupons set used_count=v_template.used_count,updated_at=now()
  where id=v_template.id;

  perform public.log_admin_action('distribute_personal_coupon','coupon',v_template.id::text,
    jsonb_build_object('target',p_target,'sent',v_count,'category',v_template.category_key));
  return v_count;
end;
$function$;
revoke all on function public.admin_distribute_coupon(uuid,text,uuid) from public,anon;
grant execute on function public.admin_distribute_coupon(uuid,text,uuid) to authenticated;

create or replace function public.admin_list_coupon_issued_codes(p_template_id uuid default null)
returns table(
  coupon_id uuid,
  source_coupon_id uuid,
  code text,
  category_key text,
  user_id uuid,
  full_name text,
  phone text,
  assigned_at timestamptz,
  used boolean,
  active boolean,
  expires_at timestamptz,
  discount_type text,
  discount_value numeric
)
language plpgsql
stable
security definer
set search_path=public
as $function$
begin
  if auth.uid() is null or not (
    public.has_admin_access(auth.uid())
    or public.admin_has_permission('promotions.read','global',null)
  ) then raise exception 'missing_promotions_read_permission'; end if;

  return query
  select c.id,c.source_coupon_id,c.code,c.category_key,a.user_id,p.full_name,p.phone,a.assigned_at,
    exists(select 1 from public.coupon_redemptions r where r.coupon_id=c.id and r.user_id=a.user_id),
    c.active,c.expires_at,c.type,c.value
  from public.coupons c
  join public.coupon_assignments a on a.coupon_id=c.id
  left join public.profiles p on p.id=a.user_id
  where c.source_coupon_id is not null
    and (p_template_id is null or c.source_coupon_id=p_template_id)
  order by a.assigned_at desc
  limit 500;
end;
$function$;
revoke all on function public.admin_list_coupon_issued_codes(uuid) from public,anon;
grant execute on function public.admin_list_coupon_issued_codes(uuid) to authenticated;

create or replace function public.get_my_coupons_v3()
returns table(
  id uuid,code text,type text,value numeric,min_amount numeric,expires_at timestamptz,
  active boolean,assigned_at timestamptz,used boolean,
  applicable_request_types text[],applicable_vehicle_categories text[],applicable_service_slugs text[],
  category_key text
)
language sql
stable
security definer
set search_path=public
as $function$
  select c.id,c.code,c.type,c.value,c.min_amount,c.expires_at,c.active,a.assigned_at,
    exists(select 1 from public.coupon_redemptions r where r.coupon_id=c.id and r.user_id=auth.uid()),
    c.applicable_request_types,c.applicable_vehicle_categories,c.applicable_service_slugs,c.category_key
  from public.coupon_assignments a
  join public.coupons c on c.id=a.coupon_id
  where auth.uid() is not null and a.user_id=auth.uid()
    and exists(select 1 from public.user_roles r where r.user_id=auth.uid() and r.role='customer')
    and not exists(select 1 from public.user_roles r where r.user_id=auth.uid() and r.role in ('driver','worker','large_driver'))
  order by a.assigned_at desc;
$function$;
revoke all on function public.get_my_coupons_v3() from public,anon;
grant execute on function public.get_my_coupons_v3() to authenticated;

create or replace function public.admin_delete_coupon(p_coupon_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $function$
begin
  if not (public.has_admin_access(auth.uid()) or public.admin_has_permission('promotions.manage','global',null)) then
    raise exception 'missing_promotions_manage_permission';
  end if;
  update public.coupons set active=false,updated_at=now()
  where source_coupon_id=p_coupon_id and distribution_template=false;
  delete from public.coupons where id=p_coupon_id and distribution_template=true;
  perform public.log_admin_action('delete_coupon','coupon',p_coupon_id::text);
end;
$function$;
revoke all on function public.admin_delete_coupon(uuid) from public,anon;
grant execute on function public.admin_delete_coupon(uuid) to authenticated;
