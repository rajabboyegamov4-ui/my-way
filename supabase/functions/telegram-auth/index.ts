// =====================================================================
//  MY WAY: telegram-auth  (Supabase Edge Function)
//  Telegram orqali kirish va mavjud akkauntga Telegramni ulash.
//  Kerakli secret: TELEGRAM_BOT_TOKEN
//  Sozlama: "Verify JWT" O'CHIRILGAN bo'lsin (tekshiruvni funksiya o'zi qiladi).
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

// Admin kaliti: eski (service_role) yoki yangi (sb_secret) tizim uchun
function adminKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (raw) { try { const o = JSON.parse(raw); const v = Object.values(o)[0]; if (typeof v === "string") return v; } catch { return raw; } }
  const own = Deno.env.get("MYWAY_SECRET_KEY");
  if (own) return own;
  throw new Error("admin_key_missing");
}

const BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// Telegram Login Widget ma'lumotini tekshirish (rasmiy algoritm)
async function verifyTelegram(data: Record<string, unknown>): Promise<boolean> {
  if (!BOT_TOKEN || !data || typeof data.hash !== "string") return false;
  const { hash, ...rest } = data;
  const checkString = Object.keys(rest)
    .filter((k) => rest[k] !== undefined && rest[k] !== null)
    .sort()
    .map((k) => `${k}=${rest[k]}`)
    .join("\n");
  const secret = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(BOT_TOKEN));
  const key = await crypto.subtle.importKey("raw", secret, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(checkString));
  const hex = [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (hex !== hash) return false;
  const age = Date.now() / 1000 - Number(rest.auth_date);
  return age >= 0 && age < 86400; // 24 soatdan eski ma'lumot qabul qilinmaydi
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const body = await req.json();
    const tg = body?.tg;
    const mode = body?.mode === "link" ? "link" : "login";
    if (!(await verifyTelegram(tg))) return json({ error: "invalid_telegram" }, 401);

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, adminKey(), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const tgId = Number(tg.id);
    const tgUser = typeof tg.username === "string" ? tg.username : null;
    const name = [tg.first_name, tg.last_name].filter(Boolean).join(" ").trim().slice(0, 40) || "Foydalanuvchi";

    const { data: owner } = await admin.from("profiles").select("id").eq("telegram_id", tgId).maybeSingle();

    // ---- Mavjud akkauntga Telegramni ulash ----
    if (mode === "link") {
      const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
      const { data: u, error } = await admin.auth.getUser(jwt);
      if (error || !u?.user) return json({ error: "not_authenticated" }, 401);
      if (owner && owner.id !== u.user.id) return json({ error: "telegram_taken" }, 409);
      const { error: upErr } = await admin.from("profiles")
        .update({ telegram_id: tgId, telegram_username: tgUser, tg_chat: true }).eq("id", u.user.id);
      if (upErr) throw upErr;
      return json({ ok: true });
    }

    // ---- Telegram orqali kirish ----
    let email: string;
    if (owner) {
      const { data: u, error } = await admin.auth.admin.getUserById(owner.id);
      if (error || !u?.user?.email) throw error ?? new Error("user_not_found");
      email = u.user.email;
    } else {
      email = `tg${tgId}@tg.myway.uz`;
      const { error: ce } = await admin.auth.admin.createUser({
        email, email_confirm: true, user_metadata: { name, phone: "" },
      });
      if (ce && !/already/i.test(ce.message)) throw ce;
    }
    const { data: link, error: le } = await admin.auth.admin.generateLink({ type: "magiclink", email });
    if (le || !link?.properties?.hashed_token) throw le ?? new Error("link_failed");
    await admin.from("profiles")
      .update({ telegram_id: tgId, telegram_username: tgUser, tg_chat: true }).eq("id", link.user.id);
    return json({ token_hash: link.properties.hashed_token });
  } catch (e) {
    console.error(e);
    return json({ error: "server_error", detail: String((e as Error)?.message ?? e) }, 500);
  }
});
