-- ============================================================
-- AgruPay · Deudas entre amigos v12 — «ya te pagué» sin tocar nada
-- ============================================================
-- Corre esto DESPUÉS de v11. Idempotente. Es una prueba de concepto.
--
-- La idea: a quien cobra casi nunca le llega el correo del Yape que recibe,
-- pero a quien paga siempre le llega el de su Yape enviado. Así que el pago lo
-- detecta el teléfono **del que paga** y se lo cuenta al servidor, y el
-- servidor se lo cuenta a quien cobró.
--
-- Qué añade
-- 1. `debt_shares`: la parte de una deuda que le toca a un amigo («Vale te
--    debe S/ 50 de la pizza»). Hasta v11 el recordatorio era sólo un recado;
--    ahora, cuando lleva monto, deja además una deuda abierta que no
--    desaparece aunque el amigo cierre el recordatorio. La crea un trigger
--    sobre `payment_reminders`: el teléfono de quien cobra no cambia nada.
-- 2. `debt_payments`: cada pago que el deudor declara (a mano o porque su
--    teléfono emparejó su Yape enviado con la deuda). Un pago por gasto del
--    deudor (`source_key`): releer el correo no paga dos veces.
-- 3. RPCs:
--      list_my_debts()                 lo que yo debo (abierto y lo recién pagado)
--      pay_debt_share(...)             «esto que yapeé era para esta deuda»
--      undo_debt_payment(id)           deshacer, mientras quien cobra no lo vea
--      list_incoming_debt_payments()   lo que me pagaron y mi teléfono no anotó
--      ack_debt_payments(ids)          mi teléfono ya lo anotó como ingreso
--
-- Al servidor sólo sube «pagó S/ X de la deuda Y»: ni el correo, ni el nombre
-- del destinatario, ni ningún otro gasto de quien paga.

-- ── Partes de deuda ────────────────────────────────────────────────────

create table if not exists public.debt_shares (
  id uuid primary key default gen_random_uuid(),
  creditor uuid not null references auth.users(id) on delete cascade,
  debtor uuid not null references auth.users(id) on delete cascade,
  -- La misma llave que `payment_reminders.debt_key`: el gasto en el teléfono
  -- de quien cobra (`TransactionKey`).
  debt_key text not null,
  merchant text not null,
  occurred_on date,
  amount numeric(14,2) not null check (amount > 0),
  currency text not null default 'PEN',
  paid_amount numeric(14,2) not null default 0,
  status text not null default 'open' check (status in ('open', 'paid')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  paid_at timestamptz
);

create unique index if not exists debt_shares_unique_idx
  on public.debt_shares (creditor, debtor, debt_key);
create index if not exists debt_shares_debtor_idx on public.debt_shares (debtor, status);

alter table public.debt_shares enable row level security;

drop policy if exists debt_shares_read on public.debt_shares;
create policy debt_shares_read on public.debt_shares
  for select to authenticated
  using (creditor = auth.uid() or debtor = auth.uid());

-- ── Pagos ──────────────────────────────────────────────────────────────

create table if not exists public.debt_payments (
  id uuid primary key default gen_random_uuid(),
  share_id uuid not null references public.debt_shares(id) on delete cascade,
  amount numeric(14,2) not null check (amount > 0),
  paid_at timestamptz not null default now(),
  -- 'Yape', 'Plin', 'BBVA'… o 'manual' si el deudor lo marcó sin correo.
  via text not null default 'manual',
  -- El gasto del deudor que lo pagó (su `TransactionKey`), o un id al azar
  -- si fue a mano. Sólo lo lee el propio deudor.
  source_key text not null,
  created_at timestamptz not null default now(),
  -- El teléfono de quien cobra ya lo anotó como ingreso.
  creditor_seen_at timestamptz
);

create unique index if not exists debt_payments_source_idx
  on public.debt_payments (share_id, source_key);
create index if not exists debt_payments_share_idx on public.debt_payments (share_id);

alter table public.debt_payments enable row level security;

drop policy if exists debt_payments_read on public.debt_payments;
create policy debt_payments_read on public.debt_payments
  for select to authenticated
  using (exists (
    select 1 from public.debt_shares s
    where s.id = share_id and (s.creditor = auth.uid() or s.debtor = auth.uid())
  ));

-- Sin insert ni update directos: todo pasa por las funciones de abajo.

-- ── Del recordatorio a la deuda ────────────────────────────────────────

-- Un recordatorio **con monto** abre (o ajusta) la parte de ese amigo. Uno sin
-- monto no toca nada: «ya sabes de cuánto es» no es una deuda que se pueda
-- saldar sola.
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
    -- Una deuda ya pagada no se reabre porque llegue otro recordatorio.
    set amount = case when debt_shares.status = 'open' then excluded.amount else debt_shares.amount end,
        merchant = excluded.merchant,
        occurred_on = excluded.occurred_on,
        currency = excluded.currency,
        updated_at = now();
  return new;
end;
$$;

drop trigger if exists payment_reminders_debt_share on public.payment_reminders;
create trigger payment_reminders_debt_share
  after insert or update of amount on public.payment_reminders
  for each row execute function public.debt_share_from_reminder();

-- Los recordatorios con monto que ya estaban abiertos también cuentan.
insert into public.debt_shares
  (creditor, debtor, debt_key, merchant, occurred_on, amount, currency, created_at)
select from_user, to_user, debt_key, merchant, occurred_on, amount, currency, created_at
from public.payment_reminders
where amount is not null and amount > 0 and dismissed_at is null
on conflict (creditor, debtor, debt_key) do nothing;

-- ── Lo que yo debo ─────────────────────────────────────────────────────

-- Abiertas, y las pagadas en los últimos 30 días (para enseñar «pagada» y
-- poder deshacer).
create or replace function public.list_my_debts()
returns table (
  id uuid, creditor uuid, debt_key text, merchant text, occurred_on date,
  amount numeric, currency text, paid_amount numeric, status text,
  created_at timestamptz, paid_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.creditor, s.debt_key, s.merchant, s.occurred_on,
         s.amount, s.currency, s.paid_amount, s.status, s.created_at, s.paid_at
  from public.debt_shares s
  where s.debtor = auth.uid()
    and public.is_friend(s.creditor)
    and (s.status = 'open' or s.paid_at > now() - interval '30 days')
  order by s.created_at desc;
$$;

revoke all on function public.list_my_debts() from public, anon;
grant execute on function public.list_my_debts() to authenticated;

-- Vuelve a sumar los pagos de una parte y la cierra o la reabre.
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
         status = case when v_paid >= amount then 'paid' else 'open' end,
         paid_at = case when v_paid >= amount then coalesce(paid_at, now()) else null end,
         updated_at = now()
   where id = p_share_id;

  -- Pagada: el recordatorio ya no tiene nada que recordar.
  if v_paid >= v_share.amount then
    update public.payment_reminders
       set dismissed_at = now()
     where from_user = v_share.creditor and to_user = v_share.debtor
       and debt_key = v_share.debt_key and dismissed_at is null;
  end if;
end;
$$;

revoke all on function public.recompute_debt_share(uuid) from public, anon, authenticated;

-- «Este Yape era para esta deuda.» Lo llama el teléfono de quien paga.
--
-- El monto se recorta a lo que falta: un Yape de S/ 60 para una deuda de
-- S/ 50 salda la deuda y nada más (el resto no es asunto de esta deuda).
--
-- Devuelve:
--   paid            la deuda quedó saldada
--   partial         abonó, todavía falta
--   already_paid    no quedaba nada por pagar
--   duplicate       ese mismo gasto ya estaba registrado para esta deuda
create or replace function public.pay_debt_share(
  p_share_id uuid,
  p_amount numeric,
  p_source_key text,
  p_paid_at timestamptz default now(),
  p_via text default 'manual'
)
returns table (status text, payment_id uuid, paid_amount numeric, remaining numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.require_google_user();
  v_share public.debt_shares%rowtype;
  v_amount numeric(14,2);
  v_id uuid;
begin
  select * into v_share from public.debt_shares where id = p_share_id and debtor = v_user;
  if not found then
    raise exception 'Esa deuda no es tuya';
  end if;
  if coalesce(trim(p_source_key), '') = '' then
    raise exception 'Falta de qué gasto sale el pago';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'El monto tiene que ser mayor que cero';
  end if;

  if v_share.status = 'paid' or v_share.paid_amount >= v_share.amount then
    status := 'already_paid'; payment_id := null;
    paid_amount := v_share.paid_amount; remaining := 0;
    return next; return;
  end if;

  v_amount := least(p_amount, v_share.amount - v_share.paid_amount);

  insert into public.debt_payments (share_id, amount, paid_at, via, source_key)
  values (p_share_id, v_amount, coalesce(p_paid_at, now()),
          left(coalesce(nullif(trim(p_via), ''), 'manual'), 20), left(trim(p_source_key), 200))
  on conflict (share_id, source_key) do nothing
  returning id into v_id;

  if v_id is null then
    status := 'duplicate'; payment_id := null;
    paid_amount := v_share.paid_amount; remaining := v_share.amount - v_share.paid_amount;
    return next; return;
  end if;

  perform public.recompute_debt_share(p_share_id);
  select * into v_share from public.debt_shares where id = p_share_id;

  status := case when v_share.status = 'paid' then 'paid' else 'partial' end;
  payment_id := v_id;
  paid_amount := v_share.paid_amount;
  remaining := greatest(v_share.amount - v_share.paid_amount, 0);
  return next;
end;
$$;

revoke all on function public.pay_debt_share(uuid, numeric, text, timestamptz, text) from public, anon;
grant execute on function public.pay_debt_share(uuid, numeric, text, timestamptz, text) to authenticated;

-- «Deshacer», mientras el teléfono de quien cobra todavía no lo anotó.
create or replace function public.undo_debt_payment(p_payment_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_share uuid;
begin
  delete from public.debt_payments p
   using public.debt_shares s
   where p.id = p_payment_id and s.id = p.share_id
     and s.debtor = auth.uid() and p.creditor_seen_at is null
  returning p.share_id into v_share;

  if v_share is null then return false; end if;
  perform public.recompute_debt_share(v_share);
  return true;
end;
$$;

revoke all on function public.undo_debt_payment(uuid) from public, anon;
grant execute on function public.undo_debt_payment(uuid) to authenticated;

-- ── Lo que me pagaron ──────────────────────────────────────────────────

-- Los pagos que mi teléfono todavía no convirtió en ingreso. `all_paid`: ya
-- no queda ninguna parte abierta de ese gasto **y** a nadie se le cobró sin
-- monto, así que quien cobra puede dar la deuda por cerrada (lo que falte es
-- lo suyo). Con un recordatorio sin cifra no se sabe cuánto falta cobrar.
create or replace function public.list_incoming_debt_payments()
returns table (
  id uuid, share_id uuid, debtor uuid, debt_key text, merchant text,
  amount numeric, currency text, paid_at timestamptz, via text,
  share_amount numeric, share_paid numeric, share_status text, all_paid boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, s.id, s.debtor, s.debt_key, s.merchant,
         p.amount, s.currency, p.paid_at, p.via,
         s.amount, s.paid_amount, s.status,
         not exists (
           select 1 from public.debt_shares o
           where o.creditor = s.creditor and o.debt_key = s.debt_key and o.status = 'open'
         ) and not exists (
           select 1 from public.payment_reminders r
           where r.from_user = s.creditor and r.debt_key = s.debt_key and r.amount is null
         )
  from public.debt_payments p
  join public.debt_shares s on s.id = p.share_id
  where s.creditor = auth.uid() and p.creditor_seen_at is null
  order by p.paid_at;
$$;

revoke all on function public.list_incoming_debt_payments() from public, anon;
grant execute on function public.list_incoming_debt_payments() to authenticated;

create or replace function public.ack_debt_payments(p_ids uuid[])
returns void
language sql
security definer
set search_path = public
as $$
  update public.debt_payments p
     set creditor_seen_at = now()
    from public.debt_shares s
   where p.id = any(p_ids) and s.id = p.share_id
     and s.creditor = auth.uid() and p.creditor_seen_at is null;
$$;

revoke all on function public.ack_debt_payments(uuid[]) from public, anon;
grant execute on function public.ack_debt_payments(uuid[]) to authenticated;

-- ── Realtime ────────────────────────────────────────────────────────────
do $$
declare
  v_table text;
begin
  foreach v_table in array array['debt_shares', 'debt_payments'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = v_table
    ) then
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    end if;
  end loop;
exception when others then
  raise notice 'Realtime no se pudo activar para las deudas: %', sqlerrm;
end
$$;
