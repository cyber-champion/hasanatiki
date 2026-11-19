-- ---------- Дуэли: вызвать одноклассника, одни и те же вопросы, у кого больше ----------
create table if not exists duels (
  id         bigserial primary key,
  group_id   uuid not null references groups(id) on delete cascade,
  a          text not null,             -- кто вызвал
  b          text not null,             -- кого вызвали
  course     text not null,
  qs         jsonb not null,            -- вопросы (одни и те же для обоих)
  a_score    int not null, a_ms int not null,
  b_score    int, b_ms int,
  winner     text,                      -- id победителя, 'draw' — ничья
  created_at timestamptz not null default now(),
  done_at    timestamptz
);
create index if not exists duels_g on duels(group_id, created_at desc);
alter table duels enable row level security;
revoke all on duels from anon, authenticated;

create or replace function duel_create(p_slug text, p_stoken text, p_opp text, p_course text, p_qs jsonb, p_score int, p_ms int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s student_sessions; g groups; n int; d duels;
begin
  s := _wauth(p_slug, p_stoken); select * into g from groups where id = s.group_id;
  if p_opp = s.student_id or not _student_ok(g, p_opp) then raise exception 'bad_input'; end if;
  if coalesce(p_course, '') !~ '^[a-z]{1,8}$' or jsonb_typeof(p_qs) <> 'array' or jsonb_array_length(p_qs) < 3 or jsonb_array_length(p_qs) > 10
     or length(p_qs::text) > 30000 or p_score < 0 or p_score > jsonb_array_length(p_qs) then raise exception 'bad_input'; end if;
  select count(*) into n from duels where group_id = g.id and a = s.student_id and created_at > now() - interval '1 day';
  if n >= 5 then raise exception 'too_many'; end if;
  select count(*) into n from duels where group_id = g.id and a = s.student_id and b = p_opp and b_score is null;
  if n > 0 then raise exception 'pending'; end if;
  insert into duels (group_id, a, b, course, qs, a_score, a_ms) values (g.id, s.student_id, p_opp, p_course, p_qs, p_score, greatest(0, least(p_ms, 3600000)))
    returning * into d;
  return json_build_object('id', d.id);
end $$;

create or replace function duel_list(p_slug text, p_stoken text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s student_sessions;
begin
  s := _wauth(p_slug, p_stoken);
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select id, a, b, course, a_score, a_ms, b_score, b_ms, winner, created_at, done_at,
           case when b = s.student_id and b_score is null then qs else null end as qs, jsonb_array_length(qs) as total
      from duels where group_id = s.group_id and (a = s.student_id or b = s.student_id)
     order by created_at desc limit 20) x), '[]'::json);
end $$;

create or replace function duel_play(p_slug text, p_stoken text, p_id bigint, p_score int, p_ms int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s student_sessions; d duels; w text; wl wallets;
begin
  s := _wauth(p_slug, p_stoken);
  select * into d from duels where id = p_id and group_id = s.group_id for update;
  if not found or d.b <> s.student_id then raise exception 'not_found'; end if;
  if d.b_score is not null then raise exception 'done'; end if;
  if p_score < 0 or p_score > jsonb_array_length(d.qs) then raise exception 'bad_input'; end if;
  p_ms := greatest(0, least(p_ms, 3600000));
  w := case when p_score > d.a_score then d.b when p_score < d.a_score then d.a
            when p_ms < d.a_ms then d.b when p_ms > d.a_ms then d.a else 'draw' end;
  update duels set b_score = p_score, b_ms = p_ms, winner = w, done_at = now() where id = d.id returning * into d;
  if w <> 'draw' then
    wl := _wallet(d.group_id, w);
    update wallets set dates = dates + 10, earned = earned + 10, updated_at = now() where group_id = d.group_id and student_id = w;
    insert into wallet_log (group_id, student_id, kind, dates, pearls, note) values (d.group_id, w, 'duel', 10, 0, 'победа в дуэли');
  end if;
  return json_build_object('winner', w, 'a_score', d.a_score, 'a_ms', d.a_ms, 'b_score', d.b_score, 'b_ms', d.b_ms);
end $$;

revoke all on function duel_create(text, text, text, text, jsonb, int, int), duel_list(text, text), duel_play(text, text, bigint, int, int) from public;
grant execute on function duel_create(text, text, text, text, jsonb, int, int), duel_list(text, text), duel_play(text, text, bigint, int, int) to anon, authenticated;
notify pgrst, 'reload schema';
