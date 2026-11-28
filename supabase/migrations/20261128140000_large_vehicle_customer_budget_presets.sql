-- Restrict large-vehicle customer budgets to the nine approved presets.
-- Provider offers are handled separately by submit_large_vehicle_offer (5,000 IQD steps up to 500,000).
create or replace function public.guard_large_vehicle_customer_price()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  if current_setting('mamnoon.allow_request_urgency', true) = 'true' then
    return new;
  end if;

  if new.type::text = 'taxi'
     and new.vehicle_category::text = 'large'
     and new.customer_price is not null
     and new.customer_price not in (15000, 25000, 35000, 50000, 60000, 75000, 100000, 125000, 150000) then
    raise exception 'ميزانية الزبون يجب أن تكون واحدة من الاختصارات المتاحة';
  end if;

  return new;
end;
$function$;
