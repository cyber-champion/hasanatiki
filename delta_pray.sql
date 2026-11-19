-- Трекер намазов: ребёнок отмечает, родитель подтверждает, за подтверждённые — баллы в рейтинг.
-- Биты маски: 1 Фаджр, 2 Зухр, 4 Аср, 8 Магриб, 16 Иша.
create table if not exists prayer_log (
  group_id   uuid not null references groups(id) on delete cascade,
  student_id text not null,
  day        date not null,
  mask       int  not null default 0,   -- отметил ребёнок
  ok         int  not null default 0,   -- подтвердил родитель
  paid       int  not null default 0,   -- за что уже начислены баллы
  updated_at timestamptz not null default now(),
  primary key (group_id, student_id, day)
);
alter table prayer_log enable row level security;

create or replace function _bits(m int) returns int language sql immutable as $$
  select ((m & 1) <> 0)::int + ((m & 2) <> 0)::int + ((m & 4) <> 0)::int + ((m & 8) <> 0)::int + ((m & 16) <> 0)::int $$;

-- последние p_days дней одного ученика
create or replace function _pray_rows(gid uuid, sid text, p_days int) returns json language sql stable as $$
  select coalesce(json_agg(json_build_object('d', to_char(day, 'YYYY-MM-DD'), 'm', mask, 'ok', ok) order by day desc), '[]'::json)
  from prayer_log where group_id = gid and student_id = sid and day > _today() - greatest(1, least(coalesce(p_days, 14), 60)) $$;

-- ребёнок: получить свои отметки
create or replace function pray_get(p_slug text, p_stoken text, p_days int default 14) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; s student_sessions;
begin
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, '')));
  if not found then raise exception 'not_found'; end if;
  s := _swho(p_stoken); if s.group_id <> g.id or not _student_ok(g, s.student_id) then raise exception 'sauth'; end if;
  return json_build_object('today', to_char(_today(), 'YYYY-MM-DD'), 'rows', _pray_rows(g.id, s.student_id, p_days));
end $$;

-- ребёнок: отметить/снять намаз (только сегодня и вчера; подтверждённое снять нельзя)
create or replace function pray_mark(p_slug text, p_stoken text, p_day date, p_bit int, p_on boolean) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; s student_sessions; r prayer_log;
begin
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, '')));
  if not found then raise exception 'not_found'; end if;
  s := _swho(p_stoken); if s.group_id <> g.id or not _student_ok(g, s.student_id) then raise exception 'sauth'; end if;
  if p_day is null or p_day > _today() or p_day < _today() - 1 or p_bit not in (1, 2, 4, 8, 16) then raise exception 'bad_input'; end if;
  insert into prayer_log as l (group_id, student_id, day, mask) values (g.id, s.student_id, p_day, case when p_on then p_bit else 0 end)
  on conflict (group_id, student_id, day) do update
    set mask = case when p_on then l.mask | p_bit when (l.ok & p_bit) <> 0 then l.mask else l.mask & ~p_bit end, updated_at = now()
  returning * into r;
  return json_build_object('d', to_char(r.day, 'YYYY-MM-DD'), 'm', r.mask, 'ok', r.ok);
end $$;

-- родитель: отметки своего ребёнка
create or replace function pray_parent_get(p_slug text, p_ptoken text, p_days int default 14) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare p parent_sessions;
begin p := _pauth(p_slug, p_ptoken);
  return json_build_object('today', to_char(_today(), 'YYYY-MM-DD'), 'rows', _pray_rows(p.group_id, p.student_id, p_days));
end $$;

-- родитель: подтвердить (только отмеченные ребёнком, за последние 3 дня). 1 балл за каждый намаз, один раз.
create or replace function pray_confirm(p_slug text, p_ptoken text, p_day date, p_mask int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare p parent_sessions; g groups; r prayer_log; gain int; idx int; st jsonb; d jsonb; entry jsonb;
begin
  p := _pauth(p_slug, p_ptoken);
  if p_day is null or p_day > _today() or p_day < _today() - 2 or p_mask is null or p_mask < 0 or p_mask > 31 then raise exception 'bad_input'; end if;
  select * into g from groups where id = p.group_id for update;
  select * into r from prayer_log where group_id = g.id and student_id = p.student_id and day = p_day for update;
  if not found then raise exception 'not_found'; end if;
  update prayer_log set ok = r.mask & p_mask, updated_at = now() where group_id = g.id and student_id = p.student_id and day = p_day returning * into r;
  gain := _bits(r.ok & ~r.paid);
  if gain > 0 then
    update prayer_log set paid = paid | r.ok where group_id = g.id and student_id = p.student_id and day = p_day;
    select (e.ord - 1)::int into idx from jsonb_array_elements(g.data->'students') with ordinality as e(v, ord) where e.v->>'id' = p.student_id limit 1;
    if idx is not null then
      st := g.data->'students'->idx; d := g.data;
      if d->'log' is null or jsonb_typeof(d->'log') <> 'array' then d := jsonb_set(d, '{log}', '[]'::jsonb); end if;
      st := st || jsonb_build_object('x', coalesce((st->>'x')::numeric, 0)::int + gain, 'xp', coalesce((st->>'xp')::numeric, 0)::int + gain);
      entry := jsonb_build_object('id', encode(extensions.gen_random_bytes(6), 'hex'), 's', p.student_id, 't', 'x', 'v', gain,
                                  'g', encode(extensions.gen_random_bytes(6), 'hex'), 'note', '🕌 Намазы ' || to_char(p_day, 'DD.MM') || ' (подтвердил родитель)',
                                  'd', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
      d := jsonb_set(jsonb_set(d, '{log}', jsonb_build_array(entry) || (d->'log')), array['students', idx::text], st);
      update groups set data = d, version = version + 1, updated_at = now() where id = g.id;
    end if;
  end if;
  return json_build_object('d', to_char(r.day, 'YYYY-MM-DD'), 'm', r.mask, 'ok', r.ok, 'points', gain);
end $$;

-- учитель: сводка по группе за неделю (сколько намазов отмечено и подтверждено)
create or replace function pray_group(p_slug text, p_token text, p_days int default 7) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; t teachers;
begin
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, '')));
  if not found then raise exception 'not_found'; end if;
  t := _who(p_token); if not _can(t, g.id) then raise exception 'forbidden'; end if;
  return coalesce((select json_object_agg(student_id, json_build_object('m', m, 'ok', ok, 'days', dd)) from (
    select student_id, sum(_bits(mask))::int m, sum(_bits(ok))::int ok, count(*) filter (where mask = 31)::int dd
    from prayer_log where group_id = g.id and day > _today() - greatest(1, least(coalesce(p_days, 7), 60)) group by student_id) q), '{}'::json);
end $$;

revoke all on function _bits(int), _pray_rows(uuid, text, int) from public, anon, authenticated;
revoke all on function pray_get(text, text, int), pray_mark(text, text, date, int, boolean), pray_parent_get(text, text, int), pray_confirm(text, text, date, int), pray_group(text, text, int) from public;
grant execute on function pray_get(text, text, int), pray_mark(text, text, date, int, boolean), pray_parent_get(text, text, int), pray_confirm(text, text, date, int), pray_group(text, text, int) to anon, authenticated;
notify pgrst, 'reload schema';
