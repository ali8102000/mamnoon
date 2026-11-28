-- Customer wallet payments and coupon-funded provider payables.
-- The customer pays only the post-coupon amount. Coupon subsidy remains a separate company payable.

create unique index if not exists payment_transactions_customer_wallet_request_uidx
on public.payment_transactions(request_id)
where provider = 'customer_wallet' and purpose = 'service_request' and request_id is not null;

create or replace function public.pay_service_request_from_customer_wallet(_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v public.service_requests%rowtype;
  v_fare bigint;
  v_wallet_tx jsonb;
  v_existing public.payment_transactions%rowtype;
begin
  if v_actor is null then raise exception 'unauthorized'; end if;
  if _request_id is null then raise exception 'request_id_required'; end if;

  select * into v from public.service_requests
  where id = _request_id for update;
  if not found then raise exception 'request_not_found'; end if;
  if v.customer_id is distinct from v_actor then raise exception 'forbidden'; end if;
  if v.status::text not in ('accepted','in_progress') then
    raise exception 'wallet_payment_only_after_provider_acceptance';
  end if;
  if v.provider_id is null then raise exception 'provider_not_assigned'; end if;
  if v.payment_method = 'customer_wallet' then
    select * into v_existing from public.payment_transactions
    where request_id = _request_id and provider = 'customer_wallet'
      and purpose = 'service_request' and status = 'paid'
    limit 1;
    if found then
      return jsonb_build_object('paid',true,'duplicate',true,'amount_iqd',v_existing.amount);
    end if;
    raise exception 'wallet_payment_state_conflict';
  end if;
  if v.payment_method = 'zaincash' then raise exception 'request_already_paid'; end if;

  v_fare := round(coalesce(v.customer_payable, v.customer_price, v.price_estimate, 0))::bigint;
  if v_fare is null or v_fare <= 0 then raise exception 'invalid_request_payable'; end if;

  v_wallet_tx := public.apply_customer_wallet_transaction(
    v_actor,
    'payment',
    -v_fare,
    'mamnoon_customer_wallet',
    'service-request:' || _request_id::text,
    'دفع طلب ممنون من المحفظة الداخلية',
    jsonb_build_object('request_id',_request_id,'provider_id',v.provider_id,'payment_method','customer_wallet')
  );

  insert into public.payment_transactions(
    user_id,purpose,request_id,amount,currency,provider,status,paid_at,metadata
  ) values (
    v_actor,'service_request',_request_id,v_fare,'IQD','customer_wallet','paid',now(),
    jsonb_build_object(
      'wallet_transaction_id',v_wallet_tx->>'transaction_id',
      'provider_id',v.provider_id,
      'coupon_discount_iqd',round(coalesce(v.coupon_discount,0))::bigint,
      'gross_fare_iqd',round(coalesce(v.customer_payable, v.customer_price, v.price_estimate, 0) + coalesce(v.coupon_discount,0))::bigint
    )
  );

  update public.service_requests
  set payment_method = 'customer_wallet', updated_at = now()
  where id = _request_id;

  return jsonb_build_object(
    'paid',true,'duplicate',false,'amount_iqd',v_fare,
    'wallet_balance',v_wallet_tx->'balance'
  );
end;
$function$;

revoke all on function public.pay_service_request_from_customer_wallet(uuid) from public, anon;
grant execute on function public.pay_service_request_from_customer_wallet(uuid) to authenticated;

-- Treat customer-wallet payment as electronic during provider completion (no cash collection).
create or replace function public.complete_service_request_with_cash(_request_id uuid, _cash_received_iqd bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v public.service_requests%rowtype;
  v_actor uuid := auth.uid();
  v_is_service_member boolean := false;
  v_fare_iqd bigint;
  v_cash_iqd bigint;
  v_change_iqd bigint;
  v_customer_balance bigint;
  v_provider_balance bigint;
  v_customer_next bigint;
  v_provider_next bigint;
  v_customer_tx uuid;
  v_provider_tx uuid;
begin
  if v_actor is null then raise exception 'unauthorized'; end if;
  if _request_id is null then raise exception 'request_id_required'; end if;
  if _cash_received_iqd is null or _cash_received_iqd < 0 or _cash_received_iqd > 100000000 then
    raise exception 'invalid_cash_received_amount';
  end if;

  select * into v from public.service_requests where id = _request_id for update;
  if not found then raise exception 'request_not_found'; end if;

  v_is_service_member := v.type::text = 'service'
    and public.is_service_request_provider(_request_id, v_actor);
  if v.provider_id is distinct from v_actor and not v_is_service_member then
    raise exception 'forbidden';
  end if;

  if v.status::text = 'completed' then
    if v.cash_settled_at is not null and v.cash_settled_by = v_actor
       and v.cash_received_iqd = _cash_received_iqd then
      return jsonb_build_object(
        'request_id',v.id,
        'fare_iqd',coalesce(v.customer_payable,v.customer_price,v.price_estimate,0)::bigint,
        'cash_received_iqd',v.cash_received_iqd,
        'change_iqd',v.cash_change_iqd,
        'duplicate',true
      );
    end if;
    raise exception 'request_already_completed';
  end if;
  if v.status::text <> 'in_progress' then raise exception 'request_not_in_progress'; end if;

  v_fare_iqd := coalesce(round(v.customer_payable),round(v.customer_price),round(v.price_estimate))::bigint;
  if v_fare_iqd is null or v_fare_iqd < 0 then raise exception 'request_final_fare_unavailable'; end if;

  if v.payment_method in ('zaincash','customer_wallet') then
    if _cash_received_iqd <> 0 then raise exception 'cash_not_expected_for_electronic_payment'; end if;
    v_cash_iqd := 0;
    v_change_iqd := 0;
  else
    if _cash_received_iqd < v_fare_iqd then raise exception 'cash_received_less_than_fare'; end if;
    v_cash_iqd := _cash_received_iqd;
    v_change_iqd := greatest(v_cash_iqd-v_fare_iqd,0);
  end if;

  if v_change_iqd > 0 then
    insert into public.account_wallets(user_id) values (v.customer_id),(v_actor)
    on conflict (user_id) do nothing;
    perform 1 from public.account_wallets
    where user_id in (v.customer_id,v_actor) order by user_id for update;
    select balance_iqd into v_customer_balance from public.account_wallets where user_id=v.customer_id;
    select balance_iqd into v_provider_balance from public.account_wallets where user_id=v_actor;
    v_customer_next := v_customer_balance+v_change_iqd;
    v_provider_next := v_provider_balance-v_change_iqd;
    if v_provider_next < -5000 then raise exception 'provider_wallet_debt_limit_exceeded'; end if;

    insert into public.account_wallet_transactions(
      user_id,transaction_type,amount_iqd,balance_after_iqd,provider,provider_reference,
      idempotency_key,description,metadata
    ) values (
      v.customer_id,'refund',v_change_iqd,v_customer_next,'mamnoon_cash_change',
      'cash-change:'||_request_id::text||':customer','cash-change:'||_request_id::text||':customer',
      'إرجاع باقي مبلغ نقدي لطلب ممنون',
      jsonb_build_object('request_id',_request_id,'provider_id',v_actor,'fare_iqd',v_fare_iqd,
        'cash_received_iqd',v_cash_iqd,'change_iqd',v_change_iqd,'direction','customer_credit')
    ) returning id into v_customer_tx;

    insert into public.account_wallet_transactions(
      user_id,transaction_type,amount_iqd,balance_after_iqd,provider,provider_reference,
      idempotency_key,description,metadata
    ) values (
      v_actor,'deduction',-v_change_iqd,v_provider_next,'mamnoon_cash_change',
      'cash-change:'||_request_id::text||':provider','cash-change:'||_request_id::text||':provider',
      'تسوية باقي نقدي أُضيف إلى محفظة الزبون',
      jsonb_build_object('request_id',_request_id,'customer_id',v.customer_id,'fare_iqd',v_fare_iqd,
        'cash_received_iqd',v_cash_iqd,'change_iqd',v_change_iqd,'direction','provider_debit')
    ) returning id into v_provider_tx;

    update public.account_wallets set balance_iqd=v_customer_next,updated_at=now() where user_id=v.customer_id;
    update public.account_wallets set balance_iqd=v_provider_next,updated_at=now() where user_id=v_actor;
  end if;

  perform set_config('mamnoon.allow_provider_request_transition','true',true);
  update public.service_requests
  set status='completed',completed_at=now(),cash_received_iqd=v_cash_iqd,
      cash_change_iqd=v_change_iqd,cash_settled_by=v_actor,cash_settled_at=now(),updated_at=now()
  where id=_request_id and status='in_progress';
  perform set_config('mamnoon.allow_provider_request_transition','false',true);

  return jsonb_build_object(
    'request_id',_request_id,'fare_iqd',v_fare_iqd,'cash_received_iqd',v_cash_iqd,
    'change_iqd',v_change_iqd,'customer_transaction_id',v_customer_tx,
    'provider_transaction_id',v_provider_tx,'duplicate',false
  );
end;
$function$;

-- Include wallet-paid fares and completed coupon subsidies in the provider's withdrawable company payable.
create or replace function public.admin_get_provider_payables_summary(p_provider_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_provider_governorate text;
  v_scope_type text;
  v_scope_governorate text;
  v_gross bigint := 0;
  v_commission bigint := 0;
  v_coupon_subsidy bigint := 0;
  v_payable bigint := 0;
  v_settled bigint := 0;
begin
  if v_actor is null then raise exception 'unauthorized'; end if;
  if p_provider_id is null then raise exception 'provider_required'; end if;
  select governorate_key into v_provider_governorate from public.profiles where id=p_provider_id;
  if not found then raise exception 'provider_not_found'; end if;
  if not exists(select 1 from public.user_roles where user_id=p_provider_id and role::text in ('driver','worker','large_driver')) then
    raise exception 'provider_account_required';
  end if;

  select scope_type,scope_governorate into v_scope_type,v_scope_governorate
  from public.staff_assignments where user_id=v_actor and active=true order by created_at desc limit 1;
  if v_scope_type='governorate' and v_scope_governorate is distinct from v_provider_governorate then
    raise exception 'provider_outside_finance_scope';
  end if;
  if not (
    public.has_admin_access(v_actor)
    or public.admin_has_permission('finance.read',
      case when v_provider_governorate is null then 'global' else 'governorate' end,
      v_provider_governorate)
  ) then raise exception 'missing_finance_read_permission'; end if;

  select coalesce(sum(q.gross_iqd),0)::bigint,
         coalesce(sum(q.commission_iqd),0)::bigint
  into v_gross,v_commission
  from (
    select sr.id,sum(pt.amount)::bigint gross_iqd,
      least(sum(pt.amount)::bigint,greatest(0,round(coalesce(sr.commission,0)))::bigint) commission_iqd
    from public.service_requests sr
    join public.payment_transactions pt on pt.request_id=sr.id
      and pt.purpose='service_request' and pt.status='paid'
      and pt.provider in ('zaincash','customer_wallet')
      and pt.currency='IQD' and pt.user_id=sr.customer_id
    where sr.provider_id=p_provider_id and sr.status='completed'
      and sr.payment_method in ('zaincash','customer_wallet')
    group by sr.id,sr.commission
  ) q;

  select coalesce(sum(discount_amount),0)::bigint into v_coupon_subsidy
  from public.coupon_subsidy_ledger
  where provider_id=p_provider_id and status='payable';

  v_payable := greatest(v_gross-v_commission,0)+v_coupon_subsidy;
  select coalesce(sum(amount_iqd),0)::bigint into v_settled
  from public.mamnoon_provider_cash_settlements where provider_id=p_provider_id;

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

revoke all on function public.admin_get_provider_payables_summary(uuid) from public,anon,authenticated;
grant execute on function public.admin_get_provider_payables_summary(uuid) to authenticated;

-- Make finance settlement validation use the exact same net-wallet + coupon-subsidy basis.
create or replace function public.admin_get_provider_payables_summary(p_provider_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_provider_governorate text;
  v_scope_type text;
  v_scope_governorate text;
  v_gross bigint := 0;
  v_commission bigint := 0;
  v_coupon_subsidy bigint := 0;
  v_payable bigint := 0;
  v_settled bigint := 0;
begin
  if v_actor is null then raise exception 'unauthorized'; end if;
  if p_provider_id is null then raise exception 'provider_required'; end if;
  select governorate_key into v_provider_governorate from public.profiles where id=p_provider_id;
  if not found then raise exception 'provider_not_found'; end if;
  if not exists(select 1 from public.user_roles where user_id=p_provider_id and role::text in ('driver','worker','large_driver')) then
    raise exception 'provider_account_required';
  end if;
  select scope_type,scope_governorate into v_scope_type,v_scope_governorate
  from public.staff_assignments where user_id=v_actor and active=true order by created_at desc limit 1;
  if v_scope_type='governorate' and v_scope_governorate is distinct from v_provider_governorate then
    raise exception 'provider_outside_finance_scope';
  end if;
  if not (public.has_admin_access(v_actor) or public.admin_has_permission('finance.read',
    case when v_provider_governorate is null then 'global' else 'governorate' end,v_provider_governorate)) then
    raise exception 'missing_finance_read_permission';
  end if;

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
    where sr.provider_id=p_provider_id and sr.status='completed'
      and sr.payment_method in ('zaincash','customer_wallet')
    group by sr.id,sr.commission
  ) p
  left join (
    select request_id,sum(discount_amount)::bigint subsidy_iqd
    from public.coupon_subsidy_ledger
    where provider_id=p_provider_id and status='payable'
    group by request_id
  ) c on c.request_id=p.id;

  select coalesce(sum(discount_amount),0)::bigint into v_coupon_subsidy
  from public.coupon_subsidy_ledger where provider_id=p_provider_id and status='payable';
  v_payable := greatest(0,v_gross+v_coupon_subsidy-v_commission);
  select coalesce(sum(amount_iqd),0)::bigint into v_settled
  from public.mamnoon_provider_cash_settlements where provider_id=p_provider_id;
  return jsonb_build_object(
    'gross_paid_iqd',v_gross,'commission_iqd',v_commission,
    'coupon_subsidy_iqd',v_coupon_subsidy,'payable_iqd',v_payable,
    'settled_iqd',v_settled,'outstanding_iqd',greatest(0,v_payable-v_settled),
    'over_settled_iqd',greatest(0,v_settled-v_payable)
  );
end;
$function$;

create or replace function public.admin_record_provider_cash_settlement(
  p_provider_id uuid,p_amount_iqd bigint,p_note text,p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_governorate text;
  v_scope_type text;
  v_scope_governorate text;
  v_existing public.mamnoon_provider_cash_settlements%rowtype;
  v_payable_total bigint := 0;
  v_settled_total bigint := 0;
  v_outstanding bigint := 0;
  v_settlement_id uuid;
begin
  if v_actor is null then raise exception 'unauthorized'; end if;
  if p_provider_id is null then raise exception 'provider_required'; end if;
  if p_amount_iqd is null or p_amount_iqd<=0 or p_amount_iqd>1000000000 then raise exception 'invalid_settlement_amount'; end if;
  if p_note is null or length(btrim(p_note)) not between 2 and 500 then raise exception 'settlement_note_required'; end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) not between 8 and 200 then raise exception 'valid_idempotency_key_required'; end if;

  select governorate_key into v_governorate from public.profiles where id=p_provider_id;
  if not found then raise exception 'provider_not_found'; end if;
  if not exists(select 1 from public.user_roles where user_id=p_provider_id and role::text in ('driver','worker','large_driver')) then
    raise exception 'provider_account_required';
  end if;
  select scope_type,scope_governorate into v_scope_type,v_scope_governorate
  from public.staff_assignments where user_id=v_actor and active=true order by created_at desc limit 1;
  if v_scope_type='governorate' and v_scope_governorate is distinct from v_governorate then
    raise exception 'provider_outside_finance_scope';
  end if;
  if not (public.has_admin_access(v_actor) or public.admin_has_permission('finance.wallet.adjust',
    case when v_governorate is null then 'global' else 'governorate' end,v_governorate)) then
    raise exception 'missing_finance_wallet_permission';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_provider_id::text,913578));
  select * into v_existing from public.mamnoon_provider_cash_settlements
  where idempotency_key=p_idempotency_key for update;
  if found then
    if v_existing.provider_id<>p_provider_id or v_existing.amount_iqd<>p_amount_iqd or v_existing.note<>btrim(p_note) then
      raise exception 'settlement_idempotency_conflict';
    end if;
    return jsonb_build_object('settlement_id',v_existing.id,'amount_iqd',v_existing.amount_iqd,'duplicate',true);
  end if;

  select coalesce(sum(greatest(p.cash_iqd+coalesce(c.subsidy_iqd,0)-least(
           p.cash_iqd+coalesce(c.subsidy_iqd,0),greatest(0,round(coalesce(p.commission,0)))::bigint
         ),0)),0)::bigint
  into v_payable_total
  from (
    select sr.id,sr.commission,sum(pt.amount)::bigint cash_iqd
    from public.service_requests sr
    join public.payment_transactions pt on pt.request_id=sr.id
      and pt.purpose='service_request' and pt.status='paid'
      and pt.provider in ('zaincash','customer_wallet') and pt.currency='IQD'
      and pt.user_id=sr.customer_id
    where sr.provider_id=p_provider_id and sr.status='completed'
      and sr.payment_method in ('zaincash','customer_wallet')
    group by sr.id,sr.commission
  ) p
  left join (
    select request_id,sum(discount_amount)::bigint subsidy_iqd
    from public.coupon_subsidy_ledger where provider_id=p_provider_id and status='payable'
    group by request_id
  ) c on c.request_id=p.id;

  select coalesce(sum(amount_iqd),0)::bigint into v_settled_total
  from public.mamnoon_provider_cash_settlements where provider_id=p_provider_id;
  v_outstanding:=v_payable_total-v_settled_total;
  if v_outstanding<=0 or p_amount_iqd>v_outstanding then raise exception 'settlement_exceeds_provider_payable'; end if;

  insert into public.mamnoon_provider_cash_settlements(provider_id,amount_iqd,note,idempotency_key,created_by)
  values(p_provider_id,p_amount_iqd,btrim(p_note),p_idempotency_key,v_actor)
  returning id into v_settlement_id;
  perform public.log_admin_action('record_provider_cash_settlement','provider',p_provider_id::text,
    jsonb_build_object('settlement_id',v_settlement_id,'amount_iqd',p_amount_iqd,'note',btrim(p_note),
      'outstanding_before_iqd',v_outstanding,'outstanding_after_iqd',v_outstanding-p_amount_iqd));
  return jsonb_build_object('settlement_id',v_settlement_id,'amount_iqd',p_amount_iqd,
    'outstanding_after_iqd',v_outstanding-p_amount_iqd,'duplicate',false);
end;
$function$;
