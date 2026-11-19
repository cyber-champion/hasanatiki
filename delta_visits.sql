-- ---------- Журнал входов: каждый заход ученика или родителя (начало, конец, сколько минут) ----------
create table if not exists visit_log (
  id         bigserial primary key,
  group_id   uuid not null references groups(id) on delete cascade,
  student_id text not null,
  role       text not null default 's',        -- s — ученик, p — родитель
  started_at timestamptz not null default now(),
  last_at    timestamptz not null default now(),
  secs       int not null default 0
);
create index if not exists visit_log_g on visit_log(group_id, started_at desc);
alter table visit_log enable row level security;
revoke all on visit_log from anon, authenticated;

create or replace function _visit(g uuid, sid text, r text, sec int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v visit_log;
begin
  select * into v from visit_log where group_id = g and student_id = sid and role = r order by last_at desc limit 1;
  if found and now() - v.last_at < interval '30 minutes' then
    update visit_log set last_at = now(), secs = secs + greatest(0, least(sec, 120)) where id = v.id;
  else
    insert into visit_log (group_id, student_id, role) values (g, sid, r);
  end if;
end $$;

create or replace function activity_ping(p_slug text, p_stoken text default null, p_student text default null, p_secs int default 0) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups := _g(p_slug); s student_sessions; sid text; last timestamptz; nv boolean; sec int;
begin
  if p_stoken is not null and p_stoken <> '' then
    s := _swho(p_stoken); if s.group_id <> g.id then raise exception 'sauth'; end if; sid := s.student_id;
  else sid := p_student; end if;
  if sid is null or not _student_ok(g, sid) then raise exception 'no_student'; end if;
  select max(last_at) into last from student_activity where group_id = g.id and student_id = sid;
  nv := last is null or now() - last > interval '30 minutes';
  sec := greatest(0, least(coalesce(p_secs, 0), 120));
  if not nv then sec := least(sec, ceil(extract(epoch from now() - last))::int + 5); else sec := least(sec, 60); end if;
  insert into student_activity as a (group_id, student_id, day, visits, secs, last_at)
       values (g.id, sid, _today(), case when nv then 1 else 0 end, sec, now())
  on conflict (group_id, student_id, day) do update
       set visits = a.visits + case when nv then 1 else 0 end, secs = a.secs + sec, last_at = now();
  perform _visit(g.id, sid, 's', sec);
  return json_build_object('ok', true);
end $$;

-- Родитель тоже отмечается в журнале
create or replace function parent_ping(p_slug text, p_ptoken text, p_secs int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare p parent_sessions;
begin
  p := _pauth(p_slug, p_ptoken);
  perform _visit(p.group_id, p.student_id, 'p', coalesce(p_secs, 0));
  return json_build_object('ok', true);
end $$;

create or replace function visit_journal(p_token text, p_slug text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t teachers := _who(p_token); g groups := _g(p_slug);
begin
  if not _can(t, g.id) then raise exception 'forbidden'; end if;
  return coalesce((select json_agg(x) from (select student_id s, role r, started_at a, last_at b, secs from visit_log
          where group_id = g.id order by started_at desc limit 100) x), '[]'::json);
end $$;

revoke all on function _visit(uuid, text, text, int) from public, anon, authenticated;
revoke all on function parent_ping(text, text, int), visit_journal(text, text) from public;
grant execute on function parent_ping(text, text, int), visit_journal(text, text), activity_ping(text, text, text, int) to anon, authenticated;
notify pgrst, 'reload schema';
