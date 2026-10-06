-- ============================================================
-- AgruPay · Analítica de uso v16
-- ============================================================
-- Corre esto DESPUÉS de v15. Idempotente: se puede volver a correr entero.
--
-- Qué añade
-- 1. `analytics_events`: un evento por fila (lo que manda `Analytics.swift`).
-- 2. `analytics_installs`: una fila por instalación (primera y última vez,
--    versión, canal). Es la base de cohortes y retención.
-- 3. `ingest_analytics(...)`: la única puerta de entrada. La llama la app con
--    la llave pública (rol `anon`), valida y recorta todo lo que llega.
-- 4. `analytics_admins` + `analytics_is_admin()`: quién puede leer.
-- 5. Vistas `analytics_*` listas para el panel (una por pregunta). Ver
--    `supabase/ANALYTICS.md` para el catálogo de eventos y qué responde cada
--    vista.
-- 6. `analytics_prune(dias)`: borra lo viejo (por defecto, > 400 días).
--
-- Privacidad
-- - El `install_id` es aleatorio y de esta instalación: no es el usuario de
--   Google ni el de Amigos, y nada aquí los cruza.
-- - Nada financiero: sin montos, comercios, correos ni nombres. Las
--   categorías propias llegan como «personalizada».
--
-- Quién lee
-- - `service_role` (desde un servidor; nunca en el navegador) y el editor SQL
--   de Supabase leen todo.
-- - Un panel en el navegador puede leer con la sesión de Google de un
--   administrador: agrega su `auth.users.id` a `analytics_admins`:
--     insert into public.analytics_admins (user_id)
--     select id from auth.users where email = 'tu-correo@gmail.com';
-- - `anon` sólo puede llamar a `ingest_analytics`: no lee ni una fila.
--
-- Zona horaria de los días y semanas de las vistas: America/Lima.
-- Las vistas excluyen el canal `debug` (Xcode / simulador). TestFlight y App
-- Store sí cuentan; filtra por `channel` en la tabla si hace falta.

-- ── Tablas ─────────────────────────────────────────────────────────────

create table if not exists public.analytics_events (
  id           bigint generated always as identity primary key,
  install_id   uuid not null,
  session_id   uuid,
  event        text not null,
  props        jsonb not null default '{}'::jsonb,
  is_pro       boolean not null default false,
  occurred_at  timestamptz not null,
  received_at  timestamptz not null default now(),
  app_version  text,
  build        text,
  os           text,
  device       text,
  locale       text,
  tz           text,
  channel      text not null default 'unknown'
);

create index if not exists analytics_events_occurred_idx
  on public.analytics_events (occurred_at);
create index if not exists analytics_events_event_idx
  on public.analytics_events (event, occurred_at);
create index if not exists analytics_events_install_idx
  on public.analytics_events (install_id, occurred_at);

create table if not exists public.analytics_installs (
  install_id     uuid primary key,
  first_seen     timestamptz not null,
  last_seen      timestamptz not null,
  first_version  text,
  last_version   text,
  channel        text,
  device         text,
  os             text,
  -- Ya usaba la app antes de que existiera la analítica: sus «horas desde
  -- que instaló» no son de un usuario nuevo.
  preexisting    boolean not null default false
);

create table if not exists public.analytics_admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

alter table public.analytics_events   enable row level security;
alter table public.analytics_installs enable row level security;
alter table public.analytics_admins   enable row level security;

revoke all on public.analytics_events   from anon, authenticated;
revoke all on public.analytics_installs from anon, authenticated;
revoke all on public.analytics_admins   from anon, authenticated;

-- ── Quién lee ──────────────────────────────────────────────────────────

create or replace function public.analytics_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  -- `service_role` y el editor SQL (dueño de las tablas) ya se saltan RLS;
  -- esto decide sólo para sesiones de usuario.
  select coalesce(auth.jwt() ->> 'role', '') = 'service_role'
      or exists (select 1 from public.analytics_admins a where a.user_id = auth.uid());
$$;

revoke all on function public.analytics_is_admin() from public;
grant execute on function public.analytics_is_admin() to authenticated, service_role;

grant select on public.analytics_events   to authenticated;
grant select on public.analytics_installs to authenticated;

drop policy if exists analytics_events_admin_read on public.analytics_events;
create policy analytics_events_admin_read on public.analytics_events
  for select to authenticated
  using ((select public.analytics_is_admin()));

drop policy if exists analytics_installs_admin_read on public.analytics_installs;
create policy analytics_installs_admin_read on public.analytics_installs
  for select to authenticated
  using ((select public.analytics_is_admin()));

-- ── Ayudantes ──────────────────────────────────────────────────────────

-- Un número de `props`, o null si no lo es: un valor raro no rompe las vistas.
create or replace function public.analytics_num(p jsonb, k text)
returns numeric
language sql
immutable
as $$
  select case when jsonb_typeof(p -> k) = 'number' then (p ->> k)::numeric end;
$$;

create or replace function public.analytics_try_ts(t text)
returns timestamptz
language plpgsql
stable
as $$
begin
  return t::timestamptz;
exception when others then
  return null;
end;
$$;

-- ── Entrada ────────────────────────────────────────────────────────────
-- p_context: { app_version, build, os, device, locale, tz, channel, preexisting }
-- p_events:  [ { e: nombre, t: ISO-8601, s: sesión, pro: bool, p: {props} } ]

create or replace function public.ingest_analytics(
  p_install_id uuid,
  p_context    jsonb,
  p_events     jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recent   integer;
  v_inserted integer;
  v_channel  text;
  v_version  text;
  v_first    timestamptz;
  v_last     timestamptz;
begin
  if p_install_id is null or jsonb_typeof(p_events) is distinct from 'array' then
    return 0;
  end if;
  if jsonb_array_length(p_events) > 100 or pg_column_size(p_events) > 262144 then
    raise exception 'lote demasiado grande' using errcode = '22023';
  end if;

  -- Tope por instalación: 5.000 eventos por hora. Lo que pase de ahí no es
  -- una persona usando la app.
  select count(*) into v_recent
  from public.analytics_events
  where install_id = p_install_id
    and occurred_at > now() - interval '1 hour';
  if v_recent > 5000 then
    return 0;
  end if;

  v_channel := case when p_context ->> 'channel' in ('debug', 'development', 'testflight', 'appstore')
                    then p_context ->> 'channel' else 'unknown' end;
  v_version := left(p_context ->> 'app_version', 20);

  with raw as (
    select e,
           public.analytics_try_ts(e ->> 't') as ts
    from jsonb_array_elements(p_events) as e
    where jsonb_typeof(e) = 'object'
  ), ok as (
    select e,
           -- Un reloj adelantado no escribe en el futuro.
           least(ts, now()) as ts
    from raw
    where ts is not null
      and ts > now() - interval '30 days'
      and (e ->> 'e') ~ '^[a-z][a-z0-9_]{1,47}$'
  ), ins as (
    insert into public.analytics_events
      (install_id, session_id, event, props, is_pro, occurred_at,
       app_version, build, os, device, locale, tz, channel)
    select p_install_id,
           case when (e ->> 's') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                then (e ->> 's')::uuid end,
           e ->> 'e',
           case when jsonb_typeof(e -> 'p') = 'object' and pg_column_size(e -> 'p') <= 2048
                then e -> 'p' else '{}'::jsonb end,
           coalesce(e -> 'pro' = 'true'::jsonb, false),
           ts,
           v_version,
           left(p_context ->> 'build', 20),
           left(p_context ->> 'os', 20),
           left(p_context ->> 'device', 30),
           left(p_context ->> 'locale', 20),
           left(p_context ->> 'tz', 40),
           v_channel
    from ok
    returning occurred_at
  )
  select count(*), min(occurred_at), max(occurred_at)
    into v_inserted, v_first, v_last
  from ins;

  if v_inserted > 0 then
    insert into public.analytics_installs as i
      (install_id, first_seen, last_seen, first_version, last_version,
       channel, device, os, preexisting)
    values
      (p_install_id, v_first, v_last, v_version, v_version, v_channel,
       left(p_context ->> 'device', 30), left(p_context ->> 'os', 20),
       coalesce(p_context -> 'preexisting' = 'true'::jsonb, false))
    on conflict (install_id) do update set
      first_seen   = least(i.first_seen, excluded.first_seen),
      last_seen    = greatest(i.last_seen, excluded.last_seen),
      last_version = coalesce(excluded.last_version, i.last_version),
      channel      = excluded.channel,
      device       = coalesce(excluded.device, i.device),
      os           = coalesce(excluded.os, i.os),
      preexisting  = i.preexisting or excluded.preexisting;
  end if;

  return v_inserted;
end;
$$;

revoke all on function public.ingest_analytics(uuid, jsonb, jsonb) from public;
grant execute on function public.ingest_analytics(uuid, jsonb, jsonb) to anon, authenticated;

-- ── Limpieza ───────────────────────────────────────────────────────────
-- Para correrla sola cada semana con pg_cron (Database › Cron):
--   select cron.schedule('analytics-prune', '0 4 * * 1',
--                        $$select public.analytics_prune(400)$$);

create or replace function public.analytics_prune(p_keep_days integer default 400)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted integer;
begin
  delete from public.analytics_events
  where occurred_at < now() - make_interval(days => greatest(p_keep_days, 30));
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.analytics_prune(integer) from public, anon, authenticated;

-- ============================================================
-- Vistas para el panel
-- ============================================================
-- Todas con `security_invoker`: leen con los permisos de quien pregunta, así
-- que la política de `analytics_events` (sólo administradores) también manda
-- aquí. Las `_daily` traen un día por fila para filtrar por rango en el panel;
-- las `_30d` ya vienen resumidas para los últimos 30 días.

-- Base: sin `debug`, con el día y la semana de Lima.
create or replace view public.analytics_ev
with (security_invoker = true) as
select e.*,
       (e.occurred_at at time zone 'America/Lima')                          as local_ts,
       (e.occurred_at at time zone 'America/Lima')::date                    as day,
       date_trunc('week',  e.occurred_at at time zone 'America/Lima')::date as week,
       date_trunc('month', e.occurred_at at time zone 'America/Lima')::date as month
from public.analytics_events e
where e.channel <> 'debug';

-- ── Uso general ────────────────────────────────────────────────────────

-- Usuarios activos por día (DAU), sesiones y aperturas.
create or replace view public.analytics_daily_active
with (security_invoker = true) as
select day,
       count(distinct install_id)                                   as active_installs,
       count(distinct install_id) filter (where is_pro)             as active_pro,
       count(distinct session_id)                                   as sessions,
       count(*) filter (where event = 'app_open')                   as opens,
       count(*)                                                     as events
from public.analytics_ev
group by day;

-- WAU y MAU.
create or replace view public.analytics_weekly_active
with (security_invoker = true) as
select week, count(distinct install_id) as active_installs,
       count(distinct install_id) filter (where is_pro) as active_pro
from public.analytics_ev group by week;

create or replace view public.analytics_monthly_active
with (security_invoker = true) as
select month, count(distinct install_id) as active_installs,
       count(distinct install_id) filter (where is_pro) as active_pro
from public.analytics_ev group by month;

-- Instalaciones nuevas por día.
create or replace view public.analytics_new_installs_daily
with (security_invoker = true) as
select (first_seen at time zone 'America/Lima')::date as day,
       count(*)                                    as installs,
       count(*) filter (where not preexisting)     as new_users,
       count(*) filter (where preexisting)         as existing_users_updated
from public.analytics_installs
where channel <> 'debug'
group by 1;

-- Pantallas: visitas (sin contar las continuaciones tras segundo plano),
-- personas y minutos.
create or replace view public.analytics_screens_daily
with (security_invoker = true) as
select day,
       props ->> 'screen'                                                     as screen,
       count(*) filter (where coalesce(props -> 'cont' <> 'true'::jsonb, true)) as views,
       count(distinct install_id)                                             as installs,
       round(sum(coalesce(public.analytics_num(props, 'seconds'), 0)) / 60, 1) as minutes
from public.analytics_ev
where event = 'screen_view'
group by day, props ->> 'screen';

create or replace view public.analytics_screens_30d
with (security_invoker = true) as
select props ->> 'screen'                                                     as screen,
       count(*) filter (where coalesce(props -> 'cont' <> 'true'::jsonb, true)) as views,
       count(distinct install_id)                                             as installs,
       round(sum(coalesce(public.analytics_num(props, 'seconds'), 0)) / 60, 1) as minutes,
       round(percentile_cont(0.5) within group
             (order by public.analytics_num(props, 'seconds'))::numeric, 1)  as median_seconds
from public.analytics_ev
where event = 'screen_view' and occurred_at > now() - interval '30 days'
group by props ->> 'screen';

-- Dónde se toca más.
create or replace view public.analytics_taps_daily
with (security_invoker = true) as
select day, props ->> 'target' as target,
       count(*) as taps, count(distinct install_id) as installs
from public.analytics_ev
where event = 'tap'
group by day, props ->> 'target';

create or replace view public.analytics_taps_30d
with (security_invoker = true) as
select props ->> 'target' as target,
       count(*) as taps, count(distinct install_id) as installs
from public.analytics_ev
where event = 'tap' and occurred_at > now() - interval '30 days'
group by props ->> 'target';

-- Pestañas y secciones de la píldora.
create or replace view public.analytics_navigation_daily
with (security_invoker = true) as
select day, event,
       coalesce(props ->> 'tab', props ->> 'section') as target,
       count(*) as selects, count(distinct install_id) as installs
from public.analytics_ev
where event in ('tab_select', 'section_select')
group by day, event, coalesce(props ->> 'tab', props ->> 'section');

-- Cuántos meses (o semanas, días…) hacia atrás se mira.
create or replace view public.analytics_period_choices_daily
with (security_invoker = true) as
select day,
       props ->> 'screen'                                    as screen,
       props ->> 'granularity'                               as granularity,
       public.analytics_num(props, 'months_back')::integer   as months_back,
       count(*)                                              as choices,
       count(distinct install_id)                            as installs
from public.analytics_ev
where event = 'period_change'
group by 1, 2, 3, 4;

create or replace view public.analytics_period_choices_30d
with (security_invoker = true) as
select props ->> 'screen'                                    as screen,
       props ->> 'granularity'                               as granularity,
       public.analytics_num(props, 'months_back')::integer   as months_back,
       count(*)                                              as choices,
       count(distinct install_id)                            as installs
from public.analytics_ev
where event = 'period_change' and occurred_at > now() - interval '30 days'
group by 1, 2, 3;

-- Lo más lejos que llegó cada persona: ¿cuánta gente mira más de 3 meses?
create or replace view public.analytics_max_months_back_30d
with (security_invoker = true) as
with per_install as (
  select install_id, max(public.analytics_num(props, 'months_back')) as max_back
  from public.analytics_ev
  where event = 'period_change' and occurred_at > now() - interval '30 days'
  group by install_id
)
select max_back::integer as max_months_back, count(*) as installs
from per_install
group by 1;

-- Días / Semanas / Meses del gráfico del Resumen.
create or replace view public.analytics_chart_modes_30d
with (security_invoker = true) as
select props ->> 'mode' as mode, count(*) as choices, count(distinct install_id) as installs
from public.analytics_ev
where event = 'chart_mode' and occurred_at > now() - interval '30 days'
group by 1;

-- ── Funciones descubiertas ─────────────────────────────────────────────

-- Qué parte de las instalaciones llegó alguna vez a cada función, y en
-- cuántos días.
create or replace view public.analytics_feature_discovery
with (security_invoker = true) as
with total as (
  select count(*)::numeric as installs
  from public.analytics_installs where channel <> 'debug'
)
select props ->> 'feature'                                          as feature,
       count(distinct install_id)                                   as installs,
       round(100 * count(distinct install_id) / nullif((select installs from total), 0), 1) as pct_of_installs,
       percentile_cont(0.5) within group
         (order by public.analytics_num(props, 'days_since_install')) as median_days_to_discover
from public.analytics_ev
where event = 'feature_first_use'
group by props ->> 'feature';

create or replace view public.analytics_feature_usage_daily
with (security_invoker = true) as
select day, props ->> 'feature' as feature,
       count(*) as uses, count(distinct install_id) as installs
from public.analytics_ev
where event = 'feature_used'
group by day, props ->> 'feature';

-- ── Motor de correo ────────────────────────────────────────────────────

-- Por banco: insertados, duplicados y «reconocí el correo pero no el
-- monto» (`amount_missing`): si sube, ese banco cambió su formato.
create or replace view public.analytics_parser_health_daily
with (security_invoker = true) as
select day,
       props ->> 'bank'     as bank,
       props ->> 'kind'     as kind,
       props ->> 'result'   as result,
       props ->> 'provider' as provider,
       count(*)             as emails,
       count(distinct install_id) as installs
from public.analytics_ev
where event = 'email_parse'
group by 1, 2, 3, 4, 5;

-- Cada lectura del correo: cuántos revisó, cuántos no reconoció ninguno.
create or replace view public.analytics_sync_runs_daily
with (security_invoker = true) as
select day,
       coalesce(props -> 'range' = 'true'::jsonb, false)               as range_sync,
       count(*)                                                        as runs,
       sum(public.analytics_num(props, 'checked'))                     as checked,
       sum(public.analytics_num(props, 'new'))                         as new_movements,
       sum(public.analytics_num(props, 'unrecognized'))                as unrecognized,
       sum(public.analytics_num(props, 'failed_fetch'))                as failed_fetch,
       round(avg(public.analytics_num(props, 'seconds')), 1)           as avg_seconds,
       round(100 * sum(public.analytics_num(props, 'unrecognized'))
             / nullif(sum(public.analytics_num(props, 'checked')), 0), 1) as pct_unrecognized
from public.analytics_ev
where event = 'email_sync_run'
group by 1, 2;

-- Minutos entre que llega el correo y aparece el movimiento (sólo lecturas
-- normales, no las de un rango pasado).
create or replace view public.analytics_email_latency_daily
with (security_invoker = true) as
select day,
       props ->> 'provider' as provider,
       count(*)             as movements,
       round(percentile_cont(0.5) within group (order by public.analytics_num(props, 'latency_min'))::numeric, 1) as p50_min,
       round(percentile_cont(0.9) within group (order by public.analytics_num(props, 'latency_min'))::numeric, 1) as p90_min
from public.analytics_ev
where event = 'email_parse'
  and props ->> 'result' = 'inserted'
  and coalesce(props -> 'range' <> 'true'::jsonb, true)
  and public.analytics_num(props, 'latency_min') is not null
group by 1, 2;

-- Conectar y desconectar el correo (desconectar = la señal de abandono).
create or replace view public.analytics_accounts_daily
with (security_invoker = true) as
select day, event,
       props ->> 'provider' as provider,
       props ->> 'reason'   as reason,
       props ->> 'origin'   as origin,
       count(*)             as events,
       count(distinct install_id) as installs
from public.analytics_ev
where event in ('account_connect_started', 'account_connected',
                'account_connect_failed', 'account_disconnected')
group by 1, 2, 3, 4, 5;

-- ── Clasificación ──────────────────────────────────────────────────────

-- A mano: por día, desde dónde y a qué categoría.
create or replace view public.analytics_classification_daily
with (security_invoker = true) as
select day,
       props ->> 'via'                                         as via,
       props ->> 'category'                                    as category,
       count(*)                                                as actions,
       sum(public.analytics_num(props, 'count'))               as movements,
       sum(public.analytics_num(props, 'from_pending'))        as from_pending,
       sum(public.analytics_num(props, 'reclassified'))        as reclassified,
       count(*) filter (where props -> 'rule_created' = 'true'::jsonb) as with_rule,
       count(distinct install_id)                              as installs
from public.analytics_ev
where event = 'movement_classified'
group by 1, 2, 3;

-- Por semana y por persona: ¿cuánto clasifica alguien a la semana?
create or replace view public.analytics_classification_weekly
with (security_invoker = true) as
with per_install as (
  select week, install_id, sum(public.analytics_num(props, 'count')) as movements
  from public.analytics_ev
  where event = 'movement_classified'
  group by week, install_id
)
select week,
       count(*)                                                as installs,
       sum(movements)                                          as movements,
       round(avg(movements), 1)                                as avg_per_install,
       percentile_cont(0.5) within group (order by movements)  as median_per_install
from per_install
group by week;

-- Automático contra manual, por día y en movimientos.
--   auto_*      : lo que llegó ya clasificado (regla, palabra clave, voz,
--                 recurrente).
--   to_pending  : lo que llegó sin categoría.
--   manual      : lo que el usuario sacó de Pendientes a mano.
create or replace view public.analytics_auto_vs_manual_daily
with (security_invoker = true) as
with auto as (
  select day,
         count(*) filter (where event = 'email_parse' and props ->> 'auto' = 'rule')    as auto_rule,
         count(*) filter (where event = 'email_parse' and props ->> 'auto' = 'keyword') as auto_keyword,
         count(*) filter (where event = 'movement_created' and props ->> 'category_source' = 'voice')     as auto_voice,
         count(*) filter (where event = 'movement_created' and props ->> 'category_source' = 'recurring') as auto_recurring,
         count(*) filter (where event = 'email_parse' and props ->> 'auto' = 'none')    as to_pending,
         count(*) filter (where event = 'movement_created' and props ->> 'category_source' in ('user', 'prefilled')) as manual_entry
  from public.analytics_ev
  where (event = 'email_parse' and props ->> 'result' = 'inserted' and props ->> 'kind' = 'expense')
     or event = 'movement_created'
  group by day
), manual as (
  select day, sum(public.analytics_num(props, 'from_pending')) as manual
  from public.analytics_ev
  where event = 'movement_classified'
  group by day
)
select coalesce(a.day, m.day) as day,
       coalesce(a.auto_rule, 0)      as auto_rule,
       coalesce(a.auto_keyword, 0)   as auto_keyword,
       coalesce(a.auto_voice, 0)     as auto_voice,
       coalesce(a.auto_recurring, 0) as auto_recurring,
       coalesce(a.to_pending, 0)     as to_pending,
       coalesce(a.manual_entry, 0)   as manual_entry,
       coalesce(m.manual, 0)         as manual_from_pending,
       round(100 * (coalesce(a.auto_rule, 0) + coalesce(a.auto_keyword, 0)
                    + coalesce(a.auto_voice, 0) + coalesce(a.auto_recurring, 0))
             / nullif(coalesce(a.auto_rule, 0) + coalesce(a.auto_keyword, 0)
                      + coalesce(a.auto_voice, 0) + coalesce(a.auto_recurring, 0)
                      + coalesce(m.manual, 0), 0), 1) as pct_auto
from auto a
full join manual m on m.day = a.day;

-- Precisión real de cada motor automático en 30 días: de lo que clasificó,
-- cuánto cambió después el usuario.
create or replace view public.analytics_auto_accuracy_30d
with (security_invoker = true) as
with auto as (
  select case when event = 'email_parse' then props ->> 'auto'
              else props ->> 'category_source' end as engine,
         count(*) as classified
  from public.analytics_ev
  where occurred_at > now() - interval '30 days'
    and ((event = 'email_parse' and props ->> 'result' = 'inserted'
          and props ->> 'auto' in ('rule', 'keyword'))
      or (event = 'movement_created' and props ->> 'category_source' in ('voice', 'recurring')))
  group by 1
), corrected as (
  select props ->> 'engine' as engine, sum(public.analytics_num(props, 'count')) as corrected
  from public.analytics_ev
  where event = 'classification_corrected' and occurred_at > now() - interval '30 days'
  group by 1
)
select a.engine,
       a.classified,
       coalesce(c.corrected, 0) as corrected,
       round(100 * (1 - coalesce(c.corrected, 0) / nullif(a.classified, 0)), 1) as pct_accuracy
from auto a
left join corrected c on c.engine = a.engine;

-- Sugerencias: mostradas, aceptadas y descartadas, por tipo.
create or replace view public.analytics_suggestions_daily
with (security_invoker = true) as
select day,
       props ->> 'kind'   as kind,
       props ->> 'screen' as screen,
       count(*) filter (where event = 'suggestion_shown')     as shown,
       count(*) filter (where event = 'suggestion_accepted')  as accepted,
       count(*) filter (where event = 'suggestion_dismissed') as dismissed
from public.analytics_ev
where event in ('suggestion_shown', 'suggestion_accepted', 'suggestion_dismissed')
group by 1, 2, 3;

create or replace view public.analytics_suggestions_30d
with (security_invoker = true) as
select props ->> 'kind' as kind,
       count(*) filter (where event = 'suggestion_shown')     as shown,
       count(*) filter (where event = 'suggestion_accepted')  as accepted,
       count(*) filter (where event = 'suggestion_dismissed') as dismissed,
       round(100.0 * count(*) filter (where event = 'suggestion_accepted')
             / nullif(count(*) filter (where event in ('suggestion_accepted', 'suggestion_dismissed')), 0), 1)
         as pct_accepted
from public.analytics_ev
where event in ('suggestion_shown', 'suggestion_accepted', 'suggestion_dismissed')
  and occurred_at > now() - interval '30 days'
group by 1;

-- Reglas de comercio creadas, por origen.
create or replace view public.analytics_rules_daily
with (security_invoker = true) as
select day, props ->> 'origin' as origin,
       sum(public.analytics_num(props, 'count')) as rules,
       count(distinct install_id) as installs
from public.analytics_ev
where event = 'rule_created'
group by 1, 2;

-- El atasco de Pendientes: si crece semana a semana, la gente se rinde.
create or replace view public.analytics_pending_backlog_daily
with (security_invoker = true) as
select day,
       count(distinct install_id)                                                  as installs,
       round(avg(public.analytics_num(props, 'pending_month')), 1)                 as avg_pending_month,
       percentile_cont(0.5) within group (order by public.analytics_num(props, 'pending_month')) as p50_pending_month,
       percentile_cont(0.9) within group (order by public.analytics_num(props, 'pending_month')) as p90_pending_month,
       round(avg(public.analytics_num(props, 'pending_total')), 1)                 as avg_pending_total,
       round(100 * avg(public.analytics_num(props, 'pending_month')
                       / nullif(public.analytics_num(props, 'movements_month'), 0)), 1) as pct_month_pending
from public.analytics_ev
where event = 'daily_snapshot'
group by day;

-- Cómo se crean los movimientos: correo, a mano, voz, Siri, widget…
create or replace view public.analytics_movements_created_daily
with (security_invoker = true) as
select day, props ->> 'source' as source, props ->> 'kind' as kind,
       count(*) as movements, count(distinct install_id) as installs
from public.analytics_ev
where event = 'movement_created'
group by 1, 2, 3;

-- ── Activación ─────────────────────────────────────────────────────────

-- Embudo del onboarding por semana de instalación.
create or replace view public.analytics_onboarding_funnel
with (security_invoker = true) as
with steps(step, step_order) as (
  values ('slide_1', 1), ('slide_2', 2), ('slide_3', 3), ('login', 4),
         ('connect_tapped', 5), ('connected', 6), ('restore_offered', 7),
         ('history', 8), ('reading', 9), ('no_account', 10), ('finished', 11)
)
select date_trunc('week', i.first_seen at time zone 'America/Lima')::date as cohort_week,
       s.step, s.step_order,
       count(distinct e.install_id) as installs
from steps s
join public.analytics_ev e on e.event = 'onboarding_step' and e.props ->> 'step' = s.step
join public.analytics_installs i on i.install_id = e.install_id
where not i.preexisting
group by 1, 2, 3;

-- Hitos: cuánta gente llega y en cuántas horas (mediana) desde instalar.
create or replace view public.analytics_activation_milestones
with (security_invoker = true) as
with total as (
  select count(*)::numeric as installs
  from public.analytics_installs where channel <> 'debug' and not preexisting
)
select e.props ->> 'name'                                              as milestone,
       count(distinct e.install_id)                                    as installs,
       round(100 * count(distinct e.install_id) / nullif((select installs from total), 0), 1) as pct_of_new_installs,
       percentile_cont(0.5) within group
         (order by public.analytics_num(e.props, 'hours_since_install')) as median_hours
from public.analytics_ev e
join public.analytics_installs i on i.install_id = e.install_id
where e.event = 'milestone' and not i.preexisting
group by 1;

-- ── Retención ──────────────────────────────────────────────────────────

-- Por semana de instalación. D1: volvió al día siguiente. D7: volvió entre
-- el día 7 y el 13. D30: entre el 30 y el 59. Null mientras la cohorte no
-- tenga edad para medirlo.
create or replace view public.analytics_retention_cohorts
with (security_invoker = true) as
with installs as (
  select install_id,
         (first_seen at time zone 'America/Lima')::date as first_day
  from public.analytics_installs
  where channel <> 'debug' and not preexisting
), flags as (
  select i.install_id, i.first_day,
         bool_or(e.day - i.first_day = 1)                    as d1,
         bool_or(e.day - i.first_day between 7 and 13)       as d7,
         bool_or(e.day - i.first_day between 30 and 59)      as d30
  from installs i
  left join public.analytics_ev e on e.install_id = i.install_id
  group by i.install_id, i.first_day
)
select date_trunc('week', first_day)::date as cohort_week,
       count(*) as installs,
       case when max(first_day) <= current_date - 1 then
         round(100.0 * count(*) filter (where d1) / count(*), 1) end  as d1_pct,
       case when max(first_day) <= current_date - 13 then
         round(100.0 * count(*) filter (where d7) / count(*), 1) end  as d7_pct,
       case when max(first_day) <= current_date - 59 then
         round(100.0 * count(*) filter (where d30) / count(*), 1) end as d30_pct
from flags
group by 1;

-- Qué trae a la gente de vuelta: ícono, notificación, widget, enlace.
create or replace view public.analytics_open_sources_daily
with (security_invoker = true) as
select day, props ->> 'source' as source,
       count(*) as opens, count(distinct install_id) as installs
from public.analytics_ev
where event = 'app_open'
group by 1, 2;

-- A qué hora se abre la app.
create or replace view public.analytics_open_hours_30d
with (security_invoker = true) as
select public.analytics_num(props, 'hour')::integer as hour, count(*) as opens
from public.analytics_ev
where event = 'app_open' and occurred_at > now() - interval '30 days'
group by 1;

-- Notificaciones: enviadas (las que arma el teléfono) y abiertas.
create or replace view public.analytics_notifications_daily
with (security_invoker = true) as
select day, props ->> 'type' as type,
       count(*) filter (where event = 'notification_sent')   as sent,
       count(*) filter (where event = 'notification_opened') as opened
from public.analytics_ev
where event in ('notification_sent', 'notification_opened')
group by 1, 2;

-- ── Pro ────────────────────────────────────────────────────────────────

-- Qué función bloqueada vende: paywall mostrado → prueba iniciada.
create or replace view public.analytics_paywall_daily
with (security_invoker = true) as
select day, coalesce(props ->> 'feature', 'general') as feature,
       count(*) filter (where event = 'paywall_shown')     as shown,
       count(distinct install_id) filter (where event = 'paywall_shown') as installs_shown,
       count(*) filter (where event = 'pro_trial_started') as trials
from public.analytics_ev
where event in ('paywall_shown', 'pro_trial_started')
  -- El interruptor «Premium (pruebas)» no es una conversión.
  and coalesce(props ->> 'source', '') <> 'test_switch'
group by 1, 2;

create or replace view public.analytics_paywall_30d
with (security_invoker = true) as
select coalesce(props ->> 'feature', 'general') as feature,
       count(distinct install_id) filter (where event = 'paywall_shown')     as installs_shown,
       count(distinct install_id) filter (where event = 'pro_trial_started') as installs_trial,
       round(100.0 * count(distinct install_id) filter (where event = 'pro_trial_started')
             / nullif(count(distinct install_id) filter (where event = 'paywall_shown'), 0), 1) as pct_conversion
from public.analytics_ev
where event in ('paywall_shown', 'pro_trial_started')
  and coalesce(props ->> 'source', '') <> 'test_switch'
  and occurred_at > now() - interval '30 days'
group by 1;

-- Pro que no usa nada Pro: lo vas a perder al renovar.
create or replace view public.analytics_pro_feature_usage_daily
with (security_invoker = true) as
select day, props ->> 'feature' as feature, count(distinct install_id) as installs
from public.analytics_ev
where event = 'pro_feature_used'
group by 1, 2;

create or replace view public.analytics_pro_engagement_30d
with (security_invoker = true) as
with pro as (
  select distinct install_id from public.analytics_ev
  where is_pro and occurred_at > now() - interval '30 days'
), using_pro as (
  select install_id, count(distinct props ->> 'feature') as features
  from public.analytics_ev
  where event = 'pro_feature_used' and occurred_at > now() - interval '30 days'
  group by install_id
)
select count(*)                                           as pro_installs,
       count(u.install_id)                                as using_pro_features,
       count(*) - count(u.install_id)                     as not_using_pro_features,
       round(avg(coalesce(u.features, 0)), 2)             as avg_features
from pro p
left join using_pro u on u.install_id = p.install_id;

create or replace view public.analytics_themes_30d
with (security_invoker = true) as
select props ->> 'theme' as theme, count(*) as changes, count(distinct install_id) as installs
from public.analytics_ev
where event = 'theme_changed' and occurred_at > now() - interval '30 days'
group by 1;

-- ── Ajustes y estado (foto diaria más reciente de cada instalación) ────

create or replace view public.analytics_adoption_latest
with (security_invoker = true) as
with latest as (
  select distinct on (install_id) install_id, props
  from public.analytics_ev
  where event = 'daily_snapshot' and occurred_at > now() - interval '14 days'
  order by install_id, occurred_at desc
)
select count(*)                                                                     as installs,
       round(100.0 * count(*) filter (where props -> 'gmail' = 'true'::jsonb) / nullif(count(*), 0), 1)          as pct_gmail,
       round(100.0 * count(*) filter (where props -> 'outlook' = 'true'::jsonb) / nullif(count(*), 0), 1)        as pct_outlook,
       round(100.0 * count(*) filter (where props -> 'pro' = 'true'::jsonb) / nullif(count(*), 0), 1)            as pct_pro,
       round(100.0 * count(*) filter (where props -> 'app_lock' = 'true'::jsonb) / nullif(count(*), 0), 1)       as pct_app_lock,
       round(100.0 * count(*) filter (where props -> 'notifications' = 'true'::jsonb) / nullif(count(*), 0), 1)  as pct_notifications,
       round(100.0 * count(*) filter (where public.analytics_num(props, 'widgets') > 0) / nullif(count(*), 0), 1) as pct_widgets,
       round(100.0 * count(*) filter (where props -> 'budget' = 'true'::jsonb) / nullif(count(*), 0), 1)         as pct_budget,
       round(100.0 * count(*) filter (where public.analytics_num(props, 'friends') > 0) / nullif(count(*), 0), 1) as pct_with_friends,
       round(100.0 * count(*) filter (where public.analytics_num(props, 'rules') > 0) / nullif(count(*), 0), 1)   as pct_with_rules,
       round(avg(public.analytics_num(props, 'rules')), 1)                                                        as avg_rules
from latest;

-- ── Calidad técnica ────────────────────────────────────────────────────

create or replace view public.analytics_launch_perf_daily
with (security_invoker = true) as
select day, app_version,
       count(*) as launches,
       percentile_cont(0.5) within group (order by public.analytics_num(props, 'ms')) as p50_ms,
       percentile_cont(0.9) within group (order by public.analytics_num(props, 'ms')) as p90_ms
from public.analytics_ev
where event = 'perf_launch'
group by 1, 2;

create or replace view public.analytics_screen_perf_daily
with (security_invoker = true) as
select day, props ->> 'screen' as screen, count(*) as samples,
       percentile_cont(0.5) within group (order by public.analytics_num(props, 'ms')) as p50_ms,
       percentile_cont(0.9) within group (order by public.analytics_num(props, 'ms')) as p90_ms
from public.analytics_ev
where event = 'perf_screen'
group by 1, 2;

-- Crashes y cuelgues (MetricKit) y congelamientos del hilo principal
-- (vigilante propio, también con la app abierta en Xcode).
create or replace view public.analytics_stability_daily
with (security_invoker = true) as
select day, app_version,
       count(*) filter (where event = 'metrickit_diagnostic' and props ->> 'kind' = 'crash') as crashes,
       count(*) filter (where event = 'metrickit_diagnostic' and props ->> 'kind' = 'hang')  as hangs_metrickit,
       count(*) filter (where event = 'main_hang')                                          as main_hangs,
       count(distinct install_id) filter (where event in ('metrickit_diagnostic', 'main_hang')) as installs_affected
from public.analytics_ev
where event in ('metrickit_diagnostic', 'main_hang')
group by 1, 2;

create or replace view public.analytics_metrickit_daily
with (security_invoker = true) as
select day, app_version, count(*) as reports,
       round(avg(public.analytics_num(props, 'launch_ms')))       as avg_launch_ms,
       round(avg(public.analytics_num(props, 'resume_ms')))       as avg_resume_ms,
       round(avg(public.analytics_num(props, 'hang_ms')))         as avg_hang_ms,
       round(avg(public.analytics_num(props, 'peak_memory_mb')))  as avg_peak_memory_mb,
       sum(public.analytics_num(props, 'fg_abnormal_exits'))      as fg_abnormal_exits
from public.analytics_ev
where event = 'metrickit_metrics'
group by 1, 2;

create or replace view public.analytics_errors_daily
with (security_invoker = true) as
select day, props ->> 'domain' as domain, props ->> 'code' as code,
       count(*) as errors, count(distinct install_id) as installs
from public.analytics_ev
where event = 'app_error'
group by 1, 2, 3;

create or replace view public.analytics_unlock_daily
with (security_invoker = true) as
select day, props ->> 'result' as result, count(*) as attempts, count(distinct install_id) as installs
from public.analytics_ev
where event = 'unlock_result'
group by 1, 2;

-- Versiones en uso (últimos 7 días).
create or replace view public.analytics_versions_7d
with (security_invoker = true) as
select app_version, channel, count(distinct install_id) as installs
from public.analytics_ev
where occurred_at > now() - interval '7 days'
group by 1, 2;

-- ── Permisos de las vistas ─────────────────────────────────────────────

do $$
declare
  v record;
begin
  for v in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v' and c.relname like 'analytics\_%'
  loop
    execute format('revoke all on public.%I from anon', v.relname);
    execute format('grant select on public.%I to authenticated, service_role', v.relname);
  end loop;
end $$;
