-- =====================================================================
--  Хасанатики — база данных для Supabase
--  Как запустить: Supabase → SQL Editor → New query → вставить ВЕСЬ
--  этот текст → Run. Запускать повторно безопасно: данные не удаляются.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- таблицы ----------
create table if not exists teachers (
  id           uuid primary key default gen_random_uuid(),
  login        text not null unique,
  name         text not null,
  pass_hash    text not null,
  is_admin     boolean not null default false,
  failed       int not null default 0,
  locked_until timestamptz,
  created_at   timestamptz not null default now()
);

create table if not exists groups (
  id         uuid primary key default gen_random_uuid(),
  slug       text not null unique,
  name       text not null,
  data       jsonb not null default '{}'::jsonb,
  version    int not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid references teachers(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists teacher_groups (
  teacher_id uuid not null references teachers(id) on delete cascade,
  group_id   uuid not null references groups(id) on delete cascade,
  primary key (teacher_id, group_id)
);

create table if not exists sessions (
  token_hash text primary key,
  teacher_id uuid not null references teachers(id) on delete cascade,
  expires_at timestamptz not null
);

-- Прогресс уроков (для учебной части платформы: звёзды и попытки по каждому уроку)
create table if not exists lesson_progress (
  group_id   uuid not null references groups(id) on delete cascade,
  student_id text not null,
  course     text not null,
  lesson     text not null,
  stars      smallint not null default 0,
  best_stars smallint not null default 0,
  correct    int not null default 0,
  total      int not null default 0,
  attempts   int not null default 0,
  first_at   timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (group_id, student_id, course, lesson)
);

-- Прямой доступ к таблицам закрыт. Сайт работает только через функции ниже.
alter table teachers       enable row level security;
alter table groups         enable row level security;
alter table teacher_groups enable row level security;
alter table sessions       enable row level security;
alter table lesson_progress enable row level security;
revoke all on teachers, groups, teacher_groups, sessions, lesson_progress from anon, authenticated;

-- ---------- служебные функции (снаружи недоступны) ----------
create or replace function _hash(p text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(extensions.digest(coalesce(p, ''), 'sha256'), 'hex')
$$;

create or replace function _who(p_token text) returns teachers
language plpgsql stable security definer set search_path = public, extensions as $$
declare t teachers;
begin
  select tt.* into t
    from sessions s join teachers tt on tt.id = s.teacher_id
   where s.token_hash = _hash(p_token) and s.expires_at > now();
  if not found then raise exception 'auth'; end if;
  return t;
end $$;

create or replace function _admin(p_token text) returns teachers
language plpgsql stable security definer set search_path = public, extensions as $$
declare t teachers;
begin
  t := _who(p_token);
  if not t.is_admin then raise exception 'forbidden'; end if;
  return t;
end $$;

create or replace function _can(t teachers, p_group uuid) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select t.is_admin or exists (select 1 from teacher_groups where teacher_id = t.id and group_id = p_group)
$$;

create or replace function _me(t teachers) returns json
language sql stable security definer set search_path = public, extensions as $$
  select json_build_object(
    'id', t.id, 'login', t.login, 'name', t.name, 'is_admin', t.is_admin,
    'groups', coalesce((
      select json_agg(json_build_object('slug', g.slug, 'name', g.name) order by g.name)
        from groups g
       where t.is_admin or exists (select 1 from teacher_groups tg where tg.teacher_id = t.id and tg.group_id = g.id)
    ), '[]'::json))
$$;

create or replace function _new_session(t teachers) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare tok text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  delete from sessions where expires_at < now();
  insert into sessions(token_hash, teacher_id, expires_at) values (_hash(tok), t.id, now() + interval '180 days');
  return json_build_object('ok', true, 'token', tok, 'me', _me(t));
end $$;

-- Код группы: 6 знаков без похожих букв и цифр (нет 0/o, 1/l/i)
create or replace function _new_code() returns text
language plpgsql volatile security definer set search_path = public, extensions as $$
declare a text := 'abcdefghjkmnpqrstuvwxyz23456789'; c text; b bytea;
begin
  loop
    b := extensions.gen_random_bytes(6); c := '';
    for i in 0..5 loop c := c || substr(a, 1 + (get_byte(b, i) % length(a)), 1); end loop;
    exit when not exists (select 1 from groups where slug = c);
  end loop;
  return c;
end $$;

create or replace function _student_ok(g groups, p_student text) returns boolean
language sql stable as $$
  select jsonb_typeof(g.data->'students') = 'array'
     and exists (select 1 from jsonb_array_elements(g.data->'students') e where e->>'id' = p_student)
$$;

create or replace function _check_pass(p text) returns void
language plpgsql immutable as $$
begin
  if p is null or length(p) < 6 then raise exception 'short_password'; end if;
  if length(p) > 72 then raise exception 'long_password'; end if;
end $$;

-- ---------- открытые функции: смотреть может любой ----------
-- Список групп наружу не отдаётся: группу открывают только по коду (ссылке).
create or replace function app_info() returns json
language sql stable security definer set search_path = public, extensions as $$
  select json_build_object('has_admin', exists (select 1 from teachers))
$$;

create or replace function group_get(p_slug text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare g groups;
begin
  select * into g from groups where slug = lower(trim(p_slug));
  if not found then raise exception 'not_found'; end if;
  return json_build_object('slug', g.slug, 'name', g.name, 'version', g.version, 'data', g.data, 'updated_at', g.updated_at);
end $$;

-- Первый администратор. Работает только пока в базе нет ни одного учителя.
create or replace function setup_admin(p_login text, p_name text, p_password text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t teachers;
begin
  perform pg_advisory_xact_lock(4242);
  if exists (select 1 from teachers) then raise exception 'exists'; end if;
  if coalesce(trim(p_login), '') !~ '^\S{3,32}$' then raise exception 'bad_login_format'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'bad_name'; end if;
  perform _check_pass(p_password);
  insert into teachers(login, name, pass_hash, is_admin)
       values (lower(trim(p_login)), left(trim(p_name), 40), extensions.crypt(p_password, extensions.gen_salt('bf', 8)), true)
    returning * into t;
  return _new_session(t);
end $$;

create or replace function login(p_login text, p_password text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t teachers;
begin
  select * into t from teachers where login = lower(trim(coalesce(p_login, '')));
  if not found then
    perform extensions.crypt('x', extensions.gen_salt('bf', 8));   -- одинаковое время ответа
    return json_build_object('ok', false, 'error', 'bad_login');
  end if;
  if t.locked_until is not null and t.locked_until > now() then
    return json_build_object('ok', false, 'error', 'locked');
  end if;
  if extensions.crypt(coalesce(p_password, ''), t.pass_hash) <> t.pass_hash then
    update teachers
       set failed = case when failed + 1 >= 8 then 0 else failed + 1 end,
           locked_until = case when failed + 1 >= 8 then now() + interval '15 minutes' else locked_until end
     where id = t.id;
    return json_build_object('ok', false, 'error', 'bad_login');
  end if;
  update teachers set failed = 0, locked_until = null where id = t.id;
  return _new_session(t);
end $$;

-- ---------- для учителей ----------
create or replace function me(p_token text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  return _me(_who(p_token));
end $$;

create or replace function logout(p_token text) returns json
language sql security definer set search_path = public, extensions as $$
  delete from sessions where token_hash = _hash(p_token);
  select json_build_object('ok', true);
$$;

create or replace function change_password(p_token text, p_old text, p_new text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t teachers := _who(p_token);
begin
  if extensions.crypt(coalesce(p_old, ''), t.pass_hash) <> t.pass_hash then
    return json_build_object('ok', false, 'error', 'bad_password');
  end if;
  perform _check_pass(p_new);
  update teachers set pass_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 8)) where id = t.id;
  delete from sessions where teacher_id = t.id and token_hash <> _hash(p_token);
  return json_build_object('ok', true);
end $$;

create or replace function group_save(p_token text, p_slug text, p_data jsonb, p_version int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t teachers := _who(p_token); g groups; nv int;
begin
  select * into g from groups where slug = lower(trim(p_slug));
  if not found then raise exception 'not_found'; end if;
  if not _can(t, g.id) then raise exception 'forbidden'; end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then raise exception 'bad_input'; end if;
  if length(p_data::text) > 900000 then raise exception 'too_large'; end if;
  update groups set data = p_data, version = version + 1, updated_at = now(), updated_by = t.id
   where id = g.id and version = p_version
  returning version into nv;
  if nv is null then
    select * into g from groups where id = g.id;
    return json_build_object('ok', false, 'conflict', true, 'version', g.version, 'data', g.data);
  end if;
  return json_build_object('ok', true, 'version', nv);
end $$;

-- ---------- для администратора ----------
create or replace function admin_list(p_token text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  return json_build_object(
    'groups', coalesce((select json_agg(json_build_object('slug', g.slug, 'name', g.name,
                  'students', coalesce(jsonb_array_length(case when jsonb_typeof(g.data->'students') = 'array' then g.data->'students' end), 0))
                  order by g.name) from groups g), '[]'::json),
    'teachers', coalesce((select json_agg(json_build_object('id', t.id, 'login', t.login, 'name', t.name, 'is_admin', t.is_admin,
                  'groups', coalesce((select json_agg(g.slug order by g.name) from teacher_groups tg join groups g on g.id = tg.group_id where tg.teacher_id = t.id), '[]'::json))
                  order by t.is_admin desc, t.name) from teachers t), '[]'::json));
end $$;

create or replace function admin_group_save(p_token text, p_slug text, p_name text, p_new boolean, p_def_g text default 'm') returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s text := lower(trim(coalesce(p_slug, ''))); n text := left(trim(coalesce(p_name, '')), 60);
begin
  perform _admin(p_token);
  if n = '' then raise exception 'bad_name'; end if;
  if p_new then
    s := _new_code();
    insert into groups(slug, name, data)
         values (s, n, jsonb_build_object('defG', case when p_def_g in ('m', 'f', 'x') then p_def_g else 'm' end));
  else
    update groups set name = n where slug = s;
    if not found then raise exception 'not_found'; end if;
  end if;
  return (admin_list(p_token)::jsonb || jsonb_build_object('created', s))::json;
end $$;

create or replace function admin_group_newcode(p_token text, p_slug text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s text;
begin
  perform _admin(p_token);
  s := _new_code();
  update groups set slug = s where slug = lower(trim(p_slug));
  if not found then raise exception 'not_found'; end if;
  return (admin_list(p_token)::jsonb || jsonb_build_object('created', s))::json;
end $$;

create or replace function admin_group_delete(p_token text, p_slug text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_token);
  delete from groups where slug = lower(trim(p_slug));
  return admin_list(p_token);
end $$;

create or replace function admin_teacher_save(p_token text, p_id uuid, p_login text, p_name text, p_password text, p_is_admin boolean, p_groups text[]) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a teachers := _admin(p_token); tid uuid := p_id; l text := lower(trim(coalesce(p_login, ''))); n text := left(trim(coalesce(p_name, '')), 40);
begin
  if l !~ '^\S{3,32}$' then raise exception 'bad_login_format'; end if;
  if n = '' then raise exception 'bad_name'; end if;
  if exists (select 1 from teachers where login = l and id is distinct from tid) then raise exception 'login_taken'; end if;
  if tid is null then
    perform _check_pass(p_password);
    insert into teachers(login, name, pass_hash, is_admin)
         values (l, n, extensions.crypt(p_password, extensions.gen_salt('bf', 8)), coalesce(p_is_admin, false))
      returning id into tid;
  else
    if tid = a.id and not coalesce(p_is_admin, false) then raise exception 'self_admin'; end if;
    update teachers set login = l, name = n, is_admin = coalesce(p_is_admin, false) where id = tid;
    if not found then raise exception 'not_found'; end if;
    if coalesce(p_password, '') <> '' then
      perform _check_pass(p_password);
      update teachers set pass_hash = extensions.crypt(p_password, extensions.gen_salt('bf', 8)), failed = 0, locked_until = null where id = tid;
      delete from sessions where teacher_id = tid and teacher_id <> a.id;
    end if;
  end if;
  delete from teacher_groups where teacher_id = tid;
  insert into teacher_groups(teacher_id, group_id)
       select tid, g.id from groups g where g.slug = any(coalesce(p_groups, '{}'::text[]));
  return admin_list(p_token);
end $$;

create or replace function admin_teacher_delete(p_token text, p_id uuid) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a teachers := _admin(p_token);
begin
  if p_id = a.id then raise exception 'self_delete'; end if;
  delete from teachers where id = p_id;
  return admin_list(p_token);
end $$;

-- ---------- прогресс уроков (учебная часть) ----------
-- Ребёнок сохраняет результат урока, зная код группы и свой id из списка учеников.
create or replace function progress_save(p_code text, p_student text, p_course text, p_lesson text, p_stars int, p_correct int, p_total int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups;
begin
  select * into g from groups where slug = lower(trim(p_code));
  if not found then raise exception 'not_found'; end if;
  if not _student_ok(g, p_student) then raise exception 'no_student'; end if;
  if coalesce(p_course, '') !~ '^[a-z0-9_-]{1,32}$' or coalesce(p_lesson, '') !~ '^[a-z0-9_-]{1,32}$' then raise exception 'bad_input'; end if;
  if p_stars is null or p_stars < 0 or p_stars > 3 then raise exception 'bad_input'; end if;
  insert into lesson_progress as lp (group_id, student_id, course, lesson, stars, best_stars, correct, total, attempts)
       values (g.id, p_student, p_course, p_lesson, p_stars, p_stars, greatest(coalesce(p_correct, 0), 0), greatest(coalesce(p_total, 0), 0), 1)
  on conflict (group_id, student_id, course, lesson) do update
       set stars = excluded.stars, best_stars = greatest(lp.best_stars, excluded.stars),
           correct = excluded.correct, total = excluded.total, attempts = lp.attempts + 1, updated_at = now();
  return json_build_object('ok', true);
end $$;

create or replace function progress_get(p_code text, p_student text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare g groups;
begin
  select * into g from groups where slug = lower(trim(p_code));
  if not found then raise exception 'not_found'; end if;
  return coalesce((select json_agg(json_build_object('course', course, 'lesson', lesson, 'stars', stars, 'best_stars', best_stars,
                    'correct', correct, 'total', total, 'attempts', attempts, 'updated_at', updated_at) order by course, lesson)
                     from lesson_progress where group_id = g.id and student_id = p_student), '[]'::json);
end $$;

-- Учитель видит прогресс всей группы.
create or replace function progress_group(p_token text, p_slug text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare t teachers := _who(p_token); g groups;
begin
  select * into g from groups where slug = lower(trim(p_slug));
  if not found then raise exception 'not_found'; end if;
  if not _can(t, g.id) then raise exception 'forbidden'; end if;
  return coalesce((select json_agg(json_build_object('student', student_id, 'course', course, 'lesson', lesson, 'stars', stars,
                    'best_stars', best_stars, 'attempts', attempts, 'updated_at', updated_at) order by student_id, course, lesson)
                     from lesson_progress where group_id = g.id), '[]'::json);
end $$;

-- ---------- права ----------
grant usage on schema public to anon, authenticated;
revoke all on function _hash(text), _who(text), _admin(text), _can(teachers, uuid), _me(teachers), _new_session(teachers), _check_pass(text),
  _new_code(), _student_ok(groups, text)
  from public, anon, authenticated;
revoke all on function app_info(), group_get(text), setup_admin(text, text, text), login(text, text), me(text), logout(text),
  change_password(text, text, text), group_save(text, text, jsonb, int), admin_list(text), admin_group_save(text, text, text, boolean, text),
  admin_group_newcode(text, text), admin_group_delete(text, text), admin_teacher_save(text, uuid, text, text, text, boolean, text[]),
  admin_teacher_delete(text, uuid), progress_save(text, text, text, text, int, int, int), progress_get(text, text), progress_group(text, text)
  from public;
grant execute on function app_info(), group_get(text), setup_admin(text, text, text), login(text, text), me(text), logout(text),
  change_password(text, text, text), group_save(text, text, jsonb, int), admin_list(text), admin_group_save(text, text, text, boolean, text),
  admin_group_newcode(text, text), admin_group_delete(text, text), admin_teacher_save(text, uuid, text, text, text, boolean, text[]),
  admin_teacher_delete(text, uuid), progress_save(text, text, text, text, int, int, int), progress_get(text, text), progress_group(text, text)
  to anon, authenticated;

notify pgrst, 'reload schema';
