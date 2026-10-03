-- AgruPay v14 · «Te deben»: la pestaña Cobros de Social, del lado de quien cobra.
--
-- v12 dejó las deudas (`debt_shares`) del lado de quien debe. Aquí se añade lo
-- que necesita quien cobra para verlas y cerrarlas:
--
--   payment_reminder_sends          cada día en que le cobraste (el historial
--                                   «15 sept · 22 sept · hoy»). `payment_reminders`
--                                   se renueva en su sitio y sólo guarda el último.
--   debt_shares.status              + 'forgiven' (perdonada, se le avisa) y
--                                   'archived' (quitada de tu lista, sin avisar)
--   list_my_receivables()           lo que me deben, abierto y cerrado hace poco
--   creditor_record_payment(...)    «Registrar pago»: me pagó por fuera (efectivo,
--                                   un Yape cuyo correo no me llegó)
--   close_debt_share(id, status)    perdonar o archivar
--
-- Requiere v10 (recordatorios) y v12 (deudas). Se puede correr más de una vez.

-- ── Historial de cobros ───────────────────────────────────────────────

create table if not exists public.payment_reminder_sends (
  id uuid primary key default gen_random_uuid(),
  from_user uuid not null references auth.users(id) on delete cascade,
  to_user uuid not null references auth.users(id) on delete cascade,
  debt_key text not null,
  sent_on date not null,
  created_at timestamptz not null default now()
);

-- Uno por día: el tope de `send_payment_reminders` ya lo garantiza, esto sólo
-- evita duplicados si el disparador corre dos veces.
create unique index if not exists payment_reminder_sends_day_idx
  on public.payment_reminder_sends (from_user, to_user, debt_key, sent_on);

alter table public.payment_reminder_sends enable row level security;

drop policy if exists payment_reminder_sends_read on public.payment_reminder_sends;
create policy payment_reminder_sends_read on public.payment_reminder_sends
  for select to authenticated
  using (from_user = auth.uid() or to_user = auth.uid());

create or replace function public.log_payment_reminder_send()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.payment_reminder_sends (from_user, to_user, debt_key, sent_on)
  values (new.from_user, new.to_user, new.debt_key, new.sent_on)
  on conflict (from_user, to_user, debt_key, sent_on) do nothing;
  return new;
end;
$$;

drop trigger if exists payment_reminders_log_send on public.payment_reminders;
create trigger payment_reminders_log_send
  after insert or update of sent_on on public.payment_reminders
  for each row execute function public.log_payment_reminder_send();

-- Lo que ya estaba: sólo se conoce el último día de cada recordatorio.
insert into public.payment_reminder_sends (from_user, to_user, debt_key, sent_on, created_at)
select from_user, to_user, debt_key, sent_on, created_at
from public.payment_reminders
on conflict (from_user, to_user, debt_key, sent_on) do nothing;

-- ── Perdonar y archivar ───────────────────────────────────────────────

-- El check de v12 puede tener otro nombre según cómo se creó la tabla: se
-- borra cualquier check de `debt_shares` que hable de `status`.
do $$
declare
  v_name text;
begin
  for v_name in
    select conname from pg_constraint
     where conrelid = 'public.debt_shares'::regclass and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute format('alter table public.debt_shares drop constraint %I', v_name);
  end loop;
end;
$$;
alter table public.debt_shares add constraint debt_shares_status_check
  check (status in ('open', 'paid', 'forgiven', 'archived'));
alter table public.debt_shares add column if not exists closed_at timestamptz;

-- Igual que en v12, pero respeta lo que cerró quien cobra: una perdonada no se
-- reabre, y una archivada sólo pasa a pagada si de verdad se pagó.
create or replace function public.recompute_debt_share(p_share_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_paid numeric(14,2);
  v_share public.debt_shares%rowtype;
begin
  select coalesce(sum(amount), 0) into v_paid from public.debt_payments where share_id = p_share_id;
  select * into v_share from public.debt_shares where id = p_share_id;
  if not found then return; end if;

  update public.debt_shares
     set paid_amount = v_paid,
         status = case
           when status = 'forgiven' then 'forgiven'
           when v_paid >= amount then 'paid'
           when status = 'archived' then 'archived'
           else 'open' end,
         paid_at = case when v_paid >= amount then coalesce(paid_at, now()) else null end,
         updated_at = now()
   where id = p_share_id;

  if v_paid >= v_share.amount then
    update public.payment_reminders
       set dismissed_at = now()
     where from_user = v_share.creditor and to_user = v_share.debtor
       and debt_key = v_share.debt_key and dismissed_at is null;
  end if;
end;
$$;

revoke all on function public.recompute_debt_share(uuid) from public, anon, authenticated;

-- Volver a cobrar una deuda archivada la devuelve a tu lista.
create or replace function public.debt_share_from_reminder()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.amount is null or new.amount <= 0 then
    return new;
  end if;

  insert into public.debt_shares
    (creditor, debtor, debt_key, merchant, occurred_on, amount, currency)
  values
    (new.from_user, new.to_user, new.debt_key, new.merchant, new.occurred_on,
     new.amount, new.currency)
  on conflict (creditor, debtor, debt_key) do update
    set amount = case when debt_shares.status in ('open', 'archived') then excluded.amount else debt_shares.amount end,
        status = case when debt_shares.status = 'archived' then 'open' else debt_shares.status end,
        closed_at = case when debt_shares.status = 'archived' then null else debt_shares.closed_at end,
        merchant = excluded.merchant,
        occurred_on = excluded.occurred_on,
        currency = excluded.currency,
        updated_at = now();
  return new;
end;
$$;

-- Quien debe ve la perdonada (para enterarse) y no ve la archivada como
-- cerrada: «sin avisar» es eso.
drop function if exists public.list_my_debts();
create or replace function public.list_my_debts()
returns table (
  id uuid, creditor uuid, debt_key text, merchant text, occurred_on date,
  amount numeric, currency text, paid_amount numeric, status text,
  created_at timestamptz, paid_at timestamptz, closed_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.creditor, s.debt_key, s.merchant, s.occurred_on,
         s.amount, s.currency, s.paid_amount,
         case when s.status = 'archived' then 'open' else s.status end,
         s.created_at, s.paid_at,
         case when s.status = 'forgiven' then s.closed_at else null end
  from public.debt_shares s
  where s.debtor = auth.uid()
    and public.is_friend(s.creditor)
    and (s.status in ('open', 'archived')
         or s.paid_at > now() - interval '30 days'
         or (s.status = 'forgiven' and s.closed_at > now() - interval '30 days'))
  order by s.created_at desc;
$$;

revoke all on function public.list_my_debts() from public, anon;
grant execute on function public.list_my_debts() to authenticated;

-- ── Lo que me deben ───────────────────────────────────────────────────

-- Abiertas, y las cerradas en los últimos 90 días («Cobros cerrados»).
create or replace function public.list_my_receivables()
returns table (
  id uuid, debtor uuid, debt_key text, merchant text, occurred_on date,
  amount numeric, currency text, paid_amount numeric, status text,
  created_at timestamptz, paid_at timestamptz, closed_at timestamptz,
  last_via text, reminder_dates date[]
)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.debtor, s.debt_key, s.merchant, s.occurred_on,
         s.amount, s.currency, s.paid_amount, s.status,
         s.created_at, s.paid_at, s.closed_at,
         (select p.via from public.debt_payments p
           where p.share_id = s.id order by p.paid_at desc limit 1),
         coalesce((select array_agg(r.sent_on order by r.sent_on)
                     from public.payment_reminder_sends r
                    where r.from_user = s.creditor and r.to_user = s.debtor
                      and r.debt_key = s.debt_key), array[]::date[])
  from public.debt_shares s
  where s.creditor = auth.uid()
    and (s.status = 'open'
         or coalesce(s.closed_at, s.paid_at) > now() - interval '90 days')
  order by s.created_at desc;
$$;

revoke all on function public.list_my_receivables() from public, anon;
grant execute on function public.list_my_receivables() to authenticated;

-- «Registrar pago»: quien cobra anota lo que le pagaron por fuera. Entra ya
-- visto (`creditor_seen_at`): el ingreso lo crea su propio teléfono al
-- registrarlo, así que `list_incoming_debt_payments` no lo vuelve a traer.
create or replace function public.creditor_record_payment(p_share_id uuid, p_amount numeric)
returns table (status text, paid_amount numeric, remaining numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.require_google_user();
  v_share public.debt_shares%rowtype;
  v_amount numeric(14,2);
begin
  select * into v_share from public.debt_shares where id = p_share_id and creditor = v_user;
  if not found then
    raise exception 'Esa deuda no es tuya';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'El monto tiene que ser mayor que cero';
  end if;
  if v_share.status not in ('open', 'archived') or v_share.paid_amount >= v_share.amount then
    status := v_share.status; paid_amount := v_share.paid_amount; remaining := 0;
    return next; return;
  end if;

  v_amount := least(p_amount, v_share.amount - v_share.paid_amount);
  insert into public.debt_payments (share_id, amount, paid_at, via, source_key, creditor_seen_at)
  values (p_share_id, v_amount, now(), 'creditor', 'creditor:' || gen_random_uuid()::text, now());

  perform public.recompute_debt_share(p_share_id);
  select * into v_share from public.debt_shares where id = p_share_id;

  status := v_share.status;
  paid_amount := v_share.paid_amount;
  remaining := greatest(v_share.amount - v_share.paid_amount, 0);
  return next;
end;
$$;

revoke all on function public.creditor_record_payment(uuid, numeric) from public, anon;
grant execute on function public.creditor_record_payment(uuid, numeric) to authenticated;

-- Perdonar (se le avisa: le sale en «Lo que debes» y se le cierra el
-- recordatorio abierto) o archivar (sólo deja de verse en tu lista).
create or replace function public.close_debt_share(p_share_id uuid, p_status text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.require_google_user();
  v_share public.debt_shares%rowtype;
begin
  if p_status not in ('forgiven', 'archived') then
    raise exception 'Estado inválido';
  end if;
  select * into v_share from public.debt_shares where id = p_share_id and creditor = v_user;
  if not found then
    raise exception 'Esa deuda no es tuya';
  end if;
  if v_share.status not in ('open', 'archived') then
    return false;
  end if;

  update public.debt_shares
     set status = p_status, closed_at = now(), updated_at = now()
   where id = p_share_id;

  if p_status = 'forgiven' then
    update public.payment_reminders
       set dismissed_at = now()
     where from_user = v_share.creditor and to_user = v_share.debtor
       and debt_key = v_share.debt_key and dismissed_at is null;
  end if;
  return true;
end;
$$;

revoke all on function public.close_debt_share(uuid, text) from public, anon;
grant execute on function public.close_debt_share(uuid, text) to authenticated;

-- Que la API vea las funciones nuevas sin esperar.
notify pgrst, 'reload schema';
