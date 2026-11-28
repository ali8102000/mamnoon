-- Provider-facing read-only view of company money owed to the authenticated provider.
create or replace function public.get_my_provider_payables_summary()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_gross bigint := 0;
  v_commission bigint := 0;
  v_coupon_subsidy bigint := 0;
  v_payable bigint := 0;
  v_settled bigint := 0;
begin
  if v_actor is null then raise exception 'unauthorized'; end if;
  if not exists (
    select 1 from public.user_roles
    where user_id=v_actor and role::text in ('driver','worker','large_driver')
  ) then raise exception 'provider_account_required'; end if;

  select coalesce(sum(p.cash_iqd),0)::bigint,
         coalesce(sum(least(p.cash_iqd+coalesce(c.subsidy_iqd,0),greatest(0,round(coalesce(p.commission,0)))::bigint)),0)::bigint
  into v_gross,v_commission
  from (
    select sr.id,sr.commission,sum(pt.amount)::bigint cash_iqd
    from public.service_requests sr
    join public.payment_transactions pt on pt.request_id=sr.id
      and pt.purpose='service_request' and pt.status='paid'
      and pt.provider in ('zaincash','customer_wallet') and pt.currency='IQD'
      and pt.user_id=sr.customer_id
    where sr.provider_id=v_actor and sr.status='completed'
      and sr.payment_method in ('zaincash','customer_wallet')
    group by sr.id,sr.commission
  ) p
  left join (
    select request_id,sum(discount_amount)::bigint subsidy_iqd
    from public.coupon_subsidy_ledger
    where provider_id=v_actor and status='payable'
    group by request_id
  ) c on c.request_id=p.id;

  select coalesce(sum(discount_amount),0)::bigint into v_coupon_subsidy
  from public.coupon_subsidy_ledger
  where provider_id=v_actor and status='payable';

  v_payable:=greatest(0,v_gross+v_coupon_subsidy-v_commission);
  select coalesce(sum(amount_iqd),0)::bigint into v_settled
  from public.mamnoon_provider_cash_settlements where provider_id=v_actor;

  return jsonb_build_object(
    'gross_paid_iqd',v_gross,
    'commission_iqd',v_commission,
    'coupon_subsidy_iqd',v_coupon_subsidy,
    'payable_iqd',v_payable,
    'settled_iqd',v_settled,
    'outstanding_iqd',greatest(0,v_payable-v_settled),
    'over_settled_iqd',greatest(0,v_settled-v_payable)
  );
end;
$function$;

revoke all on function public.get_my_provider_payables_summary() from public,anon;
grant execute on function public.get_my_provider_payables_summary() to authenticated;
