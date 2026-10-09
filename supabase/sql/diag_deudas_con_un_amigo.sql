-- Diagnóstico: qué deudas, pagos y recordatorios hay entre tú y un amigo.
-- Sólo lee. Córrelo en el editor SQL de Supabase (ahí no hay RLS: se ve todo).
-- Cambia los dos nombres de abajo si hace falta; se busca por parecido.

with yo as (
  select id from public.profiles where display_name ilike '%joseph%' limit 1
), amigo as (
  select id from public.profiles where display_name ilike '%alejo%' limit 1
)

-- 1. Deudas (debt_shares) en cualquier sentido
select 'deuda' as que, s.id, s.merchant, s.amount, s.paid_amount, s.status,
       case when s.creditor = (select id from yo) then 'él te debe' else 'tú le debes' end as sentido,
       s.debt_key, s.created_at, s.closed_at
from public.debt_shares s
where (s.creditor = (select id from yo) and s.debtor = (select id from amigo))
   or (s.creditor = (select id from amigo) and s.debtor = (select id from yo))

union all

-- 2. Recordatorios abiertos o cerrados (lo que él ve como «te cobró»)
select 'recordatorio', r.id, r.merchant, r.amount, null,
       case when r.dismissed_at is null then 'abierto' else 'cerrado' end,
       case when r.from_user = (select id from yo) then 'le cobraste' else 'te cobró' end,
       r.debt_key, r.created_at, r.dismissed_at
from public.payment_reminders r
where (r.from_user = (select id from yo) and r.to_user = (select id from amigo))
   or (r.from_user = (select id from amigo) and r.to_user = (select id from yo))
order by created_at desc;

-- 3. Pagos de esas deudas (aparte, porque tienen otras columnas)
-- select p.*, s.merchant from public.debt_payments p
-- join public.debt_shares s on s.id = p.share_id
-- where s.merchant ilike '%taxi%';

-- ── Limpiar el taxi de prueba (escribe; quita los comentarios para correrlo) ──
-- Revisa antes con la consulta de arriba que sólo salga el taxi.
--
-- delete from public.debt_shares
--  where merchant ilike '%taxi%'
--    and creditor = (select id from public.profiles where display_name ilike '%joseph%' limit 1);
-- delete from public.payment_reminders
--  where merchant ilike '%taxi%'
--    and from_user = (select id from public.profiles where display_name ilike '%joseph%' limit 1);
