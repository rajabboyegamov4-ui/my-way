-- MY WAY: AI ustoz uchun kunlik limit hisobi (faqat server yozadi)
create table if not exists public.ai_tutor_usage (
  user_id uuid references auth.users(id) on delete cascade,
  day     date not null,
  count   int  not null default 0,
  primary key (user_id, day)
);
alter table public.ai_tutor_usage enable row level security;
-- Tayyor.
