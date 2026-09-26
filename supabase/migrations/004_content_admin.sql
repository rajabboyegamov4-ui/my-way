-- =====================================================================
--  MY WAY: kontent bazasi va admin huquqlari (v3)
--  SQL Editor > New query > joylang > Run
-- =====================================================================

-- Adminlar ro'yxati
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.admins enable row level security;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid())
$$;
grant execute on function public.is_admin() to authenticated;

drop policy if exists "admins read self" on public.admins;
create policy "admins read self" on public.admins for select using (user_id = auth.uid() or public.is_admin());

-- Darslar (grammatika va IELTS)
create table if not exists public.content_lessons (
  id         text primary key,
  track      text not null default 'grammar' check (track in ('grammar','ielts')),
  level      text check (level is null or public.mw_level_order(level) is not null),
  ord        int  not null default 0,
  title      text not null,
  sub        text not null default '',
  theory     jsonb not null default '[]',
  summary    jsonb not null default '[]',
  review     boolean not null default false,
  published  boolean not null default true,
  updated_at timestamptz not null default now()
);

-- Mashqlar (javobsiz ochiq qism)
create table if not exists public.content_exercises (
  id         bigserial primary key,
  lesson_id  text not null references public.content_lessons(id) on delete cascade,
  ord        int  not null default 0,
  type       text not null check (type in ('choose','fill','listen','spell','build','match')),
  data       jsonb not null default '{}'
);
create index if not exists content_exercises_lesson on public.content_exercises(lesson_id, ord);

-- Mashq javoblari (alohida jadval: keyingi bosqichda faqat server ko'radi)
create table if not exists public.content_answers (
  exercise_id bigint primary key references public.content_exercises(id) on delete cascade,
  answer      jsonb not null,
  why         text
);

-- Lug'at
create table if not exists public.content_vocab_sets (
  id        text primary key,
  level     text not null check (public.mw_level_order(level) is not null),
  ord       int  not null default 0,
  title     text not null,
  icon      text not null default '📚',
  published boolean not null default true
);
create table if not exists public.content_words (
  id     bigserial primary key,
  set_id text not null references public.content_vocab_sets(id) on delete cascade,
  ord    int  not null default 0,
  en     text not null,
  uz     text not null
);
create index if not exists content_words_set on public.content_words(set_id, ord);

-- Xavfsizlik: hamma o'qiydi, faqat admin yozadi
alter table public.content_lessons    enable row level security;
alter table public.content_exercises  enable row level security;
alter table public.content_answers    enable row level security;
alter table public.content_vocab_sets enable row level security;
alter table public.content_words      enable row level security;

drop policy if exists "read lessons"   on public.content_lessons;
drop policy if exists "admin lessons"  on public.content_lessons;
drop policy if exists "read ex"        on public.content_exercises;
drop policy if exists "admin ex"       on public.content_exercises;
drop policy if exists "read answers"   on public.content_answers;
drop policy if exists "admin answers"  on public.content_answers;
drop policy if exists "read sets"      on public.content_vocab_sets;
drop policy if exists "admin sets"     on public.content_vocab_sets;
drop policy if exists "read words"     on public.content_words;
drop policy if exists "admin words"    on public.content_words;

create policy "read lessons"  on public.content_lessons    for select to authenticated using (published or public.is_admin());
create policy "admin lessons" on public.content_lessons    for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "read ex"       on public.content_exercises  for select to authenticated using (true);
create policy "admin ex"      on public.content_exercises  for all    to authenticated using (public.is_admin()) with check (public.is_admin());
-- DIQQAT: javoblar hozircha o'quvchilarga ham ochiq (mashq telefonda tekshiriladi).
-- Keyingi bosqichda (serverda tekshirish) bu policy o'chiriladi.
create policy "read answers"  on public.content_answers    for select to authenticated using (true);
create policy "admin answers" on public.content_answers    for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "read sets"     on public.content_vocab_sets for select to authenticated using (published or public.is_admin());
create policy "admin sets"    on public.content_vocab_sets for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "read words"    on public.content_words      for select to authenticated using (true);
create policy "admin words"   on public.content_words      for all    to authenticated using (public.is_admin()) with check (public.is_admin());

grant select, insert, update, delete on public.content_lessons, public.content_exercises, public.content_answers,
  public.content_vocab_sets, public.content_words to authenticated;
grant usage, select on sequence public.content_exercises_id_seq, public.content_words_id_seq to authenticated;

-- Admin uchun statistika
create or replace function public.admin_stats() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'not_admin'; end if;
  return json_build_object(
    'users',        (select count(*) from profiles),
    'new_today',    (select count(*) from profiles where (created_at at time zone 'Asia/Tashkent')::date = mw_today()),
    'active_today', (select count(*) from activity_days where day = mw_today()),
    'active_week',  (select count(distinct user_id) from activity_days where day > mw_today() - 7),
    'telegram',     (select count(*) from profiles where telegram_id is not null),
    'earned_today', (select coalesce(sum(amount),0) from ledger where day = mw_today() and amount > 0),
    'levels',       (select coalesce(json_object_agg(level, n), '{}'::json) from (select level, count(*) n from profiles group by level) x),
    'top',          (select coalesce(json_agg(t), '[]'::json) from (
                       select p.name, p.level, p.balance, coalesce(s.count,0) streak
                         from profiles p left join streaks s on s.user_id = p.id
                        order by p.total_earned desc limit 10) t)
  );
end $$;
revoke execute on function public.admin_stats() from public, anon;
grant  execute on function public.admin_stats() to authenticated;

-- Tayyor. Endi 4-content-seed.sql ni ishga tushiring.

-- AI tekshiruvi uchun kunlik limit hisobi (faqat server yozadi)
create table if not exists public.ai_usage (
  user_id uuid references auth.users(id) on delete cascade,
  day     date not null,
  count   int  not null default 0,
  primary key (user_id, day)
);
alter table public.ai_usage enable row level security;
