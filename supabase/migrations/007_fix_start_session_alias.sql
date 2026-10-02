-- Fix: in start_session the table alias "l" clashed with the PL/pgSQL variable "L"
-- (identifiers are case-insensitive), so placement/exam/review queries failed with
-- 'column reference "l.id" is ambiguous'. The alias is renamed to "cl".

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
    select created_at into v_last from exams where user_id = v_uid and level = v_level and score < 70 order by created_at desc limit 1;
    if v_last is not null and v_last > now() - interval '10 minutes' then raise exception 'cooldown'; end if;
    for r in select * from (
        select e.type, e.data, a.answer, a.why, cl.id lid, cl.title,
               row_number() over (partition by cl.id order by random()) rn
          from content_exercises e
          join content_answers a on a.exercise_id = e.id
          join content_lessons cl on cl.id = e.lesson_id
         where cl.level = v_level and cl.track = 'grammar' and not cl.review and cl.published
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
               join content_lessons cl on cl.id = e.lesson_id
              where cl.level = v_level and cl.track = 'grammar' and not cl.review and cl.published
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
