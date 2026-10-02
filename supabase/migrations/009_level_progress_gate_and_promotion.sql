-- Daraja yakuni:
-- * Imtihon (30 savol, 80%) faqat joriy darajadagi topshiriqlarning (grammatika darslari + lug'at to'plamlari)
--   kamida 90% i o'tilgandan keyin ochiladi.
-- * Imtihondan 100% bilan o'tilsa keyingi daraja bepul va avtomatik ochiladi, sertifikat yoziladi.
--   80-99% bilan o'tilsa keyingi daraja avvalgidek dollar bilan sotib olinadi.

create or replace function public.mw_level_progress(p_uid uuid, p_level text)
returns int language sql stable security definer set search_path = public as $$
  with t as (
    select id as key from content_lessons where level = p_level and track = 'grammar' and published
    union all
    select 'v:' || id from content_vocab_sets where level = p_level and published)
  select case when count(*) = 0 then 0
              else floor(count(lp.key) filter (where lp.passed) * 100.0 / count(*))::int end
    from t left join lesson_progress lp on lp.user_id = p_uid and lp.key = t.key
$$;
revoke execute on function public.mw_level_progress(uuid, text) from public, anon, authenticated;

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
            join content_lessons cl on cl.id = e.lesson_id
           where cl.level = L.level and cl.track = 'grammar' and not cl.review and cl.published
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
    select created_at into v_last from exams where user_id = v_uid and level = v_level and score < 80 order by created_at desc limit 1;
    if v_last is not null and v_last > now() - interval '10 minutes' then raise exception 'cooldown'; end if;
    if v_level = p.level and mw_level_progress(v_uid, v_level) < 90 then raise exception 'progress_required'; end if;
    v_items := mw_level_test_items(v_level, array['choose','fill','listen']);

  elsif p_kind = 'placement' then
    v_level := p_key;
    if mw_level_order(v_level) is null then raise exception 'invalid_input'; end if;
    v_items := mw_level_test_items(v_level, array['choose','fill']);

  else
    raise exception 'invalid_kind';
  end if;

  if jsonb_array_length(v_items) = 0 then raise exception 'not_found'; end if;
  insert into practice_sessions(user_id, kind, key, level, items)
       values (v_uid, p_kind, p_key, v_level, v_items) returning id into v_sid;
  return json_build_object('id', v_sid,
    'items', (select coalesce(jsonb_agg(x->'pub' order by n), '[]'::jsonb) from jsonb_array_elements(v_items) with ordinality t(x, n)));
end $$;

create or replace function public.finish_session(p_session uuid)
returns json language plpgsql volatile security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); s practice_sessions%rowtype; n int; first_ok int; paid int; pct int; pass boolean := false;
        v_key text; v_att int; v_mult numeric := 1; v_bonus int; v_raw int := 0; v_got int := 0; v_new int := 0; res json; r record; v_last timestamptz; v_lm numeric;
        p profiles%rowtype; v_next text; v_promoted text;
begin
  select * into s from practice_sessions where id = p_session and user_id = v_uid for update;
  if not found or s.finished then raise exception 'invalid_session'; end if;
  v_lm := coalesce(mw_level_mult(s.level), mw_level_mult((select level from profiles where id = v_uid)), 1);
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
    select last_at into v_last from lesson_progress where user_id = v_uid and key = v_key;
    v_mult := case when v_att = 0 then 1 when v_last < now() - interval '7 days' then 0.5 when v_att = 1 then 0.5 else 0.1 end;
    v_bonus := case s.kind when 'lesson' then 20 when 'vocab' then 15 else 10 end;
    v_raw := round((paid + case when pass then v_bonus else 0 end) * v_mult * v_lm);
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
    v_raw := round(v_new * v_lm);
    v_got := mw_credit(v_uid, v_raw, 'words', s.level, true);
    if v_new > 0 then perform mw_bump(v_uid, 'newWords', v_new); end if;
    perform mw_mark_activity(v_uid);

  elsif s.kind = 'exam' then
    if now() - s.started_at < interval '90 seconds' then raise exception 'too_fast'; end if;
    pass := pct >= 80;
    if pass and not exists (select 1 from exams where user_id = v_uid and level = s.key and score >= 80) then
      v_bonus := round(100 * v_lm); v_raw := v_bonus;
      v_got := mw_credit(v_uid, v_bonus, 'exam_bonus', s.key, false);
    end if;
    insert into exams(user_id, level, score) values (v_uid, s.key, pct);
    perform mw_mark_activity(v_uid);
    -- 100% xatosiz bo'lsa va bu o'quvchining joriy darajasi bo'lsa: keyingi daraja bepul ochiladi.
    -- 80-99% bo'lsa keyingi daraja buy_level orqali dollar bilan sotib olinadi.
    if pct >= 100 then
      select * into p from profiles where id = v_uid for update;
      v_next := (array['A1','A2','B1','B2','C1','C2'])[mw_level_order(s.key) + 1];
      if p.level = s.key and v_next is not null then
        update profiles
           set level = v_next,
               unlocked = case when v_next = any(unlocked) then unlocked else array_append(unlocked, v_next) end
         where id = v_uid;
        insert into certificates(user_id, level, score) values (v_uid, s.key, pct);
        v_promoted := v_next;
      end if;
    end if;

  elsif s.kind = 'placement' then
    pass := pct >= 80;
  end if;

  res := json_build_object('pct', pct, 'pass', pass, 'first_ok', first_ok, 'total', n,
                           'got', v_got, 'capped', v_got < v_raw, 'mult', v_mult, 'new', v_new,
                           'promoted', v_promoted);
  update practice_sessions set finished = true, result = res::jsonb where id = s.id;
  return res;
end $$;
