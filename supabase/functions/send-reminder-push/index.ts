// AgruPay · Edge Function `send-reminder-push`
//
// Manda la notificación de un recordatorio de cobro a los teléfonos del amigo.
// La app primero llama al RPC `send_payment_reminders` (que comprueba la
// amistad y el tope de uno por día) y después llama aquí con los ids que ese
// RPC devolvió. Aquí no se decide nada: sólo se entrega.
//
// Variables de entorno (Supabase › Edge Functions › Secrets):
//   APNS_KEY          contenido del .p8 de APNs, con sus líneas BEGIN/END
//   APNS_KEY_ID       los 10 caracteres del nombre del .p8
//   APNS_TEAM_ID      el Team ID de la cuenta de desarrollador
//   APNS_BUNDLE_ID    clmilo.Notifable
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   los pone Supabase solo
//
// Desplegar:  supabase functions deploy send-reminder-push
//
// Estilo de mensaje de iOS (`1a` de «Cobros entre amigos»): el aviso lleva
// `mutable-content` y los datos de quien cobra (`sender`) para que la
// extensión `NotifableNotificationService` le ponga la cara de su personaje y
// deje el ícono de la app de insignia. Sin la extensión se ve igual de claro:
// el título ya es el nombre y el cuerpo dice de cuánto es.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const APNS_KEY = Deno.env.get("APNS_KEY") ?? "";
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID") ?? "";
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "";
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "clmilo.Notifable";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// ── APNs ────────────────────────────────────────────────────────────────

// El token de APNs vale 1 h; se guarda mientras el contenedor siga vivo para
// no firmar uno por notificación (APNs rechaza si se piden demasiados).
let cachedToken: { value: string; madeAt: number } | null = null;

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function apnsToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now - cachedToken.madeAt < 45 * 60) return cachedToken.value;

  const pem = APNS_KEY.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );

  const header = base64url(new TextEncoder().encode(
    JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID }),
  ));
  const payload = base64url(new TextEncoder().encode(
    JSON.stringify({ iss: APNS_TEAM_ID, iat: now }),
  ));
  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key,
    new TextEncoder().encode(`${header}.${payload}`),
  ));

  const value = `${header}.${payload}.${base64url(signature)}`;
  cachedToken = { value, madeAt: now };
  return value;
}

/// Devuelve `true` si el token del teléfono ya no sirve y hay que borrarlo.
async function push(deviceToken: string, environment: string, body: unknown): Promise<boolean> {
  const host = environment === "sandbox"
    ? "https://api.sandbox.push.apple.com"
    : "https://api.push.apple.com";

  const response = await fetch(`${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await apnsToken()}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (response.ok) return false;
  const text = await response.text();
  console.error("APNs", response.status, text, deviceToken.slice(0, 8));
  // 410: el teléfono desinstaló la app. 400 BadDeviceToken: token de otro
  // entorno o inválido. En los dos casos, el token ya no sirve.
  return response.status === 410 || text.includes("BadDeviceToken");
}

// ── Petición ────────────────────────────────────────────────────────────

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const authorization = request.headers.get("Authorization") ?? "";
    if (!authorization) return json({ error: "Sin sesión" }, 401);

    // Quién llama, según su propio token de sesión.
    const asUser = createClient(SUPABASE_URL, SERVICE_KEY, {
      global: { headers: { Authorization: authorization } },
    });
    const { data: userData } = await asUser.auth.getUser();
    const sender = userData?.user?.id;
    if (!sender) return json({ error: "Sin sesión" }, 401);

    const { reminder_ids } = await request.json();
    const ids: string[] = Array.isArray(reminder_ids) ? reminder_ids.slice(0, 20) : [];
    if (ids.length === 0) return json({ sent: 0 });

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // Sólo los recordatorios que de verdad mandó quien llama. Sin el SQL v11
    // no existe `intensity`: se piden sin ella y todos van como suaves.
    const columns = "id, to_user, merchant, occurred_on, amount, currency, message, dismissed_at";
    const pick = (select: string) => admin
      .from("payment_reminders")
      .select(select)
      .in("id", ids)
      .eq("from_user", sender)
      .is("dismissed_at", null);
    let { data: reminders, error: remindersError } = await pick(`${columns}, intensity`);
    if (remindersError) ({ data: reminders } = await pick(columns));

    if (!reminders?.length) return json({ sent: 0 });

    // `avatar` (personaje completo) llegó con amigos v7; antes sólo `penguin`.
    let { data: profile, error: profileError } = await admin
      .from("profiles").select("display_name, avatar, penguin").eq("id", sender).maybeSingle();
    if (profileError) {
      ({ data: profile } = await admin
        .from("profiles").select("display_name").eq("id", sender).maybeSingle());
    }
    const senderName = profile?.display_name?.trim() || "Un amigo";
    const senderLook = profile?.avatar ?? profile?.penguin ?? null;

    let sent = 0;
    const staleTokens: string[] = [];

    for (const reminder of reminders) {
      const { data: devices } = await admin
        .from("device_tokens").select("token, environment").eq("user_id", reminder.to_user);
      if (!devices?.length) continue;

      const money = reminder.amount == null
        ? null
        : `${reminder.currency === "USD" ? "$" : "S/"} ${Number(reminder.amount).toFixed(2)}`;
      // Como un mensaje: «Vale» arriba, y debajo de cuánto es y por qué.
      const detail = [reminder.merchant, reminder.message ? `«${reminder.message}»` : null]
        .filter(Boolean).join(" · ");
      const lead = money ? `Te recuerda un pago de ${money}` : "Te recuerda un pago";

      const body = {
        aps: {
          alert: {
            title: senderName,
            body: detail ? `${lead}\n${detail}` : lead,
          },
          sound: "default",
          "thread-id": "payment-reminder",
          "mutable-content": 1,
        },
        deepLink: "agrupay://amigos",
        reminderId: reminder.id,
        intensity: reminder.intensity ?? "soft",
        sender: { id: sender, name: senderName, look: senderLook },
      };

      for (const device of devices) {
        const stale = await push(device.token, device.environment, body);
        if (stale) staleTokens.push(device.token);
        else sent += 1;
      }
    }

    if (staleTokens.length) {
      await admin.from("device_tokens").delete().in("token", staleTokens);
    }

    return json({ sent });
  } catch (error) {
    console.error(error);
    return json({ error: String(error) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
  });
}
