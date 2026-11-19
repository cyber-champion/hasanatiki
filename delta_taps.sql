-- ---------- Счётчик нажатий: куда нажимают дети, учителя и родители (без имён, только суммы по дням) ----------
create table if not exists tap_stats (
  group_id uuid not null references groups(id) on delete cascade,
  day      date not null,
  role     text not null,            -- s (ученик) / t (учитель) / p (родитель) / g (гость)
  screen   text not null,
  action   text not null,
  n        int  not null default 0,
  primary key (group_id, day, role, screen, action)
);
alter table tap_stats enable row level security;
revoke all on tap_stats from anon, authenticated;

create or replace function taps_log(p_slug text, p_token text, p_stoken text, p_ptoken text, p_ev jsonb) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; v jsonb; r text := 'g'; e jsonb; k int := 0;
begin
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, '')));
  if not found then raise exception 'not_found'; end if;
  begin v := _viewer(g, p_token, p_stoken, p_ptoken); exception when others then v := null; end;
  if v ? 't' then r := 't'; elsif v ? 's' then r := 's'; elsif v ? 'p' then r := 'p'; end if;
  if jsonb_typeof(p_ev) <> 'array' then raise exception 'bad_input'; end if;
  for e in select * from jsonb_array_elements(p_ev) loop
    k := k + 1; exit when k > 200;
    if coalesce(e->>'s', '') !~ '^[a-z0-9_:.-]{1,40}$' or coalesce(e->>'a', '') !~ '^[a-z0-9_:.-]{1,40}$' then continue; end if;
    insert into tap_stats as t (group_id, day, role, screen, action, n)
      values (g.id, _today(), r, e->>'s', e->>'a', least(greatest(coalesce((e->>'n')::int, 1), 1), 500))
    on conflict (group_id, day, role, screen, action) do update set n = t.n + excluded.n;
  end loop;
  return json_build_object('ok', true);
end $$;

create or replace function taps_report(p_slug text, p_token text, p_days int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; t teachers;
begin
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, '')));
  if not found then raise exception 'not_found'; end if;
  t := _who(p_token); if not _can(t, g.id) then raise exception 'forbidden'; end if;
  return json_build_object(
    'taps', coalesce((select json_agg(x) from (select role, screen, action, sum(n)::int n from tap_stats
              where group_id = g.id and day > _today() - greatest(1, least(coalesce(p_days, 7), 90))
              group by role, screen, action order by sum(n) desc limit 300) x), '[]'::json),
    'lessons', coalesce((select json_agg(y) from (select course, lesson, count(*)::int kids, sum(attempts)::int tries,
              round(avg(best_stars)::numeric, 1) stars, sum(greatest(total - correct, 0))::int errs from lesson_progress
              where group_id = g.id group by course, lesson order by round(avg(best_stars)::numeric, 1), sum(attempts) desc limit 30) y), '[]'::json));
end $$;

revoke all on function taps_log(text, text, text, text, jsonb), taps_report(text, text, int) from public;
grant execute on function taps_log(text, text, text, text, jsonb), taps_report(text, text, int) to anon, authenticated;
notify pgrst, 'reload schema';
