-- ---------- Баллы за прослушивание суры (и за повторение за чтецом) ----------
-- Прослушал суру целиком: +1 балл; слушал с паузами и повторял за чтецом: +2 балла. Не больше 50 баллов в день за прослушивание.
-- Проверка, что запись правда звучала: между засчитанными прослушиваниями должно пройти не меньше 90% длины суры (с паузами — 150%).
create or replace function listen_score(p_slug text, p_stoken text, p_sura text, p_rep boolean default false) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; a jsonb; sid text; sec int; last timestamptz; n int; pts int := 0; today int; idx int; st jsonb; d jsonb; entry jsonb; need int;
begin
  g := _g(p_slug); a := _actor(g, null, p_stoken); sid := a->>'s';
  if sid is null then raise exception 'sauth'; end if;
  select secs into sec from sura_secs where sura = p_sura;
  if sec is null then raise exception 'not_found'; end if;
  perform pg_advisory_xact_lock(hashtext(g.id::text || sid));
  select max(at) into last from listens where group_id = g.id and student_id = sid;
  need := greatest(3, floor(sec * (case when coalesce(p_rep, false) then 1.5 else 0.9 end))::int);
  if last is not null and now() - last < make_interval(secs => need) then
    return json_build_object('ok', false, 'why', 'too_fast');
  end if;
  if (select count(*) from listens where group_id = g.id and student_id = sid and at > now() - interval '1 day') >= 300 then
    return json_build_object('ok', false, 'why', 'limit');
  end if;
  insert into listens(group_id, student_id, sura) values (g.id, sid, p_sura);
  select count(*) into n from listens where group_id = g.id and student_id = sid and sura = p_sura;
  -- баллы за прослушивание, с дневным пределом
  select coalesce(sum((e->>'v')::int), 0) into today
    from jsonb_array_elements(coalesce(g.data->'log', '[]'::jsonb)) e
   where e->>'s' = sid and e->>'k' = 'listen' and (e->>'d')::timestamptz > date_trunc('day', now() at time zone 'Europe/Samara') at time zone 'Europe/Samara';
  pts := least(case when coalesce(p_rep, false) then 2 else 1 end, greatest(0, 50 - today));
  if pts > 0 then
    select * into g from groups where id = g.id for update;
    select (e.ord - 1)::int into idx from jsonb_array_elements(g.data->'students') with ordinality as e(v, ord) where e.v->>'id' = sid limit 1;
    if idx is not null then
      st := g.data->'students'->idx; d := g.data;
      if d->'log' is null or jsonb_typeof(d->'log') <> 'array' then d := jsonb_set(d, '{log}', '[]'::jsonb); end if;
      st := st || jsonb_build_object('q', coalesce((st->>'q')::numeric, 0)::int + pts, 'xp', coalesce((st->>'xp')::numeric, 0)::int + pts);
      entry := jsonb_build_object('id', encode(extensions.gen_random_bytes(6), 'hex'), 's', sid, 't', 'q', 'v', pts, 'k', 'listen',
                                  'g', encode(extensions.gen_random_bytes(6), 'hex'),
                                  'note', (case when coalesce(p_rep, false) then '🎧 Повторял за чтецом: ' else '🎧 Прослушал суру ' end) || p_sura,
                                  'd', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
      d := jsonb_set(jsonb_set(d, '{log}', jsonb_build_array(entry) || (d->'log')), array['students', idx::text], st);
      update groups set data = d, version = version + 1, updated_at = now() where id = g.id;
    else pts := 0;
    end if;
  end if;
  return json_build_object('ok', true, 'total', n, 'points', pts);
end $$;
revoke all on function listen_score(text, text, text, boolean) from public;
grant execute on function listen_score(text, text, text, boolean) to anon, authenticated;
notify pgrst, 'reload schema';
