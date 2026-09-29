-- ============================================================
-- AgruPay · Celular verificado por WhatsApp v13
-- ============================================================
-- Corre esto DESPUÉS de v12. Idempotente.
--
-- Verificación «al revés»: en vez de mandarle un código al usuario (un SMS se
-- paga), el usuario **nos escribe** por WhatsApp un código que le dio la app.
-- Meta le dice a la Edge Function `whatsapp-verify` desde qué número llegó el
-- mensaje, y ese número no se puede falsificar. Recibir mensajes no se cobra.
--
-- Qué añade
-- 1. `app_settings`: el número de WhatsApp de AgruPay (a dónde escribir).
-- 2. `phone_verification_codes`: códigos de un solo uso, 15 minutos.
-- 3. `verified_phones`: el celular verificado de cada usuario. Nadie lee el de
--    nadie: ni sus amigos. Lo que se comparta después (los últimos dígitos
--    para emparejar pagos) saldrá por funciones que recorten.
-- 4. RPCs: start_phone_verification, my_verified_phone, forget_my_phone.
--    `confirm_phone_verification` sólo la llama la Edge Function (servicio).

-- ── Ajustes ────────────────────────────────────────────────────────────

create table if not exists public.app_settings (
  key text primary key,
  value text not null
);

alter table public.app_settings enable row level security;
-- Sin políticas: se lee por las funciones de abajo.

-- ⚠️ Cambia esto por el número de WhatsApp Business de AgruPay, sin «+» ni
-- espacios (51 + los 9 dígitos). Mientras pruebas con el número de prueba de
-- Meta, pon ése.
insert into public.app_settings (key, value)
values ('whatsapp_verify_number', '51900000000')
on conflict (key) do nothing;

-- ── Códigos ────────────────────────────────────────────────────────────

create table if not exists public.phone_verification_codes (
  code text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '15 minutes',
  used_at timestamptz
);

create index if not exists phone_verification_codes_user_idx
  on public.phone_verification_codes (user_id, created_at);

alter table public.phone_verification_codes enable row level security;

-- ── Celulares verificados ──────────────────────────────────────────────

create table if not exists public.verified_phones (
  user_id uuid primary key references auth.users(id) on delete cascade,
  -- E.164: «+51987654321».
  phone text not null unique,
  verified_at timestamptz not null default now()
);

alter table public.verified_phones enable row level security;

-- Sólo el tuyo: la app lo necesita para saber que ya quedó verificado
-- (Realtime entrega los cambios de filas que se pueden leer).
drop policy if exists verified_phones_own on public.verified_phones;
create policy verified_phones_own on public.verified_phones
  for select to authenticated
  using (user_id = auth.uid());

-- ── Empezar ────────────────────────────────────────────────────────────

-- Devuelve el código y a qué número escribirlo. Borra los códigos sin usar
-- que tuviera: sólo vale el último.
create or replace function public.start_phone_verification()
returns table (code text, whatsapp_number text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := public.require_google_user();
  -- Sin 0/O ni 1/I/L: se leen en voz alta sin confundirse.
  v_alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text;
  v_recent int;
  i int;
begin
  select count(*) into v_recent
  from public.phone_verification_codes c
  where c.user_id = v_user and c.created_at > now() - interval '1 hour';
  if v_recent >= 6 then
    raise exception 'Demasiados intentos: prueba de nuevo en una hora';
  end if;

  delete from public.phone_verification_codes c
  where c.user_id = v_user and c.used_at is null;

  loop
    v_code := 'AGRU-';
    for i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.phone_verification_codes c where c.code = v_code);
  end loop;

  insert into public.phone_verification_codes (code, user_id) values (v_code, v_user);

  code := v_code;
  whatsapp_number := (select value from public.app_settings where key = 'whatsapp_verify_number');
  expires_at := now() + interval '15 minutes';
  return next;
end;
$$;

revoke all on function public.start_phone_verification() from public, anon;
grant execute on function public.start_phone_verification() to authenticated;

-- ── Confirmar (sólo la Edge Function) ──────────────────────────────────

-- `p_phone` llega de Meta: los dígitos del remitente con código de país
-- («51987654321»). Si ese número ya era de otra cuenta, pasa a ésta: quien
-- escribe desde el teléfono es quien lo tiene ahora.
--
-- Devuelve: verified · expired · unknown
create or replace function public.confirm_phone_verification(p_code text, p_phone text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.phone_verification_codes%rowtype;
  v_phone text := '+' || regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
begin
  if length(v_phone) < 9 then return 'unknown'; end if;

  select * into v_row from public.phone_verification_codes
  where code = upper(trim(p_code)) and used_at is null
  for update;
  if not found then return 'unknown'; end if;
  if v_row.expires_at < now() then return 'expired'; end if;

  update public.phone_verification_codes set used_at = now() where code = v_row.code;

  delete from public.verified_phones where phone = v_phone and user_id <> v_row.user_id;
  insert into public.verified_phones (user_id, phone, verified_at)
  values (v_row.user_id, v_phone, now())
  on conflict (user_id) do update set phone = excluded.phone, verified_at = now();

  return 'verified';
end;
$$;

revoke all on function public.confirm_phone_verification(text, text) from public, anon, authenticated;
grant execute on function public.confirm_phone_verification(text, text) to service_role;

-- ── El mío ─────────────────────────────────────────────────────────────

create or replace function public.my_verified_phone()
returns table (phone text, verified_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select phone, verified_at from public.verified_phones where user_id = auth.uid();
$$;

revoke all on function public.my_verified_phone() from public, anon;
grant execute on function public.my_verified_phone() to authenticated;

create or replace function public.forget_my_phone()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.verified_phones where user_id = auth.uid();
$$;

revoke all on function public.forget_my_phone() from public, anon;
grant execute on function public.forget_my_phone() to authenticated;

-- ── Realtime ────────────────────────────────────────────────────────────
-- La hoja de verificar se entera sola de que el mensaje llegó.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'verified_phones'
  ) then
    alter publication supabase_realtime add table public.verified_phones;
  end if;
exception when others then
  raise notice 'Realtime no se pudo activar para verified_phones: %', sqlerrm;
end
$$;
