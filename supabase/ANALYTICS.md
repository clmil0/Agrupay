# Analítica de uso de AgruPay

La app manda eventos anónimos a Supabase y el panel los lee de vistas ya
agregadas. Las piezas son:

| Pieza | Dónde |
|---|---|
| Cliente (cola, lotes, ID anónimo, interruptor) | `Notifable/Notifable/Core/Analytics.swift` |
| Catálogo de eventos y ayudantes (pantallas, hitos, clasificación, MetricKit) | `Notifable/Notifable/Core/AnalyticsTracking.swift` |
| Tablas, entrada, permisos y vistas | `supabase/sql/agrupay_analytics_v16.sql` |

## Puesta en marcha

La analítica vive en su **propio proyecto de Supabase**, `Agrupay_Analytics` (`https://zxfeixwrruclypwjuhnl.supabase.co`), separado de la base de la app: cualquiera con la llave publicable puede escribir eventos, y así un relleno o el crecimiento de la tabla nunca toca el disco de los datos de la app. `Analytics.swift` tiene su propia URL y llave; no uses aquí las del proyecto principal.

El panel web está en https://clmil0.github.io/agrupay-analytics/ (repo `clmil0/agrupay-analytics`).

1. Corre `supabase/sql/agrupay_analytics_v16.sql` en el editor SQL del proyecto de analítica. No depende de v15 ni de otras tablas. Se puede correr más de una vez.
2. Hazte administrador para leer desde un panel en el navegador, con tu sesión de Google:
   ```sql
   insert into public.analytics_admins (user_id)
   select id from auth.users where email = 'tu-correo@gmail.com';
   ```
3. Opcional: borra lo viejo cada semana con pg_cron.
   ```sql
   select cron.schedule('analytics-prune', '0 4 * * 1', $$select public.analytics_prune(400)$$);
   ```

Antes del paso 1, la app recibe un 404, descarta el lote y no reintenta: no se acumula nada en el teléfono.

## Cómo leer desde el panel

- **Con la llave publicable + sesión de administrador** (panel en el navegador): `select` sobre las vistas `analytics_*`. Quien no está en `analytics_admins` recibe cero filas.
- **Con `service_role`** (sólo en un servidor o una Edge Function, nunca en el navegador): lee todo.
- `anon` sólo puede ejecutar `ingest_analytics`; no lee ni una fila.

Los días y las semanas de las vistas están en hora de Lima (`America/Lima`) y la semana empieza el lunes. Las vistas **excluyen el canal `debug`** (el simulador) y sí incluyen `development` (un iPhone de verdad con un build de Xcode), TestFlight y App Store. Para separar esos dos, consulta `analytics_ev` filtrando por `channel`.

## Modelo de datos

`analytics_events`: una fila por evento.

| Columna | Qué es |
|---|---|
| `install_id` | UUID aleatorio de la instalación. No es la cuenta de Google ni la de Amigos. |
| `session_id` | Cambia cuando la app vuelve tras más de 30 min en segundo plano. |
| `event` | Nombre del evento (ver catálogo). |
| `props` | Objeto JSON con las propiedades del evento. |
| `is_pro` | Si era Pro al ocurrir. |
| `occurred_at` | Cuándo pasó, según el teléfono (limitado a «ahora» y a 30 días atrás). |
| `app_version`, `build`, `os`, `device`, `locale`, `tz` | Contexto del lote. |
| `channel` | `debug` (simulador), `development` (iPhone con build de Xcode), `testflight` o `appstore`. |

`analytics_installs`: una fila por instalación, con `first_seen`, `last_seen`, versiones, canal y `preexisting`. `preexisting = true` significa que ya usaba la app antes de que existiera la analítica: las vistas de activación y retención lo excluyen.

`analytics_ev` es la vista base: los eventos sin `debug`, con las columnas `day`, `week`, `month` y `local_ts` ya calculadas en hora de Lima.

## Catálogo de eventos

Las propiedades marcadas con `?` no siempre vienen. Las categorías propias del usuario llegan como `personalizada`; las que no tienen categoría, como `sin_clasificar`.

### Uso

| Evento | Props | Cuándo |
|---|---|---|
| `app_open` | `source` (`icon`, `notification`, `link`, `invite`), `cold`, `hour`, `notification?`, `link?` | Al volver al frente desde segundo plano o al arrancar. `link` sale de los widgets y la app Atajos (`agrupay://`). |
| `screen_view` | `screen`, `seconds`, `cont` | Al cerrar una pantalla. `cont = true` es la continuación tras volver de segundo plano: para contar visitas usa sólo `cont = false`; para tiempo, súmalas todas. |
| `tap` | `target`, más props según el caso | Toques concretos: `tabbar.add`, `summary.card` (`section`), `summary.settings`, `summary.assistant`, `onboarding.skip`, `appearance.locked_theme`. |
| `tab_select` | `tab` (`summary`, `movements`, `goals`, `friends`) | Al cambiar de pestaña. |
| `section_select` | `section` | Al cambiar en la píldora (Movimientos ↔ Pendientes ↔ Análisis; Amigos ↔ Cobros ↔ Perfil). |
| `period_change` | `screen` (`dashboard`, `history`, `category_detail`), `granularity` (`day`, `week`, `month`, `year`, `range`), `months_back`, `offset?`, `window_months_back?` | Al moverse de periodo. `months_back` es cuántos meses atrás empieza lo elegido (0 = este mes). |
| `chart_mode` | `mode` (`Días`, `Semanas`, `Meses`) | Menú del gráfico del Resumen. |
| `feature_used` | `feature`, más props según el caso | Cada uso de una función (lista abajo). |
| `feature_first_use` | `feature`, `days_since_install` | El primer uso por instalación: descubrimiento. |

Nombres de `screen`: `summary`, `summary/<sección>`, `movements/<sección>`, `friends/<sección>`, `goals`, `settings`, `settings/<título de la fila>`, `add_movement`, `dictation`, `expense_detail`, `income_detail`, `category_detail`, `assistant`, `split`, `bulk_classify`, `paywall`, `stat_sheet`, `recurring`, `recurring_confirm`, `assign_category`, `onboarding`, `category_limit`, `range_sync`, `reminder_composer`.

Valores de `feature`: `dictation`, `mic_hold`, `hide_amounts`, `pending_inbox`, `split`, `assistant`, `bulk_classify`, `tags`, `categories`, `category_detail`, `analysis`, `recurring`, `category_limit`, `range_sync`, `friends`, `receivables`, `payment_reminder`, `invite`, `export`, `app_lock`, `pro_theme`, `stat_sheet`, `account_filter`, `siri`.

### Motor de correo

| Evento | Props | Cuándo |
|---|---|---|
| `email_parse` | `bank`, `kind` (`expense`, `income`), `result` (`inserted`, `duplicate`, `amount_missing`), `provider?`, `range?`, `latency_min?`, `auto?` (`rule`, `keyword`, `none`), `reversal?` | Por cada correo de banco reconocido. Si sube `amount_missing`, ese banco cambió su formato. `latency_min` sólo viene en lecturas normales, no en las de un rango pasado. |
| `email_sync_run` | `range`, `checked`, `new`, `already`, `unrecognized`, `failed_fetch`, `retries`, `seconds`, `quiet` | Por cada lectura que procesó algo. El sondeo vacío de cada 10 s no manda nada. |
| `account_connect_started` | `provider` | Al abrir la ventana de Google o Microsoft. |
| `account_connected` | `provider`, `read_scope` | Token conseguido. `read_scope = false`: dejó sin marcar el permiso de Gmail. |
| `account_connect_failed` | `provider`, `reason` (`cancelled`, `auth_window`, `no_code`, `network`, `token_exchange`) | Cuando falla la conexión. |
| `account_disconnected` | `provider`, `reason` (`user`, `revoked`) | `revoked` = el permiso dejó de valer (contraseña cambiada, acceso quitado). Es la señal de abandono más clara. |
| `range_sync` | `origin` (`settings`, `link_flow`), `months`, `days?` | Al pedir leer un rango pasado. |

### Clasificación

| Evento | Props | Cuándo |
|---|---|---|
| `movement_created` | `source` (`form`, `form_locked`, `quick`, `voice`, `siri`, `recurring`), `kind`, `category_source?` (`user`, `prefilled`, `voice`, `keyword`, `recurring`, `quick`, `none`), `category?`, más props según el caso | Un movimiento que no vino del correo. |
| `movement_classified` | `via` (`detail`, `pending_suggestion`, `pending_sheet`, `bulk`, `bulk_suggestions`, `selection`), `category`, `count`, `from_pending`, `reclassified`, `rule_created` | El usuario puso o cambió la categoría. `from_pending` son los que salieron de Pendientes; `reclassified`, los que ya tenían otra. |
| `movement_unclassified` | `via` | «Quitar categoría». |
| `classification_corrected` | `engine` (`rule`, `keyword`, `voice`, `recurring`), `count`, `via`, `category` | El usuario cambió una categoría que puso un motor automático. Sirve para medir la precisión real de cada motor. |
| `suggestion_shown` | `kind` (`rule`, `root`, `catalog`), `confidence`, `category`, `screen` (`pending`, `bulk`) | Una vez al día por comercio y pantalla. |
| `suggestion_accepted` / `suggestion_dismissed` | `kind`, `confidence`, `category`, `screen` (`pending`, `bulk`, `assign_sheet`) | «Sí» u «Otra» en Pendientes, aceptar en bloque, o elegir otra categoría distinta a la sugerida en la hoja. |
| `rule_created` | `origin` (`pending`, `bulk`, `detail`, `add_form`), `count` | Reglas de comercio nuevas. |

El automático que llega del correo se cuenta con `email_parse.auto`. El de voz, Siri y recurrentes, con `movement_created.category_source`.

### Activación y retención

| Evento | Props | Cuándo |
|---|---|---|
| `onboarding_step` | `step` | Una vez por instalación y paso: `slide_1`, `slide_2`, `slide_3`, `login`, `connect_tapped`, `connected`, `no_account`, `restore_offered`, `history`, `reading`, `finished`. También `restore_accepted` y `restore_declined`. |
| `onboarding_completed` | `with_account`, `restored`, `read_months` | Al entrar a la app. |
| `milestone` | `name` (`first_movement`, `first_email_movement`, `first_classification`, `first_rule`, `first_friend`), `hours_since_install` | Una vez por instalación. |
| `notification_sent` | `type` | Avisos que arma el teléfono (`imported`). |
| `notification_opened` | `type` (`imported`, `payment_reminder`, `debt_reminder`, `recurring`, `budget`, `category_limit`, `other`) | Al tocar un aviso. |
| `daily_snapshot` | `pending_total`, `pending_month`, `movements_month`, `movements_month_email`, `movements_total`, `categories_used_month`, `rules`, `recurring_rules`, `gmail`, `outlook`, `pro`, `pro_theme`, `app_lock`, `hide_amounts_on_launch`, `budget`, `friends`, `cloud_backup`, `notifications`, `widgets`, `days_since_install` | Una vez al día, la primera vez que se abre la app. Sirve para medir estados (cuántos tienen Face ID, widgets, etc.) y el atasco de Pendientes. |

### Pro

| Evento | Props | Cuándo |
|---|---|---|
| `paywall_shown` | `feature` (`history`, `ai`, `alerts`, `cloud`, `sync`, `themes`, `profile`, `general`) | Al abrir el paywall, con la función que lo abrió. |
| `paywall_dismissed` | `feature`, `plan`, `seconds` | Al cerrarlo sin probar. |
| `pro_trial_started` | `feature`, `plan`, `seconds` | «Probar 7 días gratis». |
| `pro_cancelled` | `plan` | Volver a Gratis. |
| `pro_feature_used` | `feature` | Una vez al día por función, sólo siendo Pro: `history` (mirar o leer ≥ 3 meses atrás), `ai` (asistente), `alerts` (cobro intenso), `cloud` (respaldo activo), `themes` (tema Pro puesto), `profile` (perfil Pro publicado). |
| `theme_changed` | `theme`, `pro` | Al elegir un tema. |

### Calidad

| Evento | Props | Cuándo |
|---|---|---|
| `perf_launch` | `ms`, `prewarmed` | Del toque en el ícono al primer dibujo, una vez por arranque. |
| `perf_screen` | `screen` (`dashboard_catalog`), `ms` | Lo que tarda en cargar lo más pesado del Resumen, una vez por arranque. |
| `main_hang` | `seconds` | El hilo principal estuvo congelado 2 s o más (vigilante propio). |
| `metrickit_diagnostic` | `kind` (`crash`, `hang`, `cpu`, `disk`), `build`, `exception_type?`, `signal?`, `reason?`, `seconds?`, `count?` | Lo que iOS entrega en la apertura siguiente. |
| `metrickit_metrics` | `build`, `launch_ms?`, `resume_ms?`, `hang_ms?`, `peak_memory_mb?`, `foreground_min?`, `fg_abnormal_exits?`, `fg_normal_exits?` | El informe diario de iOS. |
| `app_error` | `domain`, `code`, más props según el caso | `sync_list` (`transient`/`failed`, `provider`), `sync_fetch` (`message_download`, `count`), `payment_reminder` (`send_failed`). El mismo error sale como mucho cada 10 minutos. |
| `unlock_result` | `result` (`ok`, `cancelled`, `not_recognized`, `lockout`, …), `passcode` | Cada intento de desbloquear con Face ID. |

## Vistas

Las `_daily` traen una fila por día para filtrar por rango en el panel; las `_30d` ya vienen resumidas para los últimos 30 días.

| Pregunta | Vista |
|---|---|
| Usuarios activos (DAU, WAU, MAU) | `analytics_daily_active`, `analytics_weekly_active`, `analytics_monthly_active` |
| Instalaciones nuevas | `analytics_new_installs_daily` |
| Qué pantallas se usan y cuánto tiempo | `analytics_screens_daily`, `analytics_screens_30d` |
| Dónde se toca más | `analytics_taps_daily`, `analytics_taps_30d` |
| Pestañas y secciones | `analytics_navigation_daily` |
| Cuántos meses atrás se mira | `analytics_period_choices_daily`, `analytics_period_choices_30d`, `analytics_max_months_back_30d` |
| Días / Semanas / Meses del gráfico | `analytics_chart_modes_30d` |
| Qué funciones se descubren y en cuántos días | `analytics_feature_discovery`, `analytics_feature_usage_daily` |
| Salud de los lectores por banco | `analytics_parser_health_daily` |
| Lecturas del correo y % sin reconocer | `analytics_sync_runs_daily` |
| Minutos entre correo y movimiento (p50/p90) | `analytics_email_latency_daily` |
| Conexiones y desconexiones de correo | `analytics_accounts_daily` |
| Cuánto se clasifica a mano por día | `analytics_classification_daily` |
| Cuánto clasifica cada persona por semana | `analytics_classification_weekly` |
| Automático contra manual | `analytics_auto_vs_manual_daily` |
| Precisión de cada motor automático | `analytics_auto_accuracy_30d` |
| Sugerencias mostradas, aceptadas y descartadas | `analytics_suggestions_daily`, `analytics_suggestions_30d` |
| Reglas creadas | `analytics_rules_daily` |
| Atasco de Pendientes | `analytics_pending_backlog_daily` |
| De dónde salen los movimientos manuales | `analytics_movements_created_daily` |
| Embudo del onboarding por cohorte | `analytics_onboarding_funnel` |
| Hitos de activación y horas hasta lograrlos | `analytics_activation_milestones` |
| Retención D1 / D7 / D30 por cohorte | `analytics_retention_cohorts` |
| Qué trae a la gente de vuelta | `analytics_open_sources_daily`, `analytics_open_hours_30d` |
| Notificaciones enviadas y abiertas | `analytics_notifications_daily` |
| Paywall: qué función vende | `analytics_paywall_daily`, `analytics_paywall_30d` |
| Uso de funciones Pro | `analytics_pro_feature_usage_daily`, `analytics_pro_engagement_30d`, `analytics_themes_30d` |
| Adopción de ajustes (Face ID, widgets, Gmail…) | `analytics_adoption_latest` |
| Arranque y carga | `analytics_launch_perf_daily`, `analytics_screen_perf_daily`, `analytics_metrickit_daily` |
| Crashes y cuelgues | `analytics_stability_daily` |
| Errores | `analytics_errors_daily` |
| Face ID | `analytics_unlock_daily` |
| Versiones en uso | `analytics_versions_7d` |

Retención: D1 = volvió al día siguiente de instalar; D7 = volvió entre el día 7 y el 13; D30 = entre el día 30 y el 59. Una cohorte demasiado joven para medirlo devuelve `null`.

## Privacidad y App Store

- Nunca salen del teléfono montos, comercios, textos de correos, nombres de amigos, lo que se dicta ni las categorías propias.
- El usuario lo apaga en Configuración › Ayuda › «Compartir estadísticas de uso». Al apagarlo se borra lo pendiente.
- «Enviar estadísticas ahora», en la misma sección, manda todo lo pendiente al momento y muestra cuántos eventos salieron, el error si falló y el inicio del `install_id` para encontrar ese teléfono en el panel.
- El modo QA (`-qaFakeData`) no manda nada.
- Etiqueta de privacidad de App Store Connect: **Datos de uso › Interacción con el producto** y **Diagnósticos › Datos de fallos y de rendimiento**, en ambos casos «no vinculados a la identidad» y «no se usan para rastrear».

## Añadir un evento

1. Agrega el caso a `AnalyticsEvent` en `AnalyticsTracking.swift`.
2. Llama `Analytics.track(.nuevo, ["prop": valor])`. Las props sólo pueden ser `String`, `Int`, `Double` o `Bool`, con un máximo de 24.
3. Documéntalo aquí y, si hace falta, agrega una vista en una SQL nueva (v17…).
