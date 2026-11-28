-- Кабинет родителя 2: неделя по дням, напоминания и задания от родителя ребёнку.
create table if not exists parent_notes (
  id         bigserial primary key,
  group_id   uuid not null references groups(id) on delete cascade,
  student_id text not null,
  kind       text not null check (kind in ('nudge', 'task')),
  txt        text not null,
  created_at timestamptz not null default now(),
  seen_at    timestamptz,
  done_at    timestamptz
);
create index if not exists parent_notes_kid on parent_notes (group_id, student_id, created_at desc);
alter table parent_notes enable row level security;
revoke all on parent_notes from public, anon, authenticated;

create or replace function _pauth(p_ptoken text) returns parent_sessions
language plpgsql stable security definer set search_path = public, extensions as $$
declare p parent_sessions; g groups;
begin
  select * into p from parent_sessions where token_hash = _hash(p_ptoken) and expires_at > now();
  if not found then raise exception 'pauth'; end if;
  select * into g from groups where id = p.group_id;
  if not found or not _student_ok(g, p.student_id) then raise exception 'pauth'; end if;
  return p;
end $$;

create or replace function _pnotes(gid uuid, sid text, p_open boolean) returns json
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(json_agg(json_build_object('id', n.id, 'k', n.kind, 'txt', n.txt, 'at', n.created_at,
                  'seen', n.seen_at, 'done', n.done_at) order by n.created_at desc), '[]'::json)
    from (select * from parent_notes
           where group_id = gid and student_id = sid
             and (not p_open or (done_at is null and created_at > now() - case when kind = 'nudge' then interval '2 days' else interval '14 days' end))
           order by created_at desc limit 20) n;
$$;

-- Родитель: 14 дней по дням (минуты, заходы, уроки, баллы за уроки) + свои записки ребёнку.
create or replace function parent_dash(p_ptoken text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare p parent_sessions;
begin
  p := _pauth(p_ptoken);
  return json_build_object(
    'days', (select coalesce(json_agg(json_build_object('d', d.day::date, 'secs', coalesce(a.secs, 0), 'visits', coalesce(a.visits, 0),
                     'lpts', coalesce(a.lpts, 0), 'les', coalesce(r.n, 0)) order by d.day), '[]'::json)
               from generate_series(_today() - 13, _today(), interval '1 day') d(day)
               left join student_activity a on a.group_id = p.group_id and a.student_id = p.student_id and a.day = d.day::date
               left join (select (accepted_at at time zone 'Europe/Samara')::date dd, count(*) n from lesson_receipts
                           where group_id = p.group_id and student_id = p.student_id and accepted_at > now() - interval '15 days'
                           group by 1) r on r.dd = d.day::date),
    'notes', _pnotes(p.group_id, p.student_id, false));
end $$;

create or replace function parent_note_add(p_ptoken text, p_kind text, p_txt text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare p parent_sessions; t text := btrim(coalesce(p_txt, '')); n int;
begin
  p := _pauth(p_ptoken);
  if p_kind not in ('nudge', 'task') or length(t) < 2 or length(t) > 160 then raise exception 'bad_input'; end if;
  select count(*) into n from parent_notes where group_id = p.group_id and student_id = p.student_id and created_at > now() - interval '1 day';
  if n >= 8 then raise exception 'too_many'; end if;
  insert into parent_notes (group_id, student_id, kind, txt) values (p.group_id, p.student_id, p_kind, t);
  return json_build_object('ok', true, 'notes', _pnotes(p.group_id, p.student_id, false));
end $$;

create or replace function parent_note_del(p_ptoken text, p_id bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare p parent_sessions;
begin
  p := _pauth(p_ptoken);
  delete from parent_notes where id = p_id and group_id = p.group_id and student_id = p.student_id;
  return json_build_object('ok', true, 'notes', _pnotes(p.group_id, p.student_id, false));
end $$;

-- Ребёнок: открытые записки от родителей (и отметка «увидел»).
create or replace function kid_notes(p_slug text, p_stoken text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s student_sessions; r json;
begin
  s := _wauth(p_slug, p_stoken);
  r := _pnotes(s.group_id, s.student_id, true);
  update parent_notes set seen_at = now()
   where group_id = s.group_id and student_id = s.student_id and seen_at is null;
  return r;
end $$;

create or replace function kid_note_done(p_slug text, p_stoken text, p_id bigint) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s student_sessions;
begin
  s := _wauth(p_slug, p_stoken);
  update parent_notes set done_at = now(), seen_at = coalesce(seen_at, now())
   where id = p_id and group_id = s.group_id and student_id = s.student_id;
  return json_build_object('ok', true, 'notes', _pnotes(s.group_id, s.student_id, true));
end $$;

revoke all on function _pauth(text), _pnotes(uuid, text, boolean) from public, anon, authenticated;
revoke all on function parent_dash(text), parent_note_add(text, text, text), parent_note_del(text, bigint),
  kid_notes(text, text), kid_note_done(text, text, bigint) from public;
grant execute on function parent_dash(text), parent_note_add(text, text, text), parent_note_del(text, bigint),
  kid_notes(text, text), kid_note_done(text, text, bigint) to anon, authenticated;
notify pgrst, 'reload schema';
