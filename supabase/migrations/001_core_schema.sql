-- =====================================================================
--  MY WAY: Supabase bazasi (v1)
--  Qanday ishlatiladi: Supabase > SQL Editor > New query > shu faylni
--  to'liq nusxalab joylang > Run.
--
--  Asosiy g'oya: dollar, daraja, seriya va natijalarni FAQAT server
--  hisoblaydi. Foydalanuvchi brauzerdan o'z balansini o'zgartira olmaydi.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. Yordamchi funksiyalar
-- ---------------------------------------------------------------------
create or replace function public.mw_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Tashkent')::date $$;

create or replace function public.mw_level_order(p text) returns int
language sql immutable as $$ select array_position(array['A1','A2','B1','B2','C1','C2'], p) $$;

create or replace function public.mw_level_price(p text) returns int
language sql immutable as $$
  select case p when 'A1' then 0 when 'A2' then 1000 when 'B1' then 2000
                when 'B2' then 3500 when 'C1' then 5000 when 'C2' then 7000 end $$;

-- ---------------------------------------------------------------------
-- 2. Jadvallar
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  name            text not null check (char_length(name) between 2 and 40),
  phone           text unique,
  level           text not null default 'A1' check (public.mw_level_order(level) is not null),
  unlocked        text[] not null default array['A1'],
  balance         int  not null default 0 check (balance >= 0),
  total_earned    int  not null default 0,
  placement_level text,
  wallpaper       text not null default 'daraja',
  notif           jsonb not null default '{"on":true,"time":"20:00","streak":true,"plan":true,"reward":true}',
  seen_help       boolean not null default false,
  created_at      timestamptz not null default now()
);

create table if not exists public.lesson_progress (
  user_id  uuid references public.profiles(id) on delete cascade,
  key      text not null check (char_length(key) <= 40),
  best     int  not null default 0,
  attempts int  not null default 0,
  passed   boolean not null default false,
  last_at  timestamptz,
  primary key (user_id, key)
);

create table if not exists public.known_words (
  user_id    uuid references public.profiles(id) on delete cascade,
  level      text not null,
  word       text not null,
  learned_at timestamptz not null default now(),
  primary key (user_id, level, word)
);

create table if not exists public.exams (
  id         bigserial primary key,
  user_id    uuid references public.profiles(id) on delete cascade,
  level      text not null,
  score      int  not null check (score between 0 and 100),
  created_at timestamptz not null default now()
);
create index if not exists exams_user_level on public.exams(user_id, level);

create table if not exists public.ledger (
  id         bigserial primary key,
  user_id    uuid references public.profiles(id) on delete cascade,
  amount     int  not null,
  reason     text not null,
  ref        text,
  capped     boolean not null default false,
  day        date not null default public.mw_today(),
  created_at timestamptz not null default now()
);
create index if not exists ledger_user_day on public.ledger(user_id, day);

create table if not exists public.streaks (
  user_id  uuid primary key references public.profiles(id) on delete cascade,
  count    int  not null default 0,
  best     int  not null default 0,
  last_day date,
  freezes  int  not null default 0 check (freezes between 0 and 2)
);

create table if not exists public.activity_days (
  user_id uuid references public.profiles(id) on delete cascade,
  day     date not null,
  primary key (user_id, day)
);

create table if not exists public.daily_plans (
  user_id        uuid references public.profiles(id) on delete cascade,
  day            date not null,
  plan           jsonb not null default '{}',
  metrics        jsonb not null default '{}',
  bonus_claimed  boolean not null default false,
  sentence_paid  boolean not null default false,
  primary key (user_id, day)
);

create table if not exists public.sentences (
  id         bigserial primary key,
  user_id    uuid references public.profiles(id) on delete cascade,
  day        date not null default public.mw_today(),
  word       text not null,
  text       text not null check (char_length(text) between 8 and 300),
  corrected  text,
  correct    boolean,
  created_at timestamptz not null default now()
);
create index if not exists sentences_user_day on public.sentences(user_id, day);

create table if not exists public.certificates (
  id        bigserial primary key,
  user_id   uuid references public.profiles(id) on delete cascade,
  level     text not null,
  score     int,
  issued_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. Xavfsizlik (Row Level Security): har kim faqat o'z ma'lumotini ko'radi
-- ---------------------------------------------------------------------
alter table public.profiles        enable row level security;
alter table public.lesson_progress enable row level security;
alter table public.known_words     enable row level security;
alter table public.exams           enable row level security;
alter table public.ledger          enable row level security;
alter table public.streaks         enable row level security;
alter table public.activity_days   enable row level security;
alter table public.daily_plans     enable row level security;
alter table public.sentences       enable row level security;
alter table public.certificates    enable row level security;

drop policy if exists "own profile read" on public.profiles;
create policy "own profile read" on public.profiles        for select using (auth.uid() = id);
drop policy if exists "own profile update" on public.profiles;
create policy "own profile update" on public.profiles        for update using (auth.uid() = id) with check (auth.uid() = id);
drop policy if exists "own progress" on public.lesson_progress;
create policy "own progress" on public.lesson_progress for select using (auth.uid() = user_id);
drop policy if exists "own words" on public.known_words;
create policy "own words" on public.known_words     for select using (auth.uid() = user_id);
drop policy if exists "own exams" on public.exams;
create policy "own exams" on public.exams           for select using (auth.uid() = user_id);
drop policy if exists "own ledger" on public.ledger;
create policy "own ledger" on public.ledger          for select using (auth.uid() = user_id);
drop policy if exists "own streak" on public.streaks;
create policy "own streak" on public.streaks         for select using (auth.uid() = user_id);
drop policy if exists "own days" on public.activity_days;
create policy "own days" on public.activity_days   for select using (auth.uid() = user_id);
drop policy if exists "own plans" on public.daily_plans;
create policy "own plans" on public.daily_plans     for select using (auth.uid() = user_id);
drop policy if exists "own sentences" on public.sentences;
create policy "own sentences" on public.sentences       for select using (auth.uid() = user_id);
drop policy if exists "own certificates" on public.certificates;
create policy "own certificates" on public.certificates    for select using (auth.uid() = user_id);

-- Profildan faqat xavfsiz ustunlarni o'zgartirish mumkin (balans, daraja EMAS)
revoke insert, update, delete on public.profiles from anon, authenticated;
grant update (name, wallpaper, notif, seen_help) on public.profiles to authenticated;
-- Boshqa jadvallarga to'g'ridan-to'g'ri yozish taqiqlanadi, faqat funksiyalar orqali
revoke insert, update, delete on public.lesson_progress, public.known_words, public.exams, public.ledger,
  public.streaks, public.activity_days, public.daily_plans, public.sentences, public.certificates from anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Ro'yxatdan o'tganda profil avtomatik yaratiladi
-- ---------------------------------------------------------------------
create or replace function public.mw_handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_name text := left(trim(coalesce(new.raw_user_meta_data->>'name','')), 40);
begin
  if char_length(v_name) < 2 then v_name := 'Foydalanuvchi'; end if;
  insert into public.profiles(id, name, phone)
  values (new.id, v_name, nullif(new.raw_user_meta_data->>'phone',''));
  insert into public.streaks(user_id) values (new.id);
  return new;
end $$;

drop trigger if exists mw_on_auth_user_created on auth.users;
create trigger mw_on_auth_user_created after insert on auth.users
  for each row execute function public.mw_handle_new_user();

-- ---------------------------------------------------------------------
-- 5. Ichki funksiyalar (foydalanuvchi to'g'ridan-to'g'ri chaqira olmaydi)
-- ---------------------------------------------------------------------
-- Dollar qo'shish, kunlik $300 limiti bilan
create or replace function public.mw_credit(p_uid uuid, p_amount int, p_reason text, p_ref text, p_capped boolean)
returns int language plpgsql security definer set search_path = public as $$
declare v_used int; v_grant int;
begin
  if p_amount is null or p_amount <= 0 then return 0; end if;
  perform 1 from profiles where id = p_uid for update;
  if p_capped then
    select coalesce(sum(amount),0) into v_used from ledger where user_id = p_uid and day = mw_today() and capped;
    v_grant := greatest(0, least(p_amount, 300 - v_used));
  else
    v_grant := p_amount;
  end if;
  if v_grant > 0 then
    update profiles set balance = balance + v_grant, total_earned = total_earned + v_grant where id = p_uid;
    insert into ledger(user_id, amount, reason, ref, capped) values (p_uid, v_grant, p_reason, p_ref, p_capped);
  end if;
  return v_grant;
end $$;

create or replace function public.mw_ensure_plan(p_uid uuid) returns void
language sql security definer set search_path = public as $$
  insert into daily_plans(user_id, day) values (p_uid, mw_today()) on conflict do nothing $$;

create or replace function public.mw_bump(p_uid uuid, p_key text, p_n int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform mw_ensure_plan(p_uid);
  update daily_plans
     set metrics = jsonb_set(metrics, array[p_key], to_jsonb(coalesce((metrics->>p_key)::int,0) + p_n))
   where user_id = p_uid and day = mw_today();
end $$;

create or replace function public.mw_max(p_uid uuid, p_key text, p_v int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform mw_ensure_plan(p_uid);
  update daily_plans
     set metrics = jsonb_set(metrics, array[p_key], to_jsonb(greatest(coalesce((metrics->>p_key)::int,0), p_v)))
   where user_id = p_uid and day = mw_today();
end $$;

-- Kunlik seriya (server vaqti bo'yicha, telefon soatini o'zgartirish ta'sir qilmaydi)
create or replace function public.mw_mark_activity(p_uid uuid) returns int
language plpgsql security definer set search_path = public as $$
declare s streaks%rowtype; v_today date := mw_today(); v_gap int; v_bonus int := 0;
begin
  insert into activity_days(user_id, day) values (p_uid, v_today) on conflict do nothing;
  select * into s from streaks where user_id = p_uid for update;
  if not found then insert into streaks(user_id) values (p_uid) returning * into s; end if;
  if s.last_day = v_today then return 0; end if;
  v_gap := case when s.last_day is null then 1 else v_today - s.last_day end;
  if v_gap = 1 then s.count := s.count + 1;
  elsif v_gap > 1 and v_gap - 1 <= s.freezes then s.freezes := s.freezes - (v_gap - 1); s.count := s.count + 1;
  else s.count := 1; end if;
  s.best := greatest(s.best, s.count);
  update streaks set count = s.count, best = s.best, last_day = v_today, freezes = s.freezes where user_id = p_uid;
  v_bonus := case s.count when 3 then 20 when 7 then 50 when 14 then 100 when 30 then 200 when 60 then 300 when 100 then 500 else 0 end;
  if v_bonus > 0 then perform mw_credit(p_uid, v_bonus, 'streak_bonus', s.count::text, false); end if;
  return v_bonus;
end $$;

revoke execute on function public.mw_credit(uuid,int,text,text,boolean) from public, anon, authenticated;
revoke execute on function public.mw_ensure_plan(uuid)                  from public, anon, authenticated;
revoke execute on function public.mw_bump(uuid,text,int)                from public, anon, authenticated;
revoke execute on function public.mw_max(uuid,text,int)                 from public, anon, authenticated;
revoke execute on function public.mw_mark_activity(uuid)                from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Ilova chaqiradigan funksiyalar (RPC)
-- ---------------------------------------------------------------------

-- Ilova ochilganda barcha holatni bitta so'rovda olish
create or replace function public.get_state() returns json
language sql stable security invoker set search_path = public as $$
  select json_build_object(
    'today',       mw_today(),
    'profile',     (select row_to_json(p) from profiles p where p.id = auth.uid()),
    'streak',      (select row_to_json(s) from streaks s where s.user_id = auth.uid()),
    'plan',        (select row_to_json(d) from daily_plans d where d.user_id = auth.uid() and d.day = mw_today()),
    'progress',    (select coalesce(json_object_agg(key, json_build_object('best',best,'attempts',attempts,'passed',passed)), '{}'::json)
                      from lesson_progress where user_id = auth.uid()),
    'known',       (select coalesce(json_agg(level || ':' || word), '[]'::json) from known_words where user_id = auth.uid()),
    'examBest',    (select coalesce(json_object_agg(level, b), '{}'::json)
                      from (select level, max(score) b from exams where user_id = auth.uid() group by level) x),
    'activeDays',  (select coalesce(json_agg(day order by day), '[]'::json) from activity_days
                      where user_id = auth.uid() and day > mw_today() - 60),
    'dailyEarned', (select coalesce(sum(amount),0) from ledger where user_id = auth.uid() and day = mw_today() and capped),
    'certs',       (select coalesce(json_agg(row_to_json(c)), '[]'::json) from certificates c where c.user_id = auth.uid())
  ) $$;

-- Dars va mashq natijasi
create or replace function public.submit_practice(p_key text, p_total int, p_correct int, p_paid int, p_duration_ms int, p_bonus int default 20)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); lp lesson_progress%rowtype; v_att int; v_mult numeric; v_pct int; v_pass boolean;
        v_paid int; v_raw int; v_got int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_key is null or char_length(p_key) > 40 or p_total < 1 or p_total > 60 or p_correct < 0 or p_correct > p_total
     or p_paid < 0 or p_paid > p_correct then raise exception 'invalid_input'; end if;
  select * into lp from lesson_progress where user_id = v_uid and key = p_key;
  v_att := coalesce(lp.attempts, 0);
  if lp.last_at is not null and lp.last_at > now() - interval '20 seconds' then raise exception 'too_fast'; end if;
  -- har savolga kamida 1.5 soniya: juda tez bosilsa dollar berilmaydi
  v_paid := case when coalesce(p_duration_ms,0) < p_total * 1500 then 0 else p_paid end;
  v_mult := case when v_att = 0 then 1 when v_att = 1 then 0.5 else 0.1 end;
  v_pct  := round(p_correct * 100.0 / p_total);
  v_pass := v_pct >= 80;
  v_raw  := round((v_paid + case when v_pass then least(greatest(p_bonus,0), 20) else 0 end) * v_mult);
  v_got  := mw_credit(v_uid, v_raw, 'practice', p_key, true);
  insert into lesson_progress(user_id, key, best, attempts, passed, last_at)
       values (v_uid, p_key, v_pct, 1, v_pass, now())
  on conflict (user_id, key) do update
       set best = greatest(lesson_progress.best, v_pct), attempts = lesson_progress.attempts + 1,
           passed = lesson_progress.passed or v_pass, last_at = now();
  perform mw_mark_activity(v_uid);
  perform mw_bump(v_uid, 'runs', 1);
  perform mw_bump(v_uid, 'correct', p_correct);
  if v_pct >= 70 then perform mw_bump(v_uid, 'did:' || p_key, 1); end if;
  if v_pass then perform mw_bump(v_uid, 'passed:' || p_key, 1); end if;
  if p_key = 'wrev' and v_pct >= 70 then perform mw_bump(v_uid, 'wordReview', 1); end if;
  if p_key like 'sp:%' then perform mw_bump(v_uid, 'speakRuns', 1); end if;
  return json_build_object('got', v_got, 'capped', v_got < v_raw, 'pct', v_pct, 'pass', v_pass, 'mult', v_mult);
end $$;

-- Tekshiruvdan o'tgan so'zlar
create or replace function public.learn_words(p_level text, p_words text[])
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_new int := 0; w text; v_got int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if mw_level_order(p_level) is null or coalesce(array_length(p_words,1),0) > 30 then raise exception 'invalid_input'; end if;
  foreach w in array coalesce(p_words, '{}'::text[]) loop
    if char_length(w) between 1 and 60 then
      insert into known_words(user_id, level, word) values (v_uid, p_level, w) on conflict do nothing;
      if found then v_new := v_new + 1; end if;
    end if;
  end loop;
  v_got := mw_credit(v_uid, v_new, 'words', p_level, true);
  if v_new > 0 then perform mw_bump(v_uid, 'newWords', v_new); end if;
  perform mw_mark_activity(v_uid);
  return json_build_object('new', v_new, 'got', v_got);
end $$;

-- O'yinlar: blitz, memory, cue
create or replace function public.submit_game(p_kind text, p_score int, p_stars int, p_seconds int, p_ref text)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_raw int := 0; v_got int; v_att int; v_mult numeric; v_plays int; v_key text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_kind = 'blitz' then
    if coalesce(p_seconds,0) < 55 or p_score < 0 or p_score > 3000 then raise exception 'invalid_input'; end if;
    perform mw_ensure_plan(v_uid);
    select coalesce((metrics->>'blitzPlays')::int,0) into v_plays from daily_plans where user_id = v_uid and day = mw_today();
    v_raw := least(30, p_score / 20);
    if v_plays >= 3 then v_raw := v_raw / 2; end if;
    perform mw_bump(v_uid, 'blitzPlays', 1);
    perform mw_max(v_uid, 'blitzBest', p_score);
  elsif p_kind in ('memory','cue') then
    if p_ref is null or char_length(p_ref) > 30 then raise exception 'invalid_input'; end if;
    v_key := case p_kind when 'memory' then 'mem:' else 'cue:' end || p_ref;
    select coalesce(attempts,0) into v_att from lesson_progress where user_id = v_uid and key = v_key;
    v_att  := coalesce(v_att, 0);
    v_mult := case when v_att = 0 then 1 when v_att = 1 then 0.5 else 0.1 end;
    if p_kind = 'memory' then
      if p_stars not between 1 and 3 or coalesce(p_seconds,0) < 8 then raise exception 'invalid_input'; end if;
      v_raw := round((array[4,7,10])[p_stars] * v_mult);
      if p_stars = 3 then perform mw_bump(v_uid, 'mem3', 1); end if;
    else
      if coalesce(p_seconds,0) >= 60 then v_raw := round(5 * v_mult); perform mw_bump(v_uid, 'cue', 1); end if;
    end if;
    insert into lesson_progress(user_id, key, best, attempts, passed, last_at)
         values (v_uid, v_key, coalesce(p_stars, 0), 1, true, now())
    on conflict (user_id, key) do update
         set best = greatest(lesson_progress.best, coalesce(p_stars,0)), attempts = lesson_progress.attempts + 1, last_at = now();
  else
    raise exception 'invalid_kind';
  end if;
  v_got := mw_credit(v_uid, v_raw, p_kind, p_ref, true);
  perform mw_mark_activity(v_uid);
  return json_build_object('got', v_got, 'capped', v_got < v_raw);
end $$;

-- Daraja imtihoni (yiqilgandan keyin 10 daqiqa kutish)
create or replace function public.submit_exam(p_level text, p_score int, p_seconds int)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_last timestamptz; v_best int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if mw_level_order(p_level) is null or p_score not between 0 and 100 or coalesce(p_seconds,0) < 90 then raise exception 'invalid_input'; end if;
  select created_at into v_last from exams where user_id = v_uid and level = p_level and score < 70 order by created_at desc limit 1;
  if v_last is not null and v_last > now() - interval '10 minutes' then raise exception 'cooldown'; end if;
  insert into exams(user_id, level, score) values (v_uid, p_level, p_score);
  perform mw_mark_activity(v_uid);
  select max(score) into v_best from exams where user_id = v_uid and level = p_level;
  return json_build_object('best', v_best, 'pass', p_score >= 70);
end $$;

-- Keyingi darajani sotib olish
create or replace function public.buy_level()
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); p profiles%rowtype; v_next text; v_price int; v_best int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select * into p from profiles where id = v_uid for update;
  v_next := (array['A1','A2','B1','B2','C1','C2'])[mw_level_order(p.level) + 1];
  if v_next is null then raise exception 'max_level'; end if;
  v_price := mw_level_price(v_next);
  select coalesce(max(score),0) into v_best from exams where user_id = v_uid and level = p.level;
  if v_best < 70 then raise exception 'exam_required'; end if;
  if p.balance < v_price then raise exception 'not_enough_money'; end if;
  update profiles
     set balance = balance - v_price, level = v_next,
         unlocked = case when v_next = any(unlocked) then unlocked else array_append(unlocked, v_next) end
   where id = v_uid;
  insert into ledger(user_id, amount, reason, ref) values (v_uid, -v_price, 'buy_level', v_next);
  insert into certificates(user_id, level, score) values (v_uid, p.level, v_best);
  return json_build_object('level', v_next, 'balance', p.balance - v_price);
end $$;

-- Muzlatish sotib olish ($50, ko'pi bilan 2 ta)
create or replace function public.buy_freeze()
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_bal int; v_fr int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select balance into v_bal from profiles where id = v_uid for update;
  select freezes into v_fr from streaks where user_id = v_uid for update;
  if v_fr >= 2 then raise exception 'freezes_full'; end if;
  if v_bal < 50 then raise exception 'not_enough_money'; end if;
  update profiles set balance = balance - 50 where id = v_uid;
  update streaks set freezes = freezes + 1 where user_id = v_uid;
  insert into ledger(user_id, amount, reason) values (v_uid, -50, 'buy_freeze');
  return json_build_object('freezes', v_fr + 1, 'balance', v_bal - 50);
end $$;

-- Daraja aniqlash testi natijasi (bepul ochish faqat bir marta)
create or replace function public.apply_placement(p_level text)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); p profiles%rowtype; v_granted boolean := false;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if mw_level_order(p_level) is null then raise exception 'invalid_input'; end if;
  select * into p from profiles where id = v_uid for update;
  if p.placement_level is null then
    if mw_level_order(p_level) > mw_level_order(p.level) then
      update profiles set level = p_level,
             unlocked = (array['A1','A2','B1','B2','C1','C2'])[1:mw_level_order(p_level)]
       where id = v_uid;
      v_granted := true;
    end if;
    update profiles set placement_level = p_level where id = v_uid;
  end if;
  return json_build_object('granted', v_granted);
end $$;

-- Kunlik reja: kunning birinchi chaqiruvida saqlanadi, keyin o'zgarmaydi
create or replace function public.set_daily_plan(p_new text, p_rev text, p_game text)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); d daily_plans%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_game not in ('blitz','mem3','cue','speak') then raise exception 'invalid_input'; end if;
  perform mw_ensure_plan(v_uid);
  update daily_plans set plan = jsonb_build_object('new', p_new, 'rev', p_rev, 'game', p_game)
   where user_id = v_uid and day = mw_today() and plan = '{}'::jsonb;
  select * into d from daily_plans where user_id = v_uid and day = mw_today();
  return row_to_json(d);
end $$;

-- 100% bajarilgan reja uchun +$100 (server o'zi tekshiradi)
create or replace function public.claim_plan_bonus()
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); d daily_plans%rowtype; m jsonb; ok boolean := true; v_best int; v_new text; v_rev text; v_game text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select * into d from daily_plans where user_id = v_uid and day = mw_today() for update;
  if not found or d.bonus_claimed or d.plan = '{}'::jsonb then raise exception 'not_available'; end if;
  m := d.metrics; v_new := d.plan->>'new'; v_rev := d.plan->>'rev'; v_game := d.plan->>'game';
  if v_new is not null then
    ok := ok and coalesce((m->>('passed:' || v_new))::int, 0) >= 1;
  else
    select coalesce(max(e.score),0) into v_best from exams e join profiles p on p.id = e.user_id
     where e.user_id = v_uid and e.level = p.level;
    ok := ok and v_best >= 70;
  end if;
  if v_rev is not null then
    ok := ok and coalesce((m->>('did:' || v_rev))::int, 0) >= 1;
  elsif v_new is not null then
    ok := ok and coalesce((m->>('did:' || v_new))::int, 0) >= 2;
  end if;
  ok := ok and coalesce((m->>'newWords')::int,0) >= 10
           and coalesce((m->>'wordReview')::int,0) >= 1
           and coalesce((m->>'sentences')::int,0) >= 10;
  ok := ok and case v_game
                 when 'blitz' then coalesce((m->>'blitzBest')::int,0) >= 100
                 when 'mem3'  then coalesce((m->>'mem3')::int,0) >= 1
                 when 'cue'   then coalesce((m->>'cue')::int,0) >= 1
                 when 'speak' then coalesce((m->>'speakRuns')::int,0) >= 1
                 else false end;
  if not ok then raise exception 'plan_incomplete'; end if;
  update daily_plans set bonus_claimed = true where user_id = v_uid and day = mw_today();
  perform mw_credit(v_uid, 100, 'plan_bonus', mw_today()::text, false);
  return json_build_object('got', 100);
end $$;

-- Gap tuzish (kuniga 10 ta, 10-gapdan keyin +$20)
create or replace function public.submit_sentence(p_word text, p_text text, p_corrected text, p_correct boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_n int; v_stem text; v_got int := 0; v_upd int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_text is null or char_length(p_text) not between 8 and 300 or p_word is null or char_length(p_word) > 60 then raise exception 'invalid_input'; end if;
  select count(*) into v_n from sentences where user_id = v_uid and day = mw_today();
  if v_n >= 10 then raise exception 'limit_reached'; end if;
  if exists (select 1 from sentences where user_id = v_uid and day = mw_today() and lower(text) = lower(p_text)) then raise exception 'duplicate'; end if;
  v_stem := lower(split_part(trim(p_word), ' ', 1));
  if char_length(v_stem) > 4 then v_stem := regexp_replace(v_stem, '(e|y)$', ''); end if;
  if position(v_stem in lower(p_text)) = 0 then raise exception 'word_missing'; end if;
  insert into sentences(user_id, word, text, corrected, correct) values (v_uid, p_word, p_text, left(p_corrected,300), p_correct);
  perform mw_bump(v_uid, 'sentences', 1);
  perform mw_mark_activity(v_uid);
  if v_n + 1 = 10 then
    update daily_plans set sentence_paid = true where user_id = v_uid and day = mw_today() and not sentence_paid;
    get diagnostics v_upd = row_count;
    if v_upd > 0 then v_got := mw_credit(v_uid, 20, 'sentences', mw_today()::text, true); end if;
  end if;
  return json_build_object('count', v_n + 1, 'got', v_got);
end $$;

-- RPC huquqlari: faqat tizimga kirgan foydalanuvchi
revoke execute on function public.get_state()                                   from public, anon;
revoke execute on function public.submit_practice(text,int,int,int,int,int)     from public, anon;
revoke execute on function public.learn_words(text,text[])                      from public, anon;
revoke execute on function public.submit_game(text,int,int,int,text)            from public, anon;
revoke execute on function public.submit_exam(text,int,int)                     from public, anon;
revoke execute on function public.buy_level()                                   from public, anon;
revoke execute on function public.buy_freeze()                                  from public, anon;
revoke execute on function public.apply_placement(text)                         from public, anon;
revoke execute on function public.set_daily_plan(text,text,text)                from public, anon;
revoke execute on function public.claim_plan_bonus()                            from public, anon;
revoke execute on function public.submit_sentence(text,text,text,boolean)       from public, anon;

grant execute on function public.get_state()                                    to authenticated;
grant execute on function public.submit_practice(text,int,int,int,int,int)      to authenticated;
grant execute on function public.learn_words(text,text[])                       to authenticated;
grant execute on function public.submit_game(text,int,int,int,text)             to authenticated;
grant execute on function public.submit_exam(text,int,int)                      to authenticated;
grant execute on function public.buy_level()                                    to authenticated;
grant execute on function public.buy_freeze()                                   to authenticated;
grant execute on function public.apply_placement(text)                          to authenticated;
grant execute on function public.set_daily_plan(text,text,text)                 to authenticated;
grant execute on function public.claim_plan_bonus()                             to authenticated;
grant execute on function public.submit_sentence(text,text,text,boolean)        to authenticated;

-- Tayyor! Keyingi qadam: Authentication > Providers > Email > "Confirm email" ni o'chiring.
