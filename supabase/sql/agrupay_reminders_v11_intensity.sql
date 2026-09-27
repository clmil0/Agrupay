-- ============================================================
-- AgruPay · Recordatorios de cobro v11 — modo suave y modo intenso
-- ============================================================
-- Corre esto DESPUÉS de v10. Idempotente.
--
-- Qué añade
-- 1. `payment_reminders.intensity`: 'soft' (la notificación de siempre y el
--    cobro entra en Amigos) o 'intense' (además, al abrir la app, un modal con
--    el personaje de quien cobra). Lo elige quien cobra en «Cobrar».
-- 2. `send_payment_reminders` acepta `p_intensity`. Se reemplaza la versión
--    de v10 (en vez de sumar otra con el mismo nombre) para que PostgREST no
--    tenga que elegir entre dos funciones.
--
-- El tope de uno por día no cambia: el modal sale a lo sumo una vez por
-- recordatorio, y el teléfono recuerda cuáles ya enseñó.

alter table public.payment_reminders
  add column if not exists intensity text not null default 'soft';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'payment_reminders_intensity_check'
  ) then
    alter table public.payment_reminders
      add constraint payment_reminders_intensity_check check (intensity in ('soft', 'intense'));
  end if;
end
$$;

drop function if exists public.send_payment_reminders(uuid[], text, text, date, jsonb, text, text);

create or replace function public.send_payment_reminders(
  p_friends uuid[],
  p_debt_key text,
  p_merchant text,
  p_occurred_on date default null,
  p_amounts jsonb default '{}'::jsonb,
  p_currency text default 'PEN',
  p_message text default '',
  p_intensity text default 'soft'
)
returns table (friend uuid, status text, reminder_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.require_google_user();
  v_today date := (now() at time zone 'America/Lima')::date;
  v_friend uuid;
  v_amount numeric(14,2);
  v_existing public.payment_reminders%rowtype;
  v_message text := left(coalesce(p_message, ''), 240);
  v_merchant text := left(coalesce(nullif(trim(p_merchant), ''), 'Un gasto'), 120);
  v_intensity text := case when p_intensity = 'intense' then 'intense' else 'soft' end;
begin
  if coalesce(trim(p_debt_key), '') = '' then
    raise exception 'Falta la deuda';
  end if;
  -- Tope de cordura: un recordatorio no es una lista de difusión.
  if coalesce(array_length(p_friends, 1), 0) > 20 then
    raise exception 'Demasiados amigos en un mismo recordatorio';
  end if;

  foreach v_friend in array coalesce(p_friends, array[]::uuid[]) loop
    if not public.is_friend(v_friend) then
      friend := v_friend; status := 'not_friend'; reminder_id := null;
      return next;
      continue;
    end if;

    v_amount := nullif(p_amounts ->> v_friend::text, '')::numeric;

    select * into v_existing
    from public.payment_reminders
    where from_user = v_user and to_user = v_friend
      and debt_key = trim(p_debt_key) and dismissed_at is null;

    if found then
      if v_existing.sent_on >= v_today then
        friend := v_friend; status := 'already_today'; reminder_id := v_existing.id;
        return next;
        continue;
      end if;

      update public.payment_reminders
         set merchant = v_merchant,
             occurred_on = p_occurred_on,
             amount = v_amount,
             currency = coalesce(nullif(p_currency, ''), 'PEN'),
             message = v_message,
             intensity = v_intensity,
             sent_on = v_today,
             created_at = now()
       where id = v_existing.id;

      friend := v_friend; status := 'renewed'; reminder_id := v_existing.id;
      return next;
      continue;
    end if;

    insert into public.payment_reminders
      (from_user, to_user, debt_key, merchant, occurred_on, amount, currency, message, intensity, sent_on)
    values
      (v_user, v_friend, trim(p_debt_key), v_merchant, p_occurred_on, v_amount,
       coalesce(nullif(p_currency, ''), 'PEN'), v_message, v_intensity, v_today)
    returning id into reminder_id;

    friend := v_friend; status := 'sent';
    return next;
  end loop;
end;
$$;

revoke all on function public.send_payment_reminders(uuid[], text, text, date, jsonb, text, text, text) from public, anon;
grant execute on function public.send_payment_reminders(uuid[], text, text, date, jsonb, text, text, text) to authenticated;

-- `list_my_reminders` devuelve la fila entera (`setof payment_reminders`):
-- trae `intensity` sin tocarla.
