-- AgruPay v17 · «Soluciones de cobro»: compartir un gasto crea la deuda.
--
-- Hasta v16 una deuda (`debt_shares`) sólo nacía de un recordatorio con monto:
-- anotar a quién y cuánto obligaba a mandarle algo. Aquí:
--
--   share_expense(...)              «Compartir gasto»: anota la parte de cada
--                                   amigo **sin avisarle**. Avisar sigue siendo
--                                   `send_payment_reminders`, aparte.
--   debt_payments.state             'confirmed' | 'pending' | 'rejected'. Un
--                                   «Ya le pagué» a mano queda 'pending' hasta
--                                   que quien cobra lo acepta; no se confirma solo.
--   list_pending_confirmations()    lo que mis amigos dicen que me pagaron
--   confirm_debt_payment(id, ok)    «Sí, me pagó» / «No me llegó»
--   creditor_record_payment(...)    + p_via: «Yape», «Plin», «Efectivo», «Otro»
--   close_debt_share(id, st, avisar) perdonar con o sin aviso al amigo
--   list_my_debts()                 + pending_amount / rejected_at; lo perdonado
--                                   sin aviso simplemente deja de verse
--   delete_expense_debts(key)       borrar un gasto borra sus deudas
--   rekey_expense_debts(old, new)   editar un gasto a mano no lo separa de sus deudas
--
-- Requiere v10, v11, v12 y v14. Se puede correr más de una vez.

-- ── Estado de cada pago ───────────────────────────────────────────────

alter table public.debt_payments add column if not exists state text not null default 'confirmed';
alter table public.debt_payments add column if not exists decided_at timestamptz;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.debt_payments'::regclass and conname = 'debt_payments_state_check'
  ) then
    alter table public.debt_payments add constraint debt_payments_state_check
      check (state in ('confirmed', 'pending', 'rejected'));
  end if;
end;
$$;

alter table public.debt_shares add column if not exists notify_debtor boolean not null default true;

-- Sólo lo confirmado baja la deuda.
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
  select coalesce(sum(amount), 0) into v_paid
    from public.debt_payments where share_id = p_share_id and state = 'confirmed';
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

-- ── Compartir un gasto ────────────────────────────────────────────────

-- `p_shares` es {"<uuid del amigo>": 30.00}. Crea o ajusta la parte de cada
-- amigo. Quien ya no está en la lista y no había pagado nada sale del gasto;
-- si ya había abonado, su parte se queda (no se borra un pago).
--
-- Una parte nunca baja de lo que ya se pagó de ella.
create or replace function public.share_expense(
  p_debt_key text,
  p_merchant text,
  p_occurred_on date default null,
  p_currency text default 'PEN',
  p_shares jsonb default '{}'::jsonb
)
returns table (friend uuid, status text, share_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.require_google_user();
  v_key text := trim(coalesce(p_debt_key, ''));
  v_merchant text := left(coalesce(nullif(trim(p_merchant), ''), 'Un gasto'), 120);
  v_currency text := coalesce(nullif(p_currency, ''), 'PEN');
  v_friend uuid;
  v_amount numeric(14,2);
  v_entry record;
  v_id uuid;
  v_friends uuid[] := array[]::uuid[];
begin
  if v_key = '' then
    raise exception 'Falta el gasto';
  end if;

  for v_entry in select key, value from jsonb_each_text(coalesce(p_shares, '{}'::jsonb)) loop
    v_friend := v_entry.key::uuid;
    v_amount := nullif(v_entry.value, '')::numeric;

    if not public.is_friend(v_friend) then
      friend := v_friend; status := 'not_friend'; share_id := null;
      return next;
      continue;
    end if;
    if coalesce(v_amount, 0) <= 0 then
      continue;
    end if;
    v_friends := v_friends || v_friend;

    insert into public.debt_shares
      (creditor, debtor, debt_key, merchant, occurred_on, amount, currency)
    values
      (v_user, v_friend, v_key, v_merchant, p_occurred_on, v_amount, v_currency)
    on conflict (creditor, debtor, debt_key) do update
      set amount = case when debt_shares.status in ('open', 'archived')
                        then greatest(excluded.amount, debt_shares.paid_amount)
                        else debt_shares.amount end,
          status = case when debt_shares.status = 'archived' then 'open' else debt_shares.status end,
          closed_at = case when debt_shares.status = 'archived' then null else debt_shares.closed_at end,
          merchant = excluded.merchant,
          occurred_on = excluded.occurred_on,
          currency = excluded.currency,
          updated_at = now()
    returning id into v_id;

    perform public.recompute_debt_share(v_id);
    friend := v_friend; status := 'saved'; share_id := v_id;
    return next;
  end loop;

  -- Quien salió del reparto sin haber pagado nada deja de deber.
  delete from public.debt_shares s
   where s.creditor = v_user and s.debt_key = v_key
     and s.status in ('open', 'archived') and s.paid_amount = 0
     and not (s.debtor = any(v_friends))
     and not exists (select 1 from public.debt_payments p where p.share_id = s.id);
end;
$$;

revoke all on function public.share_expense(text, text, date, text, jsonb) from public, anon;
grant execute on function public.share_expense(text, text, date, text, jsonb) to authenticated;

-- Un recordatorio con monto ya no achica una parte que se había abonado: la
-- deuda nace al compartir, no al recordar.
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
    set amount = case when debt_shares.status in ('open', 'archived')
                      then greatest(excluded.amount, debt_shares.paid_amount)
                      else debt_shares.amount end,
        status = case when debt_shares.status = 'archived' then 'open' else debt_shares.status end,
        closed_at = case when debt_shares.status = 'archived' then null else debt_shares.closed_at end,
        merchant = excluded.merchant,
        occurred_on = excluded.occurred_on,
        currency = excluded.currency,
        updated_at = now();
  return new;
end;
$$;

-- ── «Ya le pagué» espera confirmación ─────────────────────────────────

-- Igual que v12, pero lo marcado a mano (`p_via = 'manual'`) entra pendiente:
-- no baja la deuda hasta que quien cobra diga «Sí, me pagó». Lo que detectó
-- el correo del que paga (Yape, Plin…) sigue entrando confirmado.
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
  v_via text := left(coalesce(nullif(trim(p_via), ''), 'manual'), 20);
  v_state text;
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

  if v_share.status in ('paid', 'forgiven') or v_share.paid_amount >= v_share.amount then
    status := 'already_paid'; payment_id := null;
    paid_amount := v_share.paid_amount; remaining := 0;
    return next; return;
  end if;

  v_amount := least(p_amount, v_share.amount - v_share.paid_amount);
  v_state := case when v_via = 'manual' then 'pending' else 'confirmed' end;

  -- Un «Ya le pagué» nuevo reemplaza al que quien cobra rechazó.
  if v_state = 'pending' then
    delete from public.debt_payments
     where share_id = p_share_id and state in ('pending', 'rejected');
  end if;

  insert into public.debt_payments (share_id, amount, paid_at, via, source_key, state)
  values (p_share_id, v_amount, coalesce(p_paid_at, now()), v_via, left(trim(p_source_key), 200), v_state)
  on conflict (share_id, source_key) do nothing
  returning id into v_id;

  if v_id is null then
    status := 'duplicate'; payment_id := null;
    paid_amount := v_share.paid_amount; remaining := v_share.amount - v_share.paid_amount;
    return next; return;
  end if;

  perform public.recompute_debt_share(p_share_id);
  select * into v_share from public.debt_shares where id = p_share_id;

  status := case when v_state = 'pending' then 'pending'
                 when v_share.status = 'paid' then 'paid' else 'partial' end;
  payment_id := v_id;
  paid_amount := v_share.paid_amount;
  remaining := greatest(v_share.amount - v_share.paid_amount, 0);
  return next;
end;
$$;

revoke all on function public.pay_debt_share(uuid, numeric, text, timestamptz, text) from public, anon;
grant execute on function public.pay_debt_share(uuid, numeric, text, timestamptz, text) to authenticated;

-- Lo que mis amigos dicen que me pagaron y todavía no acepto.
create or replace function public.list_pending_confirmations()
returns table (
  id uuid, share_id uuid, debtor uuid, debt_key text, merchant text,
  amount numeric, currency text, paid_at timestamptz, via text
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, s.id, s.debtor, s.debt_key, s.merchant, p.amount, s.currency, p.paid_at, p.via
  from public.debt_payments p
  join public.debt_shares s on s.id = p.share_id
  where s.creditor = auth.uid() and p.state = 'pending'
  order by p.paid_at;
$$;

revoke all on function public.list_pending_confirmations() from public, anon;
grant execute on function public.list_pending_confirmations() to authenticated;

-- «Sí, me pagó» lo confirma y lo deja sin ver (`creditor_seen_at` nulo): el
-- teléfono de quien cobra lo convierte en ingreso con el mismo camino de
-- siempre (`list_incoming_debt_payments`). «No me llegó» lo rechaza: la deuda
-- sigue abierta y a quien debe le sale «No le llegó».
create or replace function public.confirm_debt_payment(p_payment_id uuid, p_accept boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.require_google_user();
  v_share uuid;
begin
  update public.debt_payments p
     set state = case when p_accept then 'confirmed' else 'rejected' end,
         decided_at = now(),
         creditor_seen_at = null
    from public.debt_shares s
   where p.id = p_payment_id and s.id = p.share_id
     and s.creditor = v_user and p.state = 'pending'
  returning p.share_id into v_share;

  if v_share is null then return false; end if;
  perform public.recompute_debt_share(v_share);
  return true;
end;
$$;

revoke all on function public.confirm_debt_payment(uuid, boolean) from public, anon;
grant execute on function public.confirm_debt_payment(uuid, boolean) to authenticated;

-- Sólo lo confirmado llega como ingreso a quien cobra.
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
         )
  from public.debt_payments p
  join public.debt_shares s on s.id = p.share_id
  where s.creditor = auth.uid() and p.creditor_seen_at is null and p.state = 'confirmed'
  order by p.paid_at;
$$;

-- ── Quien cobra registra y cierra ─────────────────────────────────────

drop function if exists public.creditor_record_payment(uuid, numeric);
create or replace function public.creditor_record_payment(
  p_share_id uuid,
  p_amount numeric,
  p_via text default 'Otro'
)
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
  insert into public.debt_payments (share_id, amount, paid_at, via, source_key, creditor_seen_at, state)
  values (p_share_id, v_amount, now(), left(coalesce(nullif(trim(p_via), ''), 'Otro'), 20),
          'creditor:' || gen_random_uuid()::text, now(), 'confirmed');

  -- Lo que quien debe había marcado como pagado queda resuelto.
  delete from public.debt_payments where share_id = p_share_id and state = 'pending';

  perform public.recompute_debt_share(p_share_id);
  select * into v_share from public.debt_shares where id = p_share_id;

  status := v_share.status;
  paid_amount := v_share.paid_amount;
  remaining := greatest(v_share.amount - v_share.paid_amount, 0);
  return next;
end;
$$;

revoke all on function public.creditor_record_payment(uuid, numeric, text) from public, anon;
grant execute on function public.creditor_record_payment(uuid, numeric, text) to authenticated;

-- Perdonar, avisándole o no. «Archivar» se mantiene por compatibilidad pero
-- la app ya no lo ofrece.
drop function if exists public.close_debt_share(uuid, text);
create or replace function public.close_debt_share(p_share_id uuid, p_status text, p_notify boolean default true)
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
     set status = p_status, closed_at = now(), updated_at = now(),
         notify_debtor = coalesce(p_notify, true)
   where id = p_share_id;

  delete from public.debt_payments where share_id = p_share_id and state = 'pending';

  if p_status = 'forgiven' then
    update public.payment_reminders
       set dismissed_at = now()
     where from_user = v_share.creditor and to_user = v_share.debtor
       and debt_key = v_share.debt_key and dismissed_at is null;
  end if;
  return true;
end;
$$;

revoke all on function public.close_debt_share(uuid, text, boolean) from public, anon;
grant execute on function public.close_debt_share(uuid, text, boolean) to authenticated;

-- ── Lo que yo debo ────────────────────────────────────────────────────

-- + `pending_amount`: lo que marqué «Ya le pagué» y espera que lo acepte.
-- + `rejected_at`: me dijo «No me llegó».
-- Lo perdonado sin aviso deja de verse sin más.
drop function if exists public.list_my_debts();
create or replace function public.list_my_debts()
returns table (
  id uuid, creditor uuid, debt_key text, merchant text, occurred_on date,
  amount numeric, currency text, paid_amount numeric, status text,
  created_at timestamptz, paid_at timestamptz, closed_at timestamptz,
  pending_amount numeric, pending_at timestamptz, rejected_at timestamptz
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
         case when s.status = 'forgiven' then s.closed_at else null end,
         coalesce((select sum(p.amount) from public.debt_payments p
                    where p.share_id = s.id and p.state = 'pending'), 0),
         (select max(p.paid_at) from public.debt_payments p
           where p.share_id = s.id and p.state = 'pending'),
         (select max(p.decided_at) from public.debt_payments p
           where p.share_id = s.id and p.state = 'rejected')
  from public.debt_shares s
  where s.debtor = auth.uid()
    and public.is_friend(s.creditor)
    and not (s.status = 'forgiven' and s.notify_debtor = false)
    and (s.status in ('open', 'archived')
         or s.paid_at > now() - interval '30 days'
         or (s.status = 'forgiven' and s.closed_at > now() - interval '30 days'))
  order by s.created_at desc;
$$;

revoke all on function public.list_my_debts() from public, anon;
grant execute on function public.list_my_debts() to authenticated;

-- ── Borrar el gasto borra sus deudas ──────────────────────────────────

-- Quien cobra borró el gasto (era una prueba, se anotó mal): sus partes, sus
-- pagos y sus recordatorios desaparecen también para el amigo.
create or replace function public.delete_expense_debts(p_debt_key text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.require_google_user();
  v_count integer;
begin
  delete from public.debt_shares
   where creditor = v_user and debt_key = trim(coalesce(p_debt_key, ''));
  get diagnostics v_count = row_count;

  delete from public.payment_reminders
   where from_user = v_user and debt_key = trim(coalesce(p_debt_key, ''));
  delete from public.payment_reminder_sends
   where from_user = v_user and debt_key = trim(coalesce(p_debt_key, ''));
  return v_count;
end;
$$;

revoke all on function public.delete_expense_debts(text) from public, anon;
grant execute on function public.delete_expense_debts(text) to authenticated;

-- Editar un gasto anotado a mano le cambia la llave (`fp:` depende del
-- comercio y la fecha): sus deudas y recordatorios se mudan con él.
create or replace function public.rekey_expense_debts(p_old_key text, p_new_key text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.require_google_user();
  v_old text := trim(coalesce(p_old_key, ''));
  v_new text := trim(coalesce(p_new_key, ''));
  v_count integer;
begin
  if v_old = '' or v_new = '' or v_old = v_new then return 0; end if;
  update public.debt_shares s set debt_key = v_new, updated_at = now()
   where s.creditor = v_user and s.debt_key = v_old
     and not exists (select 1 from public.debt_shares o
                      where o.creditor = v_user and o.debtor = s.debtor and o.debt_key = v_new);
  get diagnostics v_count = row_count;
  update public.payment_reminders r set debt_key = v_new
   where r.from_user = v_user and r.debt_key = v_old
     and not (r.dismissed_at is null and exists (
       select 1 from public.payment_reminders o
        where o.from_user = v_user and o.to_user = r.to_user and o.debt_key = v_new and o.dismissed_at is null));
  update public.payment_reminder_sends set debt_key = v_new
   where from_user = v_user and debt_key = v_old
     and not exists (select 1 from public.payment_reminder_sends o
                      where o.from_user = v_user and o.to_user = payment_reminder_sends.to_user
                        and o.debt_key = v_new and o.sent_on = payment_reminder_sends.sent_on);
  return v_count;
end;
$$;

revoke all on function public.rekey_expense_debts(text, text) from public, anon;
grant execute on function public.rekey_expense_debts(text, text) to authenticated;

-- Que la API vea las funciones nuevas sin esperar.
notify pgrst, 'reload schema';
