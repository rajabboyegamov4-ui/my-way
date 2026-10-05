-- "Harflardan so'z yig'ing" mashqi: chalg'ituvchi harflar so'zdagi harfga o'xshash bo'lmasin.
-- Masalan "arrive" uchun "j" berilgan edi, u ekranda "i" ga juda o'xshaydi.
-- Endi i/j/l va u/v juftliklaridan biri so'zda bo'lsa, ikkinchisi chalg'ituvchi sifatida berilmaydi.
create or replace function public.mw_item(p_type text, p_data jsonb, p_answer jsonb, p_why text)
returns jsonb language plpgsql as $function$
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
      (select c from unnest(string_to_array('abcdefghklmnoprstwy', null)) c
        where position(c in w) = 0
          and not (c in ('i','l') and w ~ '[ijl]')
          and not (c in ('u','v') and w ~ '[uv]')
        order by random() limit 2)
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
end $function$;
