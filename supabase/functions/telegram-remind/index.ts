// =====================================================================
//  MY WAY: telegram-remind  (Supabase Edge Function)
//  Har soatda Cron orqali chaqiriladi va eslatmalarni yuboradi.
//  Kerakli secretlar: TELEGRAM_BOT_TOKEN, CRON_SECRET, SITE_URL
//  Sozlama: "Verify JWT" O'CHIRILGAN bo'lsin (himoya: x-cron-secret).
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
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
const SITE_URL = Deno.env.get("SITE_URL") ?? "https://jovial-pony-1450fd.netlify.app";

type Target = { id: string; telegram_id: number; name: string; streak: number; practiced_today: boolean; plan_done: boolean };

function textFor(t: Target): string | null {
  if (!t.practiced_today && t.streak > 0)
    return `🔥 <b>${t.name}</b>, ${t.streak} kunlik seriyangiz xavf ostida!\n\nKun tugashidan oldin bitta mashq qiling, 5 daqiqa yetarli.`;
  if (!t.practiced_today)
    return `📚 <b>${t.name}</b>, bugun hali mashq qilmadingiz.\n\nBugun boshlasangiz, yangi seriya boshlanadi 🔥`;
  if (!t.plan_done)
    return `📋 <b>${t.name}</b>, bugungi rejani yakunlang!\n\n6 ta vazifaning hammasini bajarsangiz, <b>+$100</b> olasiz.`;
  return null;
}

Deno.serve(async (req) => {
  if (!CRON_SECRET || req.headers.get("x-cron-secret") !== CRON_SECRET) return new Response("forbidden", { status: 403 });
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, adminKey(), {
    auth: { persistSession: false },
  });
  const { data, error } = await admin.rpc("mw_reminder_targets");
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500 });

  const sent: string[] = [], handled: string[] = [], blocked: string[] = [];
  for (const t of (data ?? []) as Target[]) {
    handled.push(t.id);
    const text = textFor(t);
    if (!text) continue;
    const r = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: t.telegram_id, text, parse_mode: "HTML",
        reply_markup: { inline_keyboard: [[{ text: "📚 Mashqni boshlash", url: SITE_URL }]] },
      }),
    });
    if (r.ok) sent.push(t.id);
    else if (r.status === 403) blocked.push(t.id); // foydalanuvchi botni bloklagan
    await new Promise((res) => setTimeout(res, 40)); // Telegram limitlari uchun
  }
  if (handled.length) await admin.rpc("mw_mark_notified", { p_ids: handled });
  if (blocked.length) await admin.from("profiles").update({ tg_chat: false }).in("id", blocked);
  return new Response(JSON.stringify({ checked: handled.length, sent: sent.length, blocked: blocked.length }), {
    headers: { "Content-Type": "application/json" },
  });
});
