-- =====================================================================
--  MY WAY: mashq javoblarini SERVERDA tekshirish (v4)
--  SQL Editor > New query > joylang > Run  (ogohlantirishda "Run query")
-- =====================================================================

-- 1. Mashq sessiyalari (javoblar shu yerda, o'quvchi ko'ra olmaydi)
create table if not exists public.practice_sessions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null,
  key        text not null,
  level      text,
  items      jsonb not null,
  state      jsonb not null default '{}',
  started_at timestamptz not null default now(),
  last_at    timestamptz not null default now(),
  finished   boolean not null default false,
  result     jsonb
);
create index if not exists practice_sessions_user on public.practice_sessions(user_id, kind, started_at);
alter table public.practice_sessions enable row level security;
revoke all on public.practice_sessions from anon, authenticated;

-- 2. Javoblar endi o'quvchilarga yopiq (faqat admin ko'radi)
drop policy if exists "read answers" on public.content_answers;

-- 3. Yordamchi funksiyalar
create or replace function public.mw_norm(t text) returns text
language sql immutable as $$
  select trim(regexp_replace(regexp_replace(lower(coalesce(t,'')), '[.,!?]', '', 'g'), '\s+', ' ', 'g'))
$$;

create or replace function public.mw_shuffle_json(arr jsonb) returns jsonb
language sql volatile as $$
  select coalesce(jsonb_agg(x order by random()), '[]'::jsonb) from jsonb_array_elements(arr) x
$$;

-- Mashqdan ochiq (pub) va yopiq (ans) qismlarni yasash
create or replace function public.mw_item(p_type text, p_data jsonb, p_answer jsonb, p_why text) returns jsonb
language plpgsql volatile as $$
declare w text; pub jsonb; toks jsonb;
begin
  if p_type in ('choose','fill','listen') then
    pub := coalesce(p_data, '{}'::jsonb) || jsonb_build_object('t', p_type);
    return jsonb_build_object('t', p_type, 'pub', pub, 'ans', jsonb_build_object('a', p_answer->>'a'), 'why', p_why);
  elsif p_type = 'spell' then
    w := lower(p_answer->>'word');
    select coalesce(jsonb_agg(c order by random()), '[]'::jsonb) into toks from (
      select unnest(string_to_array(w, null)) c
      union all
      (select c from unnest(string_to_array('abcdefghijklmnoprstuwy', null)) c where position(c in w) = 0 order by random() limit 2)
    ) t;
    pub := jsonb_build_object('t','spell','uz', p_data->>'uz','letters', toks,'n', char_length(w));
    return jsonb_build_object('t','spell','pub', pub,'ans', jsonb_build_object('word', w),'why', null);
  elsif p_type = 'build' then
    select coalesce(jsonb_agg(x order by random()), '[]'::jsonb) into toks from (
      select jsonb_array_elements_text(coalesce(p_answer->'words', '[]'::jsonb)) x
      union all
      select jsonb_array_elements_text(coalesce(p_data->'extra', '[]'::jsonb))
    ) t;
    pub := jsonb_build_object('t','build','uz', p_data->>'uz','tokens', toks);
    return jsonb_build_object('t','build','pub', pub,'ans', jsonb_build_object('words', p_answer->'words'),'why', null);
  elsif p_type = 'match' then
    pub := jsonb_build_object('t','match',
      'left',  (select jsonb_agg(pr->0 order by random()) from jsonb_array_elements(p_answer->'pairs') pr),
      'right', (select jsonb_agg(pr->1 order by random()) from jsonb_array_elements(p_answer->'pairs') pr));
    return jsonb_build_object('t','match','pub', pub,'ans', jsonb_build_object('pairs', p_answer->'pairs'),'why', null);
  end if;
  raise exception 'bad_type';
end $$;

-- Lug'atdan variantlar (3 ta chalg'ituvchi + to'g'ri javob)
create or replace function public.mw_opts(p_level text, p_correct text, p_col text) returns jsonb
language plpgsql volatile as $$
declare r jsonb;
begin
  if p_col = 'uz' then
    select jsonb_agg(x order by random()) into r from (
      (select uz x from (select distinct cw.uz from content_words cw join content_vocab_sets s on s.id = cw.set_id
                          where s.level = p_level and cw.uz <> p_correct) d order by random() limit 3)
      union all select p_correct) t;
  else
    select jsonb_agg(x order by random()) into r from (
      (select en x from (select distinct cw.en from content_words cw join content_vocab_sets s on s.id = cw.set_id
                          where s.level = p_level and cw.en <> p_correct) d order by random() limit 3)
      union all select p_correct) t;
  end if;
  return r;
end $$;

create or replace function public.mw_word_item(p_kind text, p_level text, p_en text, p_uz text) returns jsonb
language plpgsql volatile as $$
begin
  if p_kind = 'choose' then
    return jsonb_build_object('t','choose','pub', jsonb_build_object('t','choose','q', p_en,'say', p_en,'opts', mw_opts(p_level, p_uz, 'uz')),
                              'ans', jsonb_build_object('a', p_uz),'why', null);
  elsif p_kind = 'listen' then
    return jsonb_build_object('t','listen','pub', jsonb_build_object('t','listen','say', p_en,'opts', mw_opts(p_level, p_uz, 'uz')),
                              'ans', jsonb_build_object('a', p_uz),'why', null);
  elsif p_kind = 'rev' then
    return jsonb_build_object('t','choose','pub', jsonb_build_object('t','choose','q', p_uz,'rev', true,'opts', mw_opts(p_level, p_en, 'en')),
                              'ans', jsonb_build_object('a', p_en),'why', null);
  else
    return mw_item('spell', jsonb_build_object('uz', p_uz), jsonb_build_object('word', p_en), null);
  end if;
end $$;

create or replace function public.mw_vocab_items(p_set text, p_level text) returns jsonb
language plpgsql volatile as $$
declare items jsonb := '[]'; r record; i int := 0; pairs jsonb := '[]';
begin
  for r in select en, uz from content_words where set_id = p_set order by random() loop
    i := i + 1;
    if i <= 3 then items := items || jsonb_build_array(mw_word_item('choose', p_level, r.en, r.uz));
    elsif i <= 6 then items := items || jsonb_build_array(mw_word_item('listen', p_level, r.en, r.uz));
    elsif i <= 8 then items := items || jsonb_build_array(mw_word_item('rev', p_level, r.en, r.uz));
    elsif i <= 10 and r.en !~ '\s' and char_length(r.en) <= 11 then items := items || jsonb_build_array(mw_word_item('spell', p_level, r.en, r.uz));
    elsif jsonb_array_length(pairs) < 4 then pairs := pairs || jsonb_build_array(jsonb_build_array(r.en, r.uz));
    end if;
  end loop;
  if jsonb_array_length(pairs) >= 2 then
    items := items || jsonb_build_array(mw_item('match', '{}'::jsonb, jsonb_build_object('pairs', pairs), null));
  end if;
  return mw_shuffle_json(items);
end $$;

create or replace function public.mw_wrev_items(p_uid uuid) returns jsonb
language plpgsql volatile as $$
declare items jsonb := '[]'; r record; i int := 0; k text;
begin
  for r in select * from (
      select distinct on (kw.word) kw.word en, cw.uz, kw.level lv
        from known_words kw
        join content_words cw on cw.en = kw.word
        join content_vocab_sets s on s.id = cw.set_id and s.level = kw.level
       where kw.user_id = p_uid
       order by kw.word) q
    order by random() limit 10
  loop
    i := i + 1;
    k := case i % 4 when 1 then 'choose' when 2 then 'listen'
                    when 3 then (case when r.en !~ '\s' and char_length(r.en) <= 11 then 'spell' else 'rev' end)
                    else 'rev' end;
    items := items || jsonb_build_array(mw_word_item(k, r.lv, r.en, r.uz));
  end loop;
  return items;
end $$;

-- 4. Sessiyani boshlash: savollar JAVOBSIZ qaytadi
create or replace function public.start_session(p_kind text, p_key text, p_words text[] default null)
returns json language plpgsql volatile security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); p profiles%rowtype; L content_lessons%rowtype; v_level text;
        v_items jsonb := '[]'; r record; v_sid uuid; v_last timestamptz; v_it jsonb;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select * into p from profiles where id = v_uid;
  delete from practice_sessions where user_id = v_uid and started_at < now() - interval '2 days';

  if p_kind = 'lesson' then
    select * into L from content_lessons where id = p_key and published;
    if not found then raise exception 'not_found'; end if;
    v_level := L.level;
    if L.track = 'grammar' and not (L.level = any(p.unlocked)) then raise exception 'locked'; end if;
    if L.review then
      for r in select * from (
          select distinct on (e.lesson_id) e.type, e.data, a.answer, a.why
            from content_exercises e
            join content_answers a on a.exercise_id = e.id
            join content_lessons l on l.id = e.lesson_id
           where l.level = L.level and l.track = 'grammar' and not l.review and l.published
           order by e.lesson_id, random()) q
        order by random() limit 15
      loop v_items := v_items || jsonb_build_array(mw_item(r.type, r.data, r.answer, r.why)); end loop;
    else
      for r in select e.type, e.data, a.answer, a.why from content_exercises e
                 join content_answers a on a.exercise_id = e.id
                where e.lesson_id = L.id order by e.ord
      loop v_items := v_items || jsonb_build_array(mw_item(r.type, r.data, r.answer, r.why)); end loop;
    end if;

  elsif p_kind in ('vocab','flash') then
    select level into v_level from content_vocab_sets where id = p_key and published;
    if v_level is null then raise exception 'not_found'; end if;
    if not (v_level = any(p.unlocked)) then raise exception 'locked'; end if;
    if p_kind = 'vocab' then
      v_items := mw_vocab_items(p_key, v_level);
    else
      if coalesce(array_length(p_words, 1), 0) = 0 or array_length(p_words, 1) > 30 then raise exception 'invalid_input'; end if;
      for r in select en, uz from content_words where set_id = p_key and en = any(p_words) order by random() loop
        v_items := v_items || jsonb_build_array(mw_word_item('choose', v_level, r.en, r.uz));
      end loop;
    end if;

  elsif p_kind = 'wrev' then
    v_level := p.level;
    v_items := mw_wrev_items(v_uid);
    if jsonb_array_length(v_items) < 4 then raise exception 'not_enough_words'; end if;

  elsif p_kind = 'exam' then
    v_level := p_key;
    if mw_level_order(v_level) is null then raise exception 'invalid_input'; end if;
    if not (v_level = any(p.unlocked)) then raise exception 'locked'; end if;
    select created_at into v_last from exams where user_id = v_uid and level = v_level and score < 70 order by created_at desc limit 1;
    if v_last is not null and v_last > now() - interval '10 minutes' then raise exception 'cooldown'; end if;
    for r in select * from (
        select e.type, e.data, a.answer, a.why, l.id lid, l.title,
               row_number() over (partition by l.id order by random()) rn
          from content_exercises e
          join content_answers a on a.exercise_id = e.id
          join content_lessons l on l.id = e.lesson_id
         where l.level = v_level and l.track = 'grammar' and not l.review and l.published
           and e.type in ('choose','fill','listen')) q
       where rn <= 2 order by random() limit 24
    loop
      v_it := mw_item(r.type, r.data, r.answer, r.why);
      v_it := jsonb_set(v_it, '{pub}', (v_it->'pub') || jsonb_build_object('topic', r.title, 'lid', r.lid));
      v_items := v_items || jsonb_build_array(v_it);
    end loop;
    for r in select cw.en, cw.uz from content_words cw join content_vocab_sets s on s.id = cw.set_id
              where s.level = v_level and s.published order by random() limit 6
    loop
      v_it := mw_word_item('choose', v_level, r.en, r.uz);
      v_it := jsonb_set(v_it, '{pub}', (v_it->'pub') || jsonb_build_object('topic', 'Lug''at'));
      v_items := v_items || jsonb_build_array(v_it);
    end loop;
    v_items := mw_shuffle_json(v_items);

  elsif p_kind = 'placement' then
    v_level := p_key;
    if mw_level_order(v_level) is null then raise exception 'invalid_input'; end if;
    for r in select e.type, e.data, a.answer, a.why from content_exercises e
               join content_answers a on a.exercise_id = e.id
               join content_lessons l on l.id = e.lesson_id
              where l.level = v_level and l.track = 'grammar' and not l.review and l.published
                and e.type in ('choose','fill')
              order by random() limit 5
    loop v_items := v_items || jsonb_build_array(mw_item(r.type, r.data, r.answer, r.why)); end loop;

  else
    raise exception 'invalid_kind';
  end if;

  if jsonb_array_length(v_items) = 0 then raise exception 'not_found'; end if;
  insert into practice_sessions(user_id, kind, key, level, items)
       values (v_uid, p_kind, p_key, v_level, v_items) returning id into v_sid;
  return json_build_object('id', v_sid,
    'items', (select coalesce(jsonb_agg(x->'pub' order by n), '[]'::jsonb) from jsonb_array_elements(v_items) with ordinality t(x, n)));
end $$;

-- 5. Bitta javobni tekshirish
create or replace function public.check_answer(p_session uuid, p_idx int, p_answer jsonb)
returns json language plpgsql volatile security definer set search_path = public as $$
declare s practice_sessions%rowtype; it jsonb; st jsonb; k text; ok boolean := false; done boolean := true;
        ans_text text; matched jsonb; paid boolean;
begin
  select * into s from practice_sessions where id = p_session and user_id = auth.uid() for update;
  if not found or s.finished then raise exception 'invalid_session'; end if;
  if s.started_at < now() - interval '3 hours' then raise exception 'expired'; end if;
  it := s.items->p_idx;
  if it is null then raise exception 'invalid_input'; end if;
  k := p_idx::text;
  st := coalesce(s.state->k, '{}'::jsonb);
  if s.kind in ('exam','placement','flash') and st ? 'first' then raise exception 'already_answered'; end if;

  if it->>'t' in ('choose','fill','listen') then
    ok := (p_answer->>'v') = (it->'ans'->>'a');
    ans_text := it->'ans'->>'a';
  elsif it->>'t' = 'spell' then
    ok := lower(trim(coalesce(p_answer->>'v',''))) = lower(it->'ans'->>'word');
    ans_text := it->'ans'->>'word';
  elsif it->>'t' = 'build' then
    ans_text := array_to_string(array(select jsonb_array_elements_text(it->'ans'->'words')), ' ');
    ok := mw_norm(p_answer->>'v') = mw_norm(ans_text);
  elsif it->>'t' = 'match' then
    ok := exists (select 1 from jsonb_array_elements(it->'ans'->'pairs') pr
                   where pr->>0 = p_answer->>'l' and pr->>1 = p_answer->>'r');
    matched := coalesce(st->'matched', '[]'::jsonb);
    if ok and not (matched ? (p_answer->>'l')) then matched := matched || to_jsonb(p_answer->>'l'); end if;
    st := st || jsonb_build_object('matched', matched);
    if not ok then st := st || '{"mist": true}'::jsonb; end if;
    done := jsonb_array_length(matched) >= jsonb_array_length(it->'ans'->'pairs');
    ans_text := (select string_agg((pr->>0) || ' = ' || (pr->>1), ', ') from jsonb_array_elements(it->'ans'->'pairs') pr);
  end if;

  if done and not (st ? 'first') then
    paid := (now() - s.last_at) >= interval '800 milliseconds';   -- juda tez bosilsa dollar yo'q
    if it->>'t' = 'match' then
      st := st || jsonb_build_object('first', not coalesce((st->>'mist')::boolean, false), 'paid', not coalesce((st->>'mist')::boolean, false));
    else
      st := st || jsonb_build_object('first', ok, 'paid', ok and paid);
    end if;
  elsif done then
    st := st || jsonb_build_object('retry', ok);
  end if;

  update practice_sessions set state = jsonb_set(state, array[k], st), last_at = now() where id = s.id;
  return json_build_object('ok', ok, 'done', done,
    'answer', case when s.kind in ('exam','placement') then null else ans_text end,
    'why',    case when ok or s.kind in ('exam','placement') then null else it->>'why' end);
end $$;

-- 6. Sessiyani yakunlash: natija va dollarni server hisoblaydi
create or replace function public.finish_session(p_session uuid)
returns json language plpgsql volatile security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); s practice_sessions%rowtype; n int; first_ok int; paid int; pct int; pass boolean := false;
        v_key text; v_att int; v_mult numeric := 1; v_bonus int; v_raw int := 0; v_got int := 0; v_new int := 0; res json; r record;
begin
  select * into s from practice_sessions where id = p_session and user_id = v_uid for update;
  if not found or s.finished then raise exception 'invalid_session'; end if;
  n := jsonb_array_length(s.items);
  select count(*) filter (where coalesce((v->>'first')::boolean, false)),
         count(*) filter (where coalesce((v->>'paid')::boolean, false))
    into first_ok, paid from jsonb_each(s.state) e(k, v);
  pct := round(first_ok * 100.0 / greatest(n, 1));

  if s.kind in ('lesson','vocab','wrev') then
    v_key := case s.kind when 'lesson' then s.key when 'vocab' then 'v:' || s.key else 'wrev' end;
    pass := pct >= 80;
    select attempts into v_att from lesson_progress where user_id = v_uid and key = v_key;
    v_att := coalesce(v_att, 0);
    v_mult := case when v_att = 0 then 1 when v_att = 1 then 0.5 else 0.1 end;
    v_bonus := case s.kind when 'lesson' then 20 when 'vocab' then 15 else 10 end;
    v_raw := round((paid + case when pass then v_bonus else 0 end) * v_mult);
    v_got := mw_credit(v_uid, v_raw, 'practice', v_key, true);
    insert into lesson_progress(user_id, key, best, attempts, passed, last_at)
         values (v_uid, v_key, pct, 1, pass, now())
    on conflict (user_id, key) do update
         set best = greatest(lesson_progress.best, pct), attempts = lesson_progress.attempts + 1,
             passed = lesson_progress.passed or pass, last_at = now();
    perform mw_mark_activity(v_uid);
    perform mw_bump(v_uid, 'runs', 1);
    perform mw_bump(v_uid, 'correct', first_ok);
    if pct >= 70 then perform mw_bump(v_uid, 'did:' || v_key, 1); end if;
    if pass then perform mw_bump(v_uid, 'passed:' || v_key, 1); end if;
    if s.kind = 'wrev' and pct >= 70 then perform mw_bump(v_uid, 'wordReview', 1); end if;

  elsif s.kind = 'flash' then
    for r in select (s.items->(e.k::int)->'pub'->>'q') en
               from jsonb_each(s.state) e(k, v) where coalesce((e.v->>'first')::boolean, false)
    loop
      insert into known_words(user_id, level, word) values (v_uid, s.level, r.en) on conflict do nothing;
      if found then v_new := v_new + 1; end if;
    end loop;
    v_raw := v_new;
    v_got := mw_credit(v_uid, v_new, 'words', s.level, true);
    if v_new > 0 then perform mw_bump(v_uid, 'newWords', v_new); end if;
    perform mw_mark_activity(v_uid);

  elsif s.kind = 'exam' then
    if now() - s.started_at < interval '90 seconds' then raise exception 'too_fast'; end if;
    insert into exams(user_id, level, score) values (v_uid, s.key, pct);
    pass := pct >= 70;
    perform mw_mark_activity(v_uid);

  elsif s.kind = 'placement' then
    pass := first_ok >= 4;
  end if;

  res := json_build_object('pct', pct, 'pass', pass, 'first_ok', first_ok, 'total', n,
                           'got', v_got, 'capped', v_got < v_raw, 'mult', v_mult, 'new', v_new);
  update practice_sessions set finished = true, result = res::jsonb where id = s.id;
  return res;
end $$;

-- 7. Daraja aniqlash natijasi: server tekshirgan bloklar asosida
create or replace function public.apply_placement(p_level text)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); p profiles%rowtype; v_granted boolean := false; i int;
        lv text[] := array['A1','A2','B1','B2','C1','C2'];
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if mw_level_order(p_level) is null then raise exception 'invalid_input'; end if;
  for i in 1 .. mw_level_order(p_level) - 1 loop
    if not exists (select 1 from practice_sessions
                    where user_id = v_uid and kind = 'placement' and key = lv[i] and finished
                      and coalesce((result->>'pass')::boolean, false) and started_at > now() - interval '3 hours') then
      raise exception 'placement_invalid';
    end if;
  end loop;
  select * into p from profiles where id = v_uid for update;
  if p.placement_level is null then
    if mw_level_order(p_level) > mw_level_order(p.level) then
      update profiles set level = p_level, unlocked = lv[1:mw_level_order(p_level)] where id = v_uid;
      v_granted := true;
    end if;
    update profiles set placement_level = p_level where id = v_uid;
  end if;
  return json_build_object('granted', v_granted);
end $$;

-- 8. Eski funksiyalarni cheklash
-- Speaking mashqlari hali telefonda tekshiriladi: faqat sp: kalitlari qabul qilinadi
create or replace function public.submit_practice(p_key text, p_total int, p_correct int, p_paid int, p_duration_ms int, p_bonus int default 20)
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); lp lesson_progress%rowtype; v_att int; v_mult numeric; v_pct int; v_pass boolean;
        v_paid int; v_raw int; v_got int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_key is null or p_key !~ '^sp:sp[0-9]{1,2}$' then raise exception 'use_sessions'; end if;
  if p_total < 1 or p_total > 20 or p_correct < 0 or p_correct > p_total or p_paid < 0 or p_paid > p_correct then raise exception 'invalid_input'; end if;
  select * into lp from lesson_progress where user_id = v_uid and key = p_key;
  v_att := coalesce(lp.attempts, 0);
  if lp.last_at is not null and lp.last_at > now() - interval '20 seconds' then raise exception 'too_fast'; end if;
  v_paid := case when coalesce(p_duration_ms,0) < p_total * 1500 then 0 else p_paid end;
  v_mult := case when v_att = 0 then 1 when v_att = 1 then 0.5 else 0.1 end;
  v_pct  := round(p_correct * 100.0 / p_total);
  v_pass := v_pct >= 80;
  v_raw  := round((v_paid + case when v_pass then least(greatest(p_bonus,0), 15) else 0 end) * v_mult);
  v_got  := mw_credit(v_uid, v_raw, 'practice', p_key, true);
  insert into lesson_progress(user_id, key, best, attempts, passed, last_at) values (v_uid, p_key, v_pct, 1, v_pass, now())
  on conflict (user_id, key) do update
       set best = greatest(lesson_progress.best, v_pct), attempts = lesson_progress.attempts + 1,
           passed = lesson_progress.passed or v_pass, last_at = now();
  perform mw_mark_activity(v_uid);
  perform mw_bump(v_uid, 'runs', 1);
  perform mw_bump(v_uid, 'correct', p_correct);
  perform mw_bump(v_uid, 'speakRuns', 1);
  return json_build_object('got', v_got, 'capped', v_got < v_raw, 'pct', v_pct, 'pass', v_pass, 'mult', v_mult);
end $$;

-- O'yinlarda to'plam va kartochka nomlari tekshiriladi (soxta nomlar bilan dollar yig'ib bo'lmaydi)
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
    if p_kind = 'memory' and not exists (select 1 from content_vocab_sets where id = p_ref) then raise exception 'invalid_input'; end if;
    if p_kind = 'cue' and (p_ref is null or p_ref !~ '^c[0-9]{1,2}$') then raise exception 'invalid_input'; end if;
    v_key := case p_kind when 'memory' then 'mem:' else 'cue:' end || p_ref;
    select attempts into v_att from lesson_progress where user_id = v_uid and key = v_key;
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

-- Eski ishonchsiz funksiyalar o'chiriladi
revoke execute on function public.submit_exam(text,int,int)  from authenticated;
revoke execute on function public.learn_words(text,text[])   from authenticated;

-- Ichki yordamchilar faqat server uchun
revoke execute on function public.mw_item(text,jsonb,jsonb,text)       from public, anon, authenticated;
revoke execute on function public.mw_opts(text,text,text)              from public, anon, authenticated;
revoke execute on function public.mw_word_item(text,text,text,text)    from public, anon, authenticated;
revoke execute on function public.mw_vocab_items(text,text)            from public, anon, authenticated;
revoke execute on function public.mw_wrev_items(uuid)                  from public, anon, authenticated;

-- Yangi RPC'lar
revoke execute on function public.start_session(text,text,text[])  from public, anon;
revoke execute on function public.check_answer(uuid,int,jsonb)     from public, anon;
revoke execute on function public.finish_session(uuid)             from public, anon;
grant  execute on function public.start_session(text,text,text[])  to authenticated;
grant  execute on function public.check_answer(uuid,int,jsonb)     to authenticated;
grant  execute on function public.finish_session(uuid)             to authenticated;

select 'Tayyor: mashqlar endi serverda tekshiriladi' as natija;
