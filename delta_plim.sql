-- ---------- Ограничения от родителя (строже учительских) ----------
create table if not exists parent_limits (
  group_id   uuid not null references groups(id) on delete cascade,
  student_id text not null,
  les int not null default 0, min int not null default 0, night int not null default 0,   -- 0 = как у учителя
  updated_at timestamptz not null default now(),
  primary key (group_id, student_id)
);
alter table parent_limits enable row level security;
revoke all on parent_limits from anon, authenticated;

create or replace function _plim(g uuid, sid text) returns jsonb language sql stable as $$
  select coalesce((select jsonb_build_object('les', les, 'min', min, 'night', night) from parent_limits where group_id = g and student_id = sid),
                  '{"les":0,"min":0,"night":0}'::jsonb)
$$;

create or replace function _pauth(p_slug text, p_ptoken text) returns parent_sessions
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; p parent_sessions;
begin
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, '')));
  if not found then raise exception 'not_found'; end if;
  select * into p from parent_sessions where token_hash = _hash(p_ptoken) and expires_at > now();
  if not found or p.group_id <> g.id or not _student_ok(g, p.student_id) then raise exception 'pauth'; end if;
  return p;
end $$;

create or replace function parent_limit_get(p_slug text, p_ptoken text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare p parent_sessions;
begin p := _pauth(p_slug, p_ptoken); return _plim(p.group_id, p.student_id)::json; end $$;

create or replace function parent_limit_set(p_slug text, p_ptoken text, p_les int, p_min int, p_night int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare p parent_sessions;
begin
  p := _pauth(p_slug, p_ptoken);
  if p_les < 0 or p_les > 20 or p_min < 0 or p_min > 180 or not (p_night = 0 or p_night between 17 and 23) then raise exception 'bad_input'; end if;
  insert into parent_limits as l (group_id, student_id, les, min, night) values (p.group_id, p.student_id, p_les, p_min, p_night)
  on conflict (group_id, student_id) do update set les = excluded.les, min = excluded.min, night = excluded.night, updated_at = now();
  return _plim(p.group_id, p.student_id)::json;
end $$;

create or replace function wallet_get(p_slug text, p_stoken text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s student_sessions; w wallets;
begin
  s := _wauth(p_slug, p_stoken); w := _wallet(s.group_id, s.student_id);
  return (_wjson(w)::jsonb || jsonb_build_object('plim', _plim(s.group_id, s.student_id)))::json;
end $$;

revoke all on function _plim(uuid, text), _pauth(text, text) from public, anon, authenticated;
revoke all on function parent_limit_get(text, text), parent_limit_set(text, text, int, int, int) from public;
grant execute on function parent_limit_get(text, text), parent_limit_set(text, text, int, int, int) to anon, authenticated;
notify pgrst, 'reload schema';
