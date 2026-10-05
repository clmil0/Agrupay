-- ============================================================
-- AgruPay · Perfil Pro en Social v15
-- ============================================================
-- Corre esto DESPUÉS de v14. Idempotente.
--
-- Qué añade
-- `profiles.social_style` (jsonb): cómo se ve tu tarjeta para tus amigos.
--   {
--     "pro": true,            -- si eras Pro al guardarlo; sin Pro, tus
--                             -- amigos sólo ven la cabecera básica
--     "banner": 3,            -- cabecera básica (0–7)
--     "theme": "aurora",      -- tema Pro del cielo, aura, fondo y marco
--     "skyHeader": true,      -- la cabecera es el cielo del tema
--     "aura": "theme",        -- none | theme | halo | gold
--     "background": "sphere", -- plain | theme | sphere | gold
--     "frame": "glow",        -- none | glow | gold
--     "entrance": "stars"     -- none | flash | hop | stars
--   }
--
-- No hace falta tocar RLS: `profiles` ya deja leer todas las filas y que
-- cada quien actualice la suya, y Realtime ya avisa de sus cambios. La app
-- prueba primero con la columna y, si el servidor la rechaza, sigue sin ella.
-- Nada financiero vive aquí.

alter table public.profiles
  add column if not exists social_style jsonb;

-- Que no se use como cajón: sólo un objeto, y pequeño.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_social_style_shape'
  ) then
    alter table public.profiles
      add constraint profiles_social_style_shape
      check (
        social_style is null
        or (jsonb_typeof(social_style) = 'object'
            and pg_column_size(social_style) <= 1024)
      );
  end if;
end $$;
