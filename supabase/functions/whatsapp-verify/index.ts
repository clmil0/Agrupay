// AgruPay · Edge Function `whatsapp-verify`
//
// El webhook de WhatsApp Cloud API. Verificación «al revés»: la app le da al
// usuario un código (`start_phone_verification`) y abre WhatsApp con el
// mensaje ya escrito hacia el número de AgruPay. Cuando lo envía, Meta llama
// aquí con el mensaje **y el número de quien lo mandó**; ese número queda
// verificado para esa cuenta (`confirm_phone_verification`).
//
// Recibir mensajes no se cobra. Por defecto no se contesta nada (una
// respuesta sí puede cobrarse); la app se entera sola por Realtime. Con
// WHATSAPP_REPLY=1 se contesta «Listo, tu número quedó verificado».
//
// Variables de entorno (Supabase › Edge Functions › Secrets):
//   WHATSAPP_VERIFY_TOKEN     cualquier texto largo; el mismo que pongas en Meta
//   WHATSAPP_APP_SECRET       App secret de la app de Meta (firma de cada aviso)
//   WHATSAPP_TOKEN            (sólo con WHATSAPP_REPLY=1) token de acceso
//   WHATSAPP_PHONE_NUMBER_ID  (sólo con WHATSAPP_REPLY=1) id del número
//   WHATSAPP_REPLY            "1" para contestar
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   los pone Supabase solo
//
// Desplegar (Meta no manda el JWT de Supabase):
//   supabase functions deploy whatsapp-verify --no-verify-jwt

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VERIFY_TOKEN = Deno.env.get("WHATSAPP_VERIFY_TOKEN") ?? "";
const APP_SECRET = Deno.env.get("WHATSAPP_APP_SECRET") ?? "";
const WA_TOKEN = Deno.env.get("WHATSAPP_TOKEN") ?? "";
const WA_PHONE_ID = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID") ?? "";
const REPLY = Deno.env.get("WHATSAPP_REPLY") === "1";

const CODE = /AGRU-[A-Z0-9]{6}/i;

const supabase = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false },
});

// ── Firma de Meta ───────────────────────────────────────────────────────

// Cada aviso llega firmado con el App secret (`X-Hub-Signature-256`). Sin
// esto, cualquiera que conozca la URL podría «verificar» el número que quiera.
async function signatureIsValid(raw: string, header: string | null): Promise<boolean> {
  if (!APP_SECRET || !header?.startsWith("sha256=")) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(APP_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw)));
  const expected = Array.from(mac).map((b) => b.toString(16).padStart(2, "0")).join("");
  const given = header.slice("sha256=".length);
  if (given.length !== expected.length) return false;
  // Comparación en tiempo constante.
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}

// ── Respuesta opcional ──────────────────────────────────────────────────

async function reply(to: string, text: string) {
  if (!REPLY || !WA_TOKEN || !WA_PHONE_ID) return;
  await fetch(`https://graph.facebook.com/v21.0/${WA_PHONE_ID}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${WA_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify({ messaging_product: "whatsapp", to, type: "text", text: { body: text } }),
  }).catch((error) => console.error("No se pudo contestar:", error));
}

// ── Webhook ─────────────────────────────────────────────────────────────

type IncomingMessage = { from?: string; type?: string; text?: { body?: string } };

Deno.serve(async (request) => {
  const url = new URL(request.url);

  // Meta comprueba la URL una vez, al configurar el webhook.
  if (request.method === "GET") {
    const ok = url.searchParams.get("hub.mode") === "subscribe"
      && VERIFY_TOKEN !== ""
      && url.searchParams.get("hub.verify_token") === VERIFY_TOKEN;
    return ok
      ? new Response(url.searchParams.get("hub.challenge") ?? "", { status: 200 })
      : new Response("Forbidden", { status: 403 });
  }

  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const raw = await request.text();
  if (!(await signatureIsValid(raw, request.headers.get("x-hub-signature-256")))) {
    return new Response("Bad signature", { status: 401 });
  }

  let payload: { entry?: { changes?: { value?: { messages?: IncomingMessage[] } }[] }[] };
  try {
    payload = JSON.parse(raw);
  } catch {
    return new Response("OK", { status: 200 });
  }

  const messages = (payload.entry ?? [])
    .flatMap((entry) => entry.changes ?? [])
    .flatMap((change) => change.value?.messages ?? []);

  for (const message of messages) {
    const from = message.from;
    const code = message.type === "text" ? message.text?.body?.match(CODE)?.[0] : undefined;
    if (!from || !code) continue;

    const { data, error } = await supabase.rpc("confirm_phone_verification", {
      p_code: code.toUpperCase(),
      p_phone: from,
    });
    if (error) {
      console.error("confirm_phone_verification:", error.message);
      continue;
    }
    // Nunca se registra el número entero en los logs.
    console.log(`Verificación ${data} para …${from.slice(-3)}`);

    if (data === "verified") {
      await reply(from, "Listo ✅ Tu número quedó verificado en AgruPay. Ya puedes volver a la app.");
    } else if (data === "expired") {
      await reply(from, "Ese código ya venció. Pide uno nuevo en la app.");
    }
  }

  // Siempre 200: si no, Meta reintenta el mismo aviso durante horas.
  return new Response("OK", { status: 200 });
});
