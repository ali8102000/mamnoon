-- Provider cancellation penalties: configurable, wallet-backed, idempotent.
-- Defaults are disabled until an administrator explicitly enables and configures them.
create table if not exists public.provider_cancellation_penalty_settings (
  id boolean primary key default true check (id),
  enabled boolean not null default false,
  grace_minutes integer not null default 5 check (grace_minutes between 1 and 1440),
  penalty_percent numeric(5,2) not null default 10 check (penalty_percent between 0 and 100),
  updated_by uuid,
  updated_at timestamptz not null default now()
);

insert into public.provider_cancellation_penalty_settings(id, enabled, grace_minutes, penalty_percent)
values (true, false, 5, 10)
on conflict (id) do nothing;

alter table public.provider_cancellation_penalty_settings enable row level security;
drop policy if exists provider_cancellation_penalty_settings_read on public.provider_cancellation_penalty_settings;
create policy provider_cancellation_penalty_settings_read
on public.provider_cancellation_penalty_settings
for select to authenticated
using (true);
revoke insert, update, delete on public.provider_cancellation_penalty_settings from anon, authenticated;

create or replace function public.admin_update_provider_cancellation_penalty_settings(
  p_enabled boolean,
  p_grace_minutes integer,
  p_penalty_percent numeric
) returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_row public.provider_cancellation_penalty_settings%rowtype;
begin
  if auth.uid() is null or not public.has_admin_access(auth.uid()) then
    raise exception 'forbidden';
  end if;
  if p_grace_minutes is null or p_grace_minutes not between 1 and 1440 then
    raise exception 'invalid_grace_minutes';
  end if;
  if p_penalty_percent is null or p_penalty_percent < 0 or p_penalty_percent > 100 then
    raise exception 'invalid_penalty_percent';
  end if;

  insert into public.provider_cancellation_penalty_settings(
    id, enabled, grace_minutes, penalty_percent, updated_by, updated_at
  ) values (true, p_enabled, p_grace_minutes, p_penalty_percent, auth.uid(), now())
  on conflict (id) do update set
    enabled = excluded.enabled,
    grace_minutes = excluded.grace_minutes,
    penalty_percent = excluded.penalty_percent,
    updated_by = excluded.updated_by,
    updated_at = now()
  returning * into v_row;

  return jsonb_build_object(
    'enabled', v_row.enabled,
    'grace_minutes', v_row.grace_minutes,
    'penalty_percent', v_row.penalty_percent,
    'updated_at', v_row.updated_at
  );
end;
$function$;

create or replace function public.get_provider_cancellation_penalty_preview(_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  r public.service_requests%rowtype;
  s public.provider_cancellation_penalty_settings%rowtype;
  v_elapsed numeric;
  v_rate numeric;
  v_base numeric;
  v_amount bigint;
  v_balance bigint;
  v_provider uuid := auth.uid();
begin
  if v_provider is null then raise exception 'unauthorized'; end if;
  select * into r from public.service_requests where id = _request_id;
  if not found then raise exception 'request_not_found'; end if;
  if r.provider_id is distinct from v_provider
     and not (r.type::text = 'service' and public.is_service_request_provider(_request_id, v_provider)) then
    raise exception 'forbidden';
  end if;
  select * into s from public.provider_cancellation_penalty_settings where id = true;
  if not found then
    s.enabled := false; s.grace_minutes := 5; s.penalty_percent := 10;
  end if;
  v_elapsed := greatest(0, extract(epoch from (now() - coalesce(r.accepted_at, r.created_at))) / 60.0);
  v_rate := case
    when not coalesce(s.enabled, false) then 0
    when v_elapsed <= s.grace_minutes then s.penalty_percent / 2
    else s.penalty_percent
  end;
  v_base := greatest(0, coalesce(r.customer_payable, r.customer_price, r.price_estimate, 0));
  v_amount := round(v_base * v_rate / 100.0)::bigint;
  select balance_iqd into v_balance from public.account_wallets where user_id = v_provider;
  return jsonb_build_object(
    'enabled', coalesce(s.enabled, false),
    'elapsed_minutes', round(v_elapsed, 2),
    'grace_minutes', coalesce(s.grace_minutes, 5),
    'penalty_percent', coalesce(s.penalty_percent, 10),
    'applied_percent', v_rate,
    'base_amount_iqd', round(v_base)::bigint,
    'penalty_amount_iqd', v_amount,
    'wallet_balance_iqd', coalesce(v_balance, 0),
    'stage', case when v_rate = 0 then 'disabled' when v_elapsed <= coalesce(s.grace_minutes,5) then 'half' else 'full' end
  );
end;
$function$;

create table if not exists public.provider_cancellation_penalty_ledger (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.service_requests(id) on delete restrict,
  provider_id uuid not null references auth.users(id) on delete restrict,
  assessed_iqd bigint not null check (assessed_iqd >= 0),
  collected_iqd bigint not null default 0 check (collected_iqd >= 0 and collected_iqd <= assessed_iqd),
  outstanding_iqd bigint not null default 0 check (outstanding_iqd >= 0),
  applied_percent numeric(5,2) not null,
  elapsed_minutes numeric(10,2) not null,
  grace_minutes integer not null,
  status text not null check (status in ('collected','partially_collected','accrued')),
  idempotency_key text not null unique,
  wallet_transaction_id uuid references public.account_wallet_transactions(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (request_id, provider_id)
);
create index if not exists provider_cancellation_penalty_provider_created_idx
  on public.provider_cancellation_penalty_ledger(provider_id, created_at desc);
alter table public.provider_cancellation_penalty_ledger enable row level security;
drop policy if exists provider_cancellation_penalty_ledger_read_own on public.provider_cancellation_penalty_ledger;
create policy provider_cancellation_penalty_ledger_read_own
  on public.provider_cancellation_penalty_ledger for select to authenticated
  using (provider_id = auth.uid() or public.has_admin_access(auth.uid()));
revoke insert, update, delete on public.provider_cancellation_penalty_ledger from anon, authenticated;

create or replace function public.apply_provider_cancellation_penalty()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  s public.provider_cancellation_penalty_settings%rowtype;
  v_provider uuid := new.cancelled_by;
  v_elapsed numeric;
  v_rate numeric;
  v_base numeric;
  v_assessed bigint;
  v_balance bigint;
  v_debit bigint;
  v_after bigint;
  v_key text;
  v_role boolean;
begin
  if new.cancelled_by is null
     or new.cancelled_by is not distinct from old.cancelled_by
     or new.cancelled_by = new.customer_id then
    return new;
  end if;

  select exists (
    select 1 from public.user_roles
    where user_id = v_provider and role::text in ('driver','large_driver','worker')
  ) into v_role;
  if not v_role then return new; end if;

  select * into s from public.provider_cancellation_penalty_settings where id = true;
  if not found or not s.enabled or s.penalty_percent <= 0 then return new; end if;

  v_elapsed := greatest(0, extract(epoch from (now() - coalesce(old.accepted_at, old.created_at))) / 60.0);
  v_rate := case when v_elapsed <= s.grace_minutes then s.penalty_percent / 2 else s.penalty_percent end;
  v_base := greatest(0, coalesce(old.customer_payable, old.customer_price, old.price_estimate, 0));
  v_assessed := round(v_base * v_rate / 100.0)::bigint;
  if v_assessed <= 0 then return new; end if;

  v_key := 'provider_cancel:' || old.id::text || ':' || v_provider::text;
  if exists (select 1 from public.provider_cancellation_penalty_ledger where idempotency_key = v_key) then
    return new;
  end if;

  insert into public.account_wallets(user_id) values (v_provider)
  on conflict (user_id) do nothing;
  select balance_iqd into v_balance
  from public.account_wallets where user_id = v_provider for update;

  -- Respect the existing provider wallet debt ceiling (-5,000 IQD).
  v_debit := least(v_assessed, greatest(0, v_balance + 5000));
  v_after := v_balance - v_debit;

  if v_debit > 0 then
    insert into public.account_wallet_transactions(
      user_id, transaction_type, amount_iqd, balance_after_iqd,
      provider, provider_reference, idempotency_key, description, metadata
    ) values (
      v_provider, 'provider_cancellation_penalty', -v_debit, v_after,
      'mamnoon', v_key, v_key,
      'غرامة إلغاء مقدم الخدمة للطلب ' || coalesce(old.request_code, old.id::text),
      jsonb_build_object(
        'request_id', old.id, 'request_code', old.request_code,
        'assessed_iqd', v_assessed, 'collected_iqd', v_debit,
        'applied_percent', v_rate, 'elapsed_minutes', round(v_elapsed,2),
        'grace_minutes', s.grace_minutes
      )
    );
    update public.account_wallets
    set balance_iqd = v_after, updated_at = now()
    where user_id = v_provider;
  end if;

  insert into public.provider_cancellation_penalty_ledger(
    request_id, provider_id, assessed_iqd, collected_iqd, outstanding_iqd,
    applied_percent, elapsed_minutes, grace_minutes, status, idempotency_key,
    wallet_transaction_id, metadata
  ) values (
    old.id, v_provider, v_assessed, v_debit, v_assessed - v_debit,
    v_rate, round(v_elapsed,2), s.grace_minutes,
    case when v_debit >= v_assessed then 'collected'
         when v_debit > 0 then 'partially_collected'
         else 'accrued' end,
    v_key,
    (select id from public.account_wallet_transactions where idempotency_key = v_key),
    jsonb_build_object('request_code', old.request_code)
  );

  insert into public.notifications(user_id, type, title, body, link, data)
  values (
    v_provider, 'provider_cancellation_penalty',
    'تم احتساب غرامة إلغاء',
    'تم احتساب غرامة بمبلغ ' || v_assessed::text || ' د.ع على إلغاء الطلب. المخصوم من المحفظة: ' ||
      v_debit::text || ' د.ع.',
    '/wallet',
    jsonb_build_object(
      'request_id', old.id, 'request_code', old.request_code,
      'assessed_iqd', v_assessed, 'collected_iqd', v_debit,
      'outstanding_iqd', v_assessed - v_debit, 'applied_percent', v_rate
    )
  );

  return new;
end;
$function$;

drop trigger if exists trg_provider_cancellation_penalty on public.service_requests;
create trigger trg_provider_cancellation_penalty
after update of cancelled_by on public.service_requests
for each row
when (new.cancelled_by is not null and new.cancelled_by is distinct from old.cancelled_by)
execute function public.apply_provider_cancellation_penalty();

revoke all on function public.apply_provider_cancellation_penalty() from public, anon, authenticated;
grant execute on function public.get_provider_cancellation_penalty_preview(uuid) to authenticated;
grant execute on function public.admin_update_provider_cancellation_penalty_settings(boolean, integer, numeric) to authenticated;
