-- ---------- Мотивация: финики за серию дней и за подтверждённые намазы; трудные вопросы для учителя ----------
-- Применять после delta_lim2.sql и delta_pray.sql (переопределяет _wallet_lesson и pray_confirm)

-- 1. Урок: прежнее начисление + бонус фиников за серию дней (один раз в день, при первом уроке дня)
create or replace function _wallet_lesson(g uuid, sid text, p_stars int, p_correct int, p_old int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare w wallets; gain int; pr int := 0; ch int := 0; td date := _today(); room int; note text := ''; sb int := 0; newday boolean;
begin
  w := _wallet(g, sid);
  insert into student_activity as a (group_id, student_id, day, lessons) values (g, sid, _today(), 1)
    on conflict (group_id, student_id, day) do update set lessons = a.lessons + 1;
  if w.day is distinct from td then w.day := td; w.day_dates := 0; end if;
  gain := greatest(0, coalesce(p_correct, 0)) + greatest(0, p_stars) * 2;
  room := greatest(0, 80 - w.day_dates);
  gain := least(gain, room);
  newday := w.last_day is distinct from td;
  -- серия дней
  if w.last_day is null or w.last_day < td - 1 then w.streak := 1;
  elsif w.last_day = td - 1 then w.streak := w.streak + 1;
    if w.streak % 3 = 0 then pr := pr + 1; note := 'серия ' || w.streak || ' дн.'; end if;
  end if;
  -- бонус за серию: 2 финика за каждый день подряд, не больше 14 (вне дневного лимита)
  if newday and w.streak >= 2 then sb := least(w.streak, 7) * 2; end if;
  w.last_day := td;
  if p_stars >= 1 then
    w.lessons := w.lessons + 1;
    if w.lessons % 3 = 0 then ch := 1; end if;
    if w.lessons % 5 = 0 then pr := pr + 1; end if;
  end if;
  update wallets set dates = dates + gain + sb, pearls = pearls + pr, chests = chests + ch, lessons = w.lessons,
         streak = w.streak, last_day = w.last_day, day = w.day, day_dates = w.day_dates + gain,
         earned = earned + gain + sb, updated_at = now()
   where group_id = g and student_id = sid returning * into w;
  if gain > 0 or pr > 0 then
    insert into wallet_log (group_id, student_id, kind, dates, pearls, note) values (g, sid, 'lesson', gain, pr, nullif(note, ''));
  end if;
  if sb > 0 then
    insert into wallet_log (group_id, student_id, kind, dates, pearls, note) values (g, sid, 'streak', sb, 0, 'серия ' || w.streak || ' дн.');
  end if;
  return json_build_object('dates', gain + sb, 'pearls', pr, 'chest', ch, 'streak', case when sb > 0 then w.streak else 0 end, 'sdates', sb, 'wallet', _wjson(w));
end $$;

-- 2. Намазы: родитель подтвердил — +1 балл и +2 финика за каждый намаз, +5 фиников за все 5 за день
create or replace function pray_confirm(p_slug text, p_ptoken text, p_day date, p_mask int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare p parent_sessions; g groups; r prayer_log; gain int; idx int; st jsonb; d jsonb; entry jsonb; was int; dd int := 0;
begin
  p := _pauth(p_slug, p_ptoken);
  if p_day is null or p_day > _today() or p_day < _today() - 2 or p_mask is null or p_mask < 0 or p_mask > 31 then raise exception 'bad_input'; end if;
  select * into g from groups where id = p.group_id for update;
  select * into r from prayer_log where group_id = g.id and student_id = p.student_id and day = p_day for update;
  if not found then raise exception 'not_found'; end if;
  was := r.paid;
  update prayer_log set ok = r.mask & p_mask, updated_at = now() where group_id = g.id and student_id = p.student_id and day = p_day returning * into r;
  gain := _bits(r.ok & ~r.paid);
  if gain > 0 then
    update prayer_log set paid = paid | r.ok where group_id = g.id and student_id = p.student_id and day = p_day;
    dd := gain * 2 + case when (was | r.ok) = 31 and was <> 31 then 5 else 0 end;
    perform _wallet(g.id, p.student_id);
    update wallets set dates = dates + dd, earned = earned + dd, updated_at = now() where group_id = g.id and student_id = p.student_id;
    insert into wallet_log (group_id, student_id, kind, dates, pearls, note) values (g.id, p.student_id, 'pray', dd, 0, 'намазы ' || to_char(p_day, 'DD.MM'));
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
  return json_build_object('d', to_char(r.day, 'YYYY-MM-DD'), 'm', r.mask, 'ok', r.ok, 'points', gain, 'dates', dd);
end $$;

-- 3. Трудные вопросы: ошибки учеников в уроках (без имён, только сколько раз ошиблись)
create table if not exists miss_stats (
  group_id uuid not null references groups(id) on delete cascade,
  day      date not null,
  course   text not null,
  q        text not null,
  n        int  not null default 0,
  kids     text[] not null default '{}',
  primary key (group_id, day, course, q)
);
alter table miss_stats enable row level security;
revoke all on miss_stats from anon, authenticated;

create or replace function miss_log(p_slug text, p_stoken text, p_course text, p_q text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; s student_sessions; qq text := left(btrim(coalesce(p_q, '')), 140);
begin
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, '')));
  if not found then raise exception 'not_found'; end if;
  s := _swho(p_stoken); if s.group_id <> g.id or not _student_ok(g, s.student_id) then raise exception 'sauth'; end if;
  if coalesce(p_course, '') !~ '^[a-z0-9_-]{1,32}$' or qq = '' then raise exception 'bad_input'; end if;
  if (select coalesce(sum(n), 0) from miss_stats where group_id = g.id and day = _today()) > 3000 then return json_build_object('ok', false); end if;
  insert into miss_stats as m (group_id, day, course, q, n, kids) values (g.id, _today(), p_course, qq, 1, array[s.student_id])
  on conflict (group_id, day, course, q) do update set n = m.n + 1,
     kids = case when s.student_id = any(m.kids) then m.kids else m.kids || s.student_id end;
  return json_build_object('ok', true);
end $$;

create or replace function miss_report(p_slug text, p_token text, p_days int default 7) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; t teachers;
begin
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, '')));
  if not found then raise exception 'not_found'; end if;
  t := _who(p_token); if not _can(t, g.id) then raise exception 'forbidden'; end if;
  return coalesce((select json_agg(x) from (
    with a as (select course, q, sum(n)::int n from miss_stats
                where group_id = g.id and day > _today() - greatest(1, least(coalesce(p_days, 7), 60)) group by course, q),
         b as (select course, q, count(distinct k)::int kids from miss_stats, unnest(kids) k
                where group_id = g.id and day > _today() - greatest(1, least(coalesce(p_days, 7), 60)) group by course, q)
    select a.course, a.q, a.n, b.kids from a join b using (course, q) order by b.kids desc, a.n desc limit 20) x), '[]'::json);
end $$;

revoke all on function miss_log(text, text, text, text), miss_report(text, text, int) from public;
grant execute on function miss_log(text, text, text, text), miss_report(text, text, int) to anon, authenticated;
notify pgrst, 'reload schema';
