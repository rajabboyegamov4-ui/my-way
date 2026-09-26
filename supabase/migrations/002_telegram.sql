-- =====================================================================
--  MY WAY: Telegram qo'shimchasi (v2)
--  SQL Editor > New query > shu faylni joylang > Run
-- =====================================================================

alter table public.profiles add column if not exists telegram_id       bigint unique;
alter table public.profiles add column if not exists telegram_username text;
alter table public.profiles add column if not exists tg_chat           boolean not null default false; -- bot xabar yubora oladimi
alter table public.profiles add column if not exists last_tg_notify    date;

-- Eslatma yuborish kerak bo'lgan foydalanuvchilar (har soatda chaqiriladi).
-- Har foydalanuvchiga o'zi tanlagan soatda, kuniga ko'pi bilan bir marta.
create or replace function public.mw_reminder_targets()
returns table(id uuid, telegram_id bigint, name text, streak int, practiced_today boolean, plan_done boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.telegram_id, p.name,
         coalesce(s.count, 0),
         coalesce(s.last_day = mw_today(), false),
         coalesce(d.bonus_claimed, false)
    from profiles p
    left join streaks s     on s.user_id = p.id
    left join daily_plans d on d.user_id = p.id and d.day = mw_today()
   where p.telegram_id is not null
     and p.tg_chat
     and coalesce((p.notif->>'on')::boolean, true)
     and split_part(coalesce(p.notif->>'time', '20:00'), ':', 1)::int
         = extract(hour from now() at time zone 'Asia/Tashkent')::int
     and (p.last_tg_notify is null or p.last_tg_notify < mw_today())
$$;

create or replace function public.mw_mark_notified(p_ids uuid[])
returns void language sql security definer set search_path = public as $$
  update profiles set last_tg_notify = mw_today() where id = any(p_ids)
$$;

revoke execute on function public.mw_reminder_targets()      from public, anon, authenticated;
revoke execute on function public.mw_mark_notified(uuid[])   from public, anon, authenticated;
grant  execute on function public.mw_reminder_targets()      to service_role;
grant  execute on function public.mw_mark_notified(uuid[])   to service_role;

-- Tayyor.
