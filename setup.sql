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

-- =====================================================================
--  ДОМАШНИЕ ЗАДАНИЯ, ФАЙЛЫ И ЛИЧНЫЕ КАБИНЕТЫ УЧЕНИКОВ
-- =====================================================================
create table if not exists student_keys (          -- PIN-коды учеников (выдаёт учитель)
  group_id     uuid not null references groups(id) on delete cascade,
  student_id   text not null,
  pin          text not null,
  failed       int not null default 0,
  locked_until timestamptz,
  primary key (group_id, student_id)
);
create table if not exists student_sessions (      -- входы учеников
  token_hash text primary key,
  group_id   uuid not null references groups(id) on delete cascade,
  student_id text not null,
  expires_at timestamptz not null
);
create table if not exists homework (
  id         uuid primary key default gen_random_uuid(),
  group_id   uuid not null references groups(id) on delete cascade,
  title      text not null,
  body       text not null default '',
  due        date,
  points     int not null default 3,
  created_by uuid references teachers(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists homework_group_idx on homework(group_id, created_at desc);
alter table homework add column if not exists sura text;
alter table homework add column if not exists listen int;     -- сколько раз прослушать суру в плеере (необязательно)      -- если задание — выучить суру: при приёме сура засчитывается сама
create table if not exists submissions (           -- ответы учеников
  homework_id  uuid not null references homework(id) on delete cascade,
  student_id   text not null,
  note         text not null default '',
  status       text not null default 'sent',       -- sent | accepted | returned
  teacher_note text not null default '',
  points       int not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  reviewed_at  timestamptz,
  reviewed_by  uuid references teachers(id) on delete set null,
  primary key (homework_id, student_id)
);
create table if not exists hw_files (              -- файлы заданий и ответов (сами файлы лежат в Storage)
  id          uuid primary key default gen_random_uuid(),
  group_id    uuid not null references groups(id) on delete cascade,
  homework_id uuid not null references homework(id) on delete cascade,
  student_id  text,                                -- пусто: файл учителя; иначе файл ответа ученика
  path        text not null unique,
  name        text not null,
  mime        text not null default '',
  size        bigint not null default 0,
  ready       boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists hw_files_hw_idx on hw_files(homework_id);
create table if not exists file_tickets (          -- временные пропуска к файлам: r — читать, w — загрузить, d — удалить
  path       text not null,
  op         text not null,
  expires_at timestamptz not null,
  primary key (path, op)
);

alter table student_keys     enable row level security;
alter table student_sessions enable row level security;
alter table homework         enable row level security;
alter table submissions      enable row level security;
alter table hw_files         enable row level security;
alter table file_tickets     enable row level security;
revoke all on student_keys, student_sessions, homework, submissions, hw_files, file_tickets from anon, authenticated;

-- ---------- служебные ----------
create or replace function _g(p_slug text) returns groups
language plpgsql stable security definer set search_path = public, extensions as $$
declare g groups;
begin
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, '')));
  if not found then raise exception 'not_found'; end if;
  return g;
end $$;

create or replace function _swho(p_stoken text) returns student_sessions
language plpgsql stable security definer set search_path = public, extensions as $$
declare s student_sessions;
begin
  select * into s from student_sessions where token_hash = _hash(p_stoken) and expires_at > now();
  if not found then raise exception 'sauth'; end if;
  return s;
end $$;

-- Кто обращается: {"t": id учителя} или {"s": id ученика}. Чужая группа — ошибка.
create or replace function _actor(g groups, p_token text, p_stoken text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare t teachers; s student_sessions;
begin
  if p_token is not null and p_token <> '' then
    t := _who(p_token);
    if not _can(t, g.id) then raise exception 'forbidden'; end if;
    return jsonb_build_object('t', t.id);
  elsif p_stoken is not null and p_stoken <> '' then
    s := _swho(p_stoken);
    if s.group_id <> g.id or not _student_ok(g, s.student_id) then raise exception 'sauth'; end if;
    return jsonb_build_object('s', s.student_id);
  end if;
  raise exception 'auth';
end $$;

create or replace function _ticket(p_path text, p_op text, p_minutes int) returns void
language plpgsql volatile security definer set search_path = public, extensions as $$
begin
  delete from file_tickets where expires_at < now();
  insert into file_tickets(path, op, expires_at) values (p_path, p_op, now() + make_interval(mins => p_minutes))
  on conflict (path, op) do update set expires_at = excluded.expires_at;
end $$;

create or replace function _files_json(p_homework uuid, p_student text) returns json
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(json_agg(json_build_object('id', f.id, 'name', f.name, 'mime', f.mime, 'size', f.size) order by f.created_at), '[]'::json)
    from hw_files f
   where f.homework_id = p_homework and f.ready and f.student_id is not distinct from p_student
$$;

-- Проверка пропуска. Её вызывают правила доступа к хранилищу файлов (см. в конце).
create or replace function hw_file_ok(p_name text, p_op text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from file_tickets
                  where path = p_name and expires_at > now() and (p_op = 'any' or op = p_op))
$$;

-- ---------- личные кабинеты учеников ----------
-- Учитель: список PIN-кодов. p_make — выдать тем, у кого нет; p_student — выдать новый одному.
create or replace function student_pins(p_token text, p_slug text, p_make boolean default false, p_student text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t teachers; g groups; sid text; b bytea;
begin
  t := _who(p_token); g := _g(p_slug);
  if not _can(t, g.id) then raise exception 'forbidden'; end if;
  if jsonb_typeof(g.data->'students') = 'array' then
    for sid in select e->>'id' from jsonb_array_elements(g.data->'students') e loop
      if (p_student is not null and sid = p_student)
         or (p_make and not exists (select 1 from student_keys where group_id = g.id and student_id = sid)) then
        b := extensions.gen_random_bytes(3);
        insert into student_keys(group_id, student_id, pin)
        values (g.id, sid, lpad((((get_byte(b,0) * 65536 + get_byte(b,1) * 256 + get_byte(b,2)) % 9000) + 1000)::text, 4, '0'))
        on conflict (group_id, student_id) do update set pin = excluded.pin, failed = 0, locked_until = null;
        if p_student is not null then
          delete from student_sessions where group_id = g.id and student_id = sid;
        end if;
      end if;
    end loop;
  end if;
  return coalesce((select json_agg(json_build_object('student_id', k.student_id, 'pin', k.pin))
                     from student_keys k where k.group_id = g.id), '[]'::json);
end $$;

create or replace function student_login(p_slug text, p_student text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; k student_keys; tok text;
begin
  g := _g(p_slug);
  select * into k from student_keys where group_id = g.id and student_id = p_student;
  if not found or not _student_ok(g, p_student) then return json_build_object('ok', false, 'error', 'no_pin'); end if;
  if k.locked_until is not null and k.locked_until > now() then return json_build_object('ok', false, 'error', 'locked'); end if;
  if k.pin <> regexp_replace(coalesce(p_pin, ''), '\D', '', 'g') then
    update student_keys set failed = case when failed + 1 >= 5 then 0 else failed + 1 end,
           locked_until = case when failed + 1 >= 5 then now() + interval '15 minutes' else null end
     where group_id = g.id and student_id = p_student;
    return json_build_object('ok', false, 'error', 'bad_pin');
  end if;
  update student_keys set failed = 0, locked_until = null where group_id = g.id and student_id = p_student;
  delete from student_sessions where expires_at < now();
  tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into student_sessions(token_hash, group_id, student_id, expires_at) values (_hash(tok), g.id, p_student, now() + interval '180 days');
  return json_build_object('ok', true, 'token', tok, 'student_id', p_student);
end $$;

create or replace function student_logout(p_stoken text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from student_sessions where token_hash = _hash(p_stoken);
  return json_build_object('ok', true);
end $$;

-- ---------- задания ----------
-- Список заданий группы. Гость видит задания и файлы учителя; ученик — ещё и свой ответ; учитель — все ответы.
create or replace function hw_list(p_slug text, p_token text default null, p_stoken text default null) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare g groups; a jsonb := '{}'::jsonb; tid text; sid text; items json;
begin
  g := _g(p_slug);
  begin
    a := _actor(g, p_token, p_stoken);
  exception when others then a := '{}'::jsonb;      -- вход истёк: показываем как гостю
  end;
  tid := a->>'t'; sid := a->>'s';
  select coalesce(json_agg(row_to_json(x) order by x.created_at desc), '[]'::json) into items from (
    select h.id, h.title, h.body, h.due, h.points, h.sura, h.listen, h.created_at,
           case when sid is not null and h.listen is not null and h.sura is not null then (
             select count(*) from listens l where l.group_id = g.id and l.student_id = sid and l.sura = h.sura and l.at >= h.created_at) end as my_listens,
           case when tid is not null and h.listen is not null and h.sura is not null then (
             select coalesce(json_object_agg(q.student_id, q.n), '{}'::json) from (
               select l.student_id, count(*) as n from listens l
                where l.group_id = g.id and l.sura = h.sura and l.at >= h.created_at group by l.student_id) q) end as listens,
           _files_json(h.id, null) as files,
           case when sid is not null then (
             select json_build_object('status', s.status, 'note', s.note, 'teacher_note', s.teacher_note, 'points', s.points, 'updated_at', s.updated_at)
               from submissions s where s.homework_id = h.id and s.student_id = sid) end as my,
           case when sid is not null then _files_json(h.id, sid) end as my_files,
           case when tid is not null then (
             select coalesce(json_agg(json_build_object('student_id', s.student_id, 'status', s.status, 'note', s.note,
                      'teacher_note', s.teacher_note, 'points', s.points, 'updated_at', s.updated_at,
                      'files', _files_json(h.id, s.student_id)) order by s.updated_at desc), '[]'::json)
               from submissions s where s.homework_id = h.id) end as subs
      from homework h
     where h.group_id = g.id
     order by h.created_at desc
     limit 60) x;
  return json_build_object('role', case when tid is not null then 'teacher' when sid is not null then 'student' else 'guest' end,
                           'student_id', sid, 'items', items,
                           'msg_unread', case when tid is not null then _msg_unread(g.id, null, 't') when sid is not null then _msg_unread(g.id, sid, 's') else 0 end);
end $$;

drop function if exists hw_save(text, text, uuid, text, text, date, int);
drop function if exists hw_save(text, text, uuid, text, text, date, int, text);
create or replace function hw_save(p_token text, p_slug text, p_id uuid, p_title text, p_body text, p_due date, p_points int, p_sura text default null, p_listen int default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t teachers; g groups; ttl text := btrim(coalesce(p_title, '')); pts int := greatest(0, least(50, coalesce(p_points, 0))); hid uuid;
        sr text := nullif(left(btrim(coalesce(p_sura, '')), 60), '');
        ls int := case when coalesce(p_listen, 0) > 0 then least(p_listen, 500) end;
begin
  t := _who(p_token); g := _g(p_slug);
  if not _can(t, g.id) then raise exception 'forbidden'; end if;
  if ttl = '' or length(ttl) > 120 then raise exception 'bad_name'; end if;
  if length(coalesce(p_body, '')) > 4000 then raise exception 'too_large'; end if;
  if p_id is null then
    insert into homework(group_id, title, body, due, points, created_by, sura, listen)
    values (g.id, ttl, coalesce(p_body, ''), p_due, pts, t.id, sr, ls) returning id into hid;
    perform _push(g.id, null, false, true, 'Новое задание 📚', ttl, '#/g/' || g.slug || '/hw');
  else
    update homework set title = ttl, body = coalesce(p_body, ''), due = p_due, points = pts, sura = sr, listen = ls
     where id = p_id and group_id = g.id returning id into hid;
    if hid is null then raise exception 'not_found'; end if;
  end if;
  return json_build_object('id', hid);
end $$;

create or replace function hw_delete(p_token text, p_slug text, p_id uuid) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t teachers; g groups;
begin
  t := _who(p_token); g := _g(p_slug);
  if not _can(t, g.id) then raise exception 'forbidden'; end if;
  delete from homework where id = p_id and group_id = g.id;
  return json_build_object('ok', true);
end $$;

-- Ученик отправляет ответ на проверку (текст и/или уже загруженные файлы).
create or replace function hw_submit(p_slug text, p_stoken text, p_homework uuid, p_note text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; a jsonb; sid text; nt text := left(btrim(coalesce(p_note, '')), 1000);
begin
  g := _g(p_slug); a := _actor(g, null, p_stoken); sid := a->>'s';
  if not exists (select 1 from homework where id = p_homework and group_id = g.id) then raise exception 'not_found'; end if;
  if exists (select 1 from submissions where homework_id = p_homework and student_id = sid and status = 'accepted') then raise exception 'accepted'; end if;
  if nt = '' and not exists (select 1 from hw_files where homework_id = p_homework and student_id = sid and ready) then raise exception 'empty'; end if;
  insert into submissions(homework_id, student_id, note, status) values (p_homework, sid, nt, 'sent')
  on conflict (homework_id, student_id) do update set note = excluded.note, status = 'sent', updated_at = now();
  perform _push(g.id, null, true, false, 'Задание на проверку', _sname(g, sid) || ': ' || (select title from homework where id = p_homework), '#/g/' || g.slug || '/hw');
  return json_build_object('ok', true);
end $$;

-- Учитель принимает (баллы сразу идут в рейтинг) или возвращает на доработку.
-- Можно принять и без ответа в приложении — например, ученик ответил устно на уроке.
create or replace function hw_review(p_token text, p_slug text, p_homework uuid, p_student text, p_accept boolean, p_note text, p_points int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t teachers; g groups; h homework; s submissions; pts int; idx int; st jsonb; d jsonb; entry jsonb; ver int;
        nt text := left(btrim(coalesce(p_note, '')), 500);
begin
  t := _who(p_token);
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, ''))) for update;
  if not found then raise exception 'not_found'; end if;
  if not _can(t, g.id) then raise exception 'forbidden'; end if;
  select * into h from homework where id = p_homework and group_id = g.id;
  if not found then raise exception 'not_found'; end if;
  if not _student_ok(g, p_student) then raise exception 'no_student'; end if;
  select * into s from submissions where homework_id = h.id and student_id = p_student for update;
  if found and s.status = 'accepted' then return json_build_object('ok', true, 'changed', false); end if;
  if not coalesce(p_accept, false) then
    if s.homework_id is null then raise exception 'not_found'; end if;
    update submissions set status = 'returned', teacher_note = nt, reviewed_at = now(), reviewed_by = t.id, updated_at = now()
     where homework_id = h.id and student_id = p_student;
    perform _push(g.id, p_student, false, false, 'Задание вернули на доработку', h.title || coalesce(': ' || nullif(nt, ''), ''), '#/g/' || g.slug || '/hw');
    return json_build_object('ok', true, 'changed', true);
  end if;
  pts := greatest(0, least(50, coalesce(p_points, h.points)));
  insert into submissions(homework_id, student_id, status, teacher_note, points, reviewed_at, reviewed_by)
  values (h.id, p_student, 'accepted', nt, pts, now(), t.id)
  on conflict (homework_id, student_id) do update
    set status = 'accepted', teacher_note = excluded.teacher_note, points = excluded.points, reviewed_at = now(), reviewed_by = t.id, updated_at = now();
  ver := g.version;
  select (e.ord - 1)::int into idx from jsonb_array_elements(g.data->'students') with ordinality as e(v, ord) where e.v->>'id' = p_student limit 1;
  st := g.data->'students'->idx; d := g.data;
  if d->'log' is null or jsonb_typeof(d->'log') <> 'array' then d := jsonb_set(d, '{log}', '[]'::jsonb); end if;
  if pts > 0 then
    st := st || jsonb_build_object('x',  coalesce((st->>'x')::numeric, 0)::int + pts,
                                   'xp', coalesce((st->>'xp')::numeric, 0)::int + pts);
    entry := jsonb_build_object('id', encode(extensions.gen_random_bytes(6), 'hex'), 's', p_student, 't', 'x', 'v', pts,
                                'g', encode(extensions.gen_random_bytes(6), 'hex'), 'note', left('ДЗ: ' || h.title, 80),
                                'd', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
    d := jsonb_set(d, '{log}', jsonb_build_array(entry) || (d->'log'));
  end if;
  -- задание «выучить суру»: сура засчитывается автоматически
  if h.sura is not null and not coalesce((st->'sur') ? h.sura, false) then
    st := jsonb_set(st, '{sur}', case when jsonb_typeof(st->'sur') = 'array' then st->'sur' else '[]'::jsonb end || to_jsonb(h.sura));
    entry := jsonb_build_object('id', encode(extensions.gen_random_bytes(6), 'hex'), 's', p_student, 't', 's', 'v', 1,
                                'g', encode(extensions.gen_random_bytes(6), 'hex'), 'note', h.sura,
                                'd', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
    d := jsonb_set(d, '{log}', jsonb_build_array(entry) || (d->'log'));
  end if;
  if st is distinct from g.data->'students'->idx then
    d := jsonb_set(d, array['students', idx::text], st);
    update groups set data = d, version = version + 1, updated_at = now(), updated_by = t.id where id = g.id returning version into ver;
  end if;
  perform _push(g.id, p_student, false, false, 'Задание принято ✅', h.title || case when pts > 0 then ' · +' || pts else '' end, '#/g/' || g.slug || '/hw');
  return json_build_object('ok', true, 'changed', true, 'points', pts, 'version', ver);
end $$;

-- ---------- файлы ----------
-- Шаг 1: получить место и пропуск на загрузку. Шаг 2: загрузить в Storage. Шаг 3: file_done.
create or replace function file_begin(p_slug text, p_homework uuid, p_name text, p_mime text, p_size bigint, p_token text default null, p_stoken text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; a jsonb; sid text; ext text; pth text; fid uuid; nm text := left(btrim(coalesce(p_name, '')), 120);
begin
  g := _g(p_slug); a := _actor(g, p_token, p_stoken); sid := a->>'s';
  if not exists (select 1 from homework where id = p_homework and group_id = g.id) then raise exception 'not_found'; end if;
  if nm = '' then nm := 'файл'; end if;
  if p_size is null or p_size <= 0 or p_size > 26214400 then raise exception 'file_too_large'; end if;
  delete from hw_files where not ready and created_at < now() - interval '1 day';
  if (select coalesce(sum(size), 0) from hw_files where group_id = g.id) + p_size > 419430400
     or (select coalesce(sum(size), 0) from hw_files) + p_size > 943718400 then raise exception 'quota'; end if;
  if sid is null then
    if (select count(*) from hw_files where homework_id = p_homework and student_id is null) >= 12 then raise exception 'too_many'; end if;
  else
    if exists (select 1 from submissions where homework_id = p_homework and student_id = sid and status = 'accepted') then raise exception 'accepted'; end if;
    if (select count(*) from hw_files where homework_id = p_homework and student_id = sid) >= 6 then raise exception 'too_many'; end if;
  end if;
  ext := lower(substring(nm from '\.([A-Za-z0-9]{1,8})$'));
  pth := g.id::text || '/' || encode(extensions.gen_random_bytes(16), 'hex') || coalesce('.' || ext, '');
  insert into hw_files(group_id, homework_id, student_id, path, name, mime, size)
  values (g.id, p_homework, sid, pth, nm, left(coalesce(p_mime, ''), 100), p_size) returning id into fid;
  perform _ticket(pth, 'w', 20);
  return json_build_object('id', fid, 'path', pth);
end $$;

-- Пропуск на чтение. Файл учителя — любому, кто знает код группы; ответ ученика — только ему и учителям группы.
create or replace function file_done(p_slug text, p_id uuid, p_token text default null, p_stoken text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; a jsonb; f hw_files;
begin
  g := _g(p_slug); a := _actor(g, p_token, p_stoken);
  select * into f from hw_files where id = p_id and group_id = g.id;
  if not found then raise exception 'not_found'; end if;
  if a->>'t' is not null then
    if f.student_id is not null and not f.by_teacher then raise exception 'not_found'; end if;
  elsif f.by_teacher or f.student_id is distinct from (a->>'s') then raise exception 'not_found';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'hw' and name = f.path) then raise exception 'no_upload'; end if;
  update hw_files set ready = true where id = f.id;
  delete from file_tickets where path = f.path and op = 'w';
  return json_build_object('ok', true);
end $$;

create or replace function file_get(p_slug text, p_id uuid, p_token text default null, p_stoken text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; a jsonb; f hw_files;
begin
  g := _g(p_slug);
  select * into f from hw_files where id = p_id and group_id = g.id and ready;
  if not found then raise exception 'not_found'; end if;
  if f.student_id is not null then
    a := _actor(g, p_token, p_stoken);
    if a->>'t' is null and (a->>'s') is distinct from f.student_id then raise exception 'forbidden'; end if;
  end if;
  perform _ticket(f.path, 'r', 15);
  return json_build_object('path', f.path, 'name', f.name, 'mime', f.mime, 'size', f.size);
end $$;

create or replace function file_delete(p_slug text, p_id uuid, p_token text default null, p_stoken text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; a jsonb; f hw_files;
begin
  g := _g(p_slug); a := _actor(g, p_token, p_stoken);
  select * into f from hw_files where id = p_id and group_id = g.id;
  if not found then raise exception 'not_found'; end if;
  if a->>'t' is null then
    if f.student_id is distinct from (a->>'s') then raise exception 'forbidden'; end if;
    if exists (select 1 from submissions where homework_id = f.homework_id and student_id = f.student_id and status = 'accepted') then raise exception 'accepted'; end if;
  end if;
  delete from hw_files where id = f.id;
  return json_build_object('ok', true);
end $$;

-- Уборка: файлы в хранилище, на которые больше нет записей (удалённые задания, прерванные загрузки).
-- Возвращает пути с пропусками на удаление — сайт удаляет их сам.
create or replace function hw_cleanup(p_token text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t teachers; r record; out_paths text[] := '{}';
begin
  t := _who(p_token);
  for r in select o.name from storage.objects o
            where o.bucket_id = 'hw' and o.created_at < now() - interval '1 hour'
              and not exists (select 1 from hw_files f where f.path = o.name)
            limit 40 loop
    perform _ticket(r.name, 'd', 15);
    out_paths := out_paths || r.name;
  end loop;
  return to_json(out_paths);
end $$;

revoke all on function _g(text), _swho(text), _actor(groups, text, text), _ticket(text, text, int), _files_json(uuid, text)
  from public, anon, authenticated;
revoke all on function hw_file_ok(text, text), student_pins(text, text, boolean, text), student_login(text, text, text), student_logout(text),
  hw_list(text, text, text), hw_save(text, text, uuid, text, text, date, int, text, int), hw_delete(text, text, uuid), hw_submit(text, text, uuid, text),
  hw_review(text, text, uuid, text, boolean, text, int), file_begin(text, uuid, text, text, bigint, text, text),
  file_done(text, uuid, text, text), file_get(text, uuid, text, text), file_delete(text, uuid, text, text), hw_cleanup(text)
  from public;
grant execute on function hw_file_ok(text, text), student_pins(text, text, boolean, text), student_login(text, text, text), student_logout(text),
  hw_list(text, text, text), hw_save(text, text, uuid, text, text, date, int, text, int), hw_delete(text, text, uuid), hw_submit(text, text, uuid, text),
  hw_review(text, text, uuid, text, boolean, text, int), file_begin(text, uuid, text, text, bigint, text, text),
  file_done(text, uuid, text, text), file_get(text, uuid, text, text), file_delete(text, uuid, text, text), hw_cleanup(text)
  to anon, authenticated;

-- ---------- свои фото-аватарки учеников ----------
create table if not exists student_avatars (
  group_id   uuid not null references groups(id) on delete cascade,
  student_id text not null,
  img        text not null,                        -- маленькая картинка (data:image/jpeg;base64,...)
  updated_at timestamptz not null default now(),
  primary key (group_id, student_id)
);
alter table student_avatars enable row level security;
revoke all on student_avatars from anon, authenticated;

create or replace function avatars_get(p_slug text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare g groups;
begin
  g := _g(p_slug);
  return coalesce((select json_object_agg(a.student_id, a.img) from student_avatars a where a.group_id = g.id), '{}'::json);
end $$;

-- Аватарку меняет сам ученик (вошёл по PIN) или учитель группы.
-- p_img — своё фото; p_av — готовая аватарка (фото при этом убирается); оба пустые — просто убрать фото.
create or replace function avatar_set(p_slug text, p_student text, p_av text default null, p_img text default null, p_token text default null, p_stoken text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; a jsonb; idx int; ver int;
begin
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, ''))) for update;
  if not found then raise exception 'not_found'; end if;
  a := _actor(g, p_token, p_stoken);
  if a->>'t' is null and (a->>'s') is distinct from p_student then raise exception 'forbidden'; end if;
  if not _student_ok(g, p_student) then raise exception 'no_student'; end if;
  ver := g.version;
  if p_img is not null then
    if length(p_img) > 60000 or p_img !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$' then raise exception 'bad_image'; end if;
    insert into student_avatars(group_id, student_id, img) values (g.id, p_student, p_img)
    on conflict (group_id, student_id) do update set img = excluded.img, updated_at = now();
    update groups set version = version + 1 where id = g.id returning version into ver;   -- чтобы у всех обновилась картинка
  else
    delete from student_avatars where group_id = g.id and student_id = p_student;
    if found and p_av is null then
      update groups set version = version + 1 where id = g.id returning version into ver;
    end if;
    if p_av is not null then
      if p_av !~ '^[bgn]-[a-z]{2,12}$' then raise exception 'bad_input'; end if;
      select (e.ord - 1)::int into idx from jsonb_array_elements(g.data->'students') with ordinality as e(v, ord) where e.v->>'id' = p_student limit 1;
      update groups set data = jsonb_set(g.data, array['students', idx::text, 'av'], to_jsonb(p_av)), version = version + 1, updated_at = now()
       where id = g.id returning version into ver;
    end if;
  end if;
  return json_build_object('ok', true, 'version', ver);
end $$;

revoke all on function avatars_get(text), avatar_set(text, text, text, text, text, text) from public;
grant execute on function avatars_get(text), avatar_set(text, text, text, text, text, text) to anon, authenticated;

-- =====================================================================
--  СООБЩЕНИЯ (ЧАТ УЧЕНИКА С УЧИТЕЛЕМ: ГОЛОСОВЫЕ, ЧТЕНИЕ СУР) И ПУШ-УВЕДОМЛЕНИЯ
-- =====================================================================
alter table hw_files alter column homework_id drop not null;
alter table hw_files add column if not exists by_teacher boolean not null default false;

create table if not exists messages (
  id         uuid primary key default gen_random_uuid(),
  group_id   uuid not null references groups(id) on delete cascade,
  student_id text not null,                          -- чей это чат
  by_teacher boolean not null default false,
  teacher_id uuid references teachers(id) on delete set null,
  body       text not null default '',
  file_id    uuid references hw_files(id) on delete set null,
  dur        int,                                    -- длина голосового, секунд
  sura       text,                                   -- какую суру читает (необязательно)
  created_at timestamptz not null default now()
);
create index if not exists messages_thread_idx on messages(group_id, student_id, created_at);
create table if not exists msg_reads (                -- до какого времени прочитано: side = 's' ученик, 't' учителя
  group_id   uuid not null references groups(id) on delete cascade,
  student_id text not null,
  side       text not null,
  at         timestamptz not null,
  primary key (group_id, student_id, side)
);
create table if not exists push_config (
  id           int primary key default 1 check (id = 1),
  vapid_public text not null,
  secret_hash  text not null,
  updated_at   timestamptz not null default now()
);
create table if not exists push_subs (
  endpoint   text primary key,
  p256dh     text not null,
  auth       text not null,
  group_id   uuid references groups(id) on delete cascade,
  student_id text,
  teacher_id uuid references teachers(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists push_queue (
  id          bigserial primary key,
  group_id    uuid references groups(id) on delete cascade,
  student_id  text,
  to_teachers boolean not null default false,
  to_group    boolean not null default false,
  title       text not null,
  body        text not null default '',
  url         text not null default './',
  created_at  timestamptz not null default now()
);
alter table push_queue add column if not exists teacher_id uuid references teachers(id) on delete cascade;   -- лично учителю (проверка)
alter table messages    enable row level security;
alter table msg_reads   enable row level security;
alter table push_config enable row level security;
alter table push_subs   enable row level security;
alter table push_queue  enable row level security;
revoke all on messages, msg_reads, push_config, push_subs, push_queue from anon, authenticated;
revoke all on sequence push_queue_id_seq from anon, authenticated;

create or replace function _sname(g groups, p_student text) returns text
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select e->>'name' from jsonb_array_elements(g.data->'students') e where e->>'id' = p_student limit 1), 'Ученик')
$$;

create or replace function _push(p_group uuid, p_student text, p_teachers boolean, p_all boolean, p_title text, p_body text, p_url text) returns void
language plpgsql volatile security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from push_config) then return; end if;
  insert into push_queue(group_id, student_id, to_teachers, to_group, title, body, url)
  values (p_group, p_student, p_teachers, p_all, left(p_title, 80), left(coalesce(p_body, ''), 160), coalesce(p_url, './'));
end $$;

create or replace function _msg_unread(p_group uuid, p_student text, p_side text) returns int
language sql stable security definer set search_path = public, extensions as $$
  select count(*)::int from messages m
   where m.group_id = p_group and (p_student is null or m.student_id = p_student)
     and m.by_teacher = (p_side = 's')
     and m.created_at > coalesce((select r.at from msg_reads r where r.group_id = m.group_id and r.student_id = m.student_id and r.side = p_side), '-infinity')
$$;

-- ---------- файлы для сообщений ----------
create or replace function msg_file_begin(p_slug text, p_student text, p_name text, p_mime text, p_size bigint, p_token text default null, p_stoken text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; a jsonb; ext text; pth text; fid uuid; nm text := left(btrim(coalesce(p_name, '')), 120);
begin
  g := _g(p_slug); a := _actor(g, p_token, p_stoken);
  if a->>'t' is null and (a->>'s') is distinct from p_student then raise exception 'forbidden'; end if;
  if not _student_ok(g, p_student) then raise exception 'no_student'; end if;
  if nm = '' then nm := 'файл'; end if;
  if p_size is null or p_size <= 0 or p_size > 26214400 then raise exception 'file_too_large'; end if;
  delete from hw_files where not ready and created_at < now() - interval '1 day';
  if (select coalesce(sum(size), 0) from hw_files where group_id = g.id) + p_size > 419430400
     or (select coalesce(sum(size), 0) from hw_files) + p_size > 943718400 then raise exception 'quota'; end if;
  ext := lower(substring(nm from '\.([A-Za-z0-9]{1,8})$'));
  pth := g.id::text || '/' || encode(extensions.gen_random_bytes(16), 'hex') || coalesce('.' || ext, '');
  insert into hw_files(group_id, homework_id, student_id, by_teacher, path, name, mime, size)
  values (g.id, null, p_student, a->>'t' is not null, pth, nm, left(coalesce(p_mime, ''), 100), p_size) returning id into fid;
  perform _ticket(pth, 'w', 20);
  return json_build_object('id', fid, 'path', pth);
end $$;


-- ---------- сообщения ----------
create or replace function _msg_json(m messages) returns json
language sql stable security definer set search_path = public, extensions as $$
  select json_build_object('id', m.id, 'by_teacher', m.by_teacher, 'body', m.body, 'dur', m.dur, 'sura', m.sura, 'created_at', m.created_at,
    'teacher', (select t.name from teachers t where t.id = m.teacher_id),
    'file', (select json_build_object('id', f.id, 'name', f.name, 'mime', f.mime, 'size', f.size) from hw_files f where f.id = m.file_id and f.ready))
$$;

create or replace function msg_send(p_slug text, p_student text, p_body text, p_file uuid default null, p_dur int default null, p_sura text default null,
                                    p_token text default null, p_stoken text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; a jsonb; byt boolean; m messages; bd text := left(btrim(coalesce(p_body, '')), 2000);
        sr text := nullif(left(btrim(coalesce(p_sura, '')), 60), ''); nm text; what text;
begin
  g := _g(p_slug); a := _actor(g, p_token, p_stoken); byt := a->>'t' is not null;
  if not byt and (a->>'s') is distinct from p_student then raise exception 'forbidden'; end if;
  if not _student_ok(g, p_student) then raise exception 'no_student'; end if;
  if p_file is not null and not exists (select 1 from hw_files where id = p_file and group_id = g.id and student_id = p_student
                                         and by_teacher = byt and homework_id is null and ready) then raise exception 'not_found'; end if;
  if bd = '' and p_file is null then raise exception 'empty'; end if;
  if not byt and (select count(*) from messages where group_id = g.id and student_id = p_student and not by_teacher
                   and created_at > now() - interval '1 minute') >= 15 then raise exception 'slow'; end if;
  insert into messages(group_id, student_id, by_teacher, teacher_id, body, file_id, dur, sura)
  values (g.id, p_student, byt, (a->>'t')::uuid, bd, p_file, case when p_file is null or p_dur is null then null else greatest(0, least(3600, p_dur)) end, sr) returning * into m;
  insert into msg_reads(group_id, student_id, side, at) values (g.id, p_student, case when byt then 't' else 's' end, m.created_at)
  on conflict (group_id, student_id, side) do update set at = greatest(msg_reads.at, excluded.at);
  nm := _sname(g, p_student);
  what := case when p_file is not null and m.dur is not null then '🎙 Голосовое' || coalesce(' · ' || sr, '')
               when p_file is not null then '📎 Файл' else left(bd, 120) end;
  if byt then
    perform _push(g.id, p_student, false, false, 'Сообщение от учителя', what, '#/g/' || g.slug || '/chat');
  else
    perform _push(g.id, null, true, false, nm || ' · ' || g.name, what, '#/g/' || g.slug || '/chat/' || p_student);
  end if;
  return _msg_json(m);
end $$;

-- Сообщения одного чата. p_after — только новее этого времени. Отмечает чат прочитанным.
create or replace function msg_list(p_slug text, p_student text, p_after timestamptz default null, p_token text default null, p_stoken text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; a jsonb; v_side text; v_other text; items json;
begin
  g := _g(p_slug); a := _actor(g, p_token, p_stoken);
  if a->>'t' is null and (a->>'s') is distinct from p_student then raise exception 'forbidden'; end if;
  v_side := case when a->>'t' is not null then 't' else 's' end;
  v_other := case when v_side = 't' then 's' else 't' end;
  select coalesce(json_agg(_msg_json(x) order by x.created_at), '[]'::json) into items from (
    select * from messages where group_id = g.id and student_id = p_student and (p_after is null or created_at > p_after)
     order by created_at desc limit 150) x;
  insert into msg_reads(group_id, student_id, side, at) values (g.id, p_student, v_side, now())
  on conflict (group_id, student_id, side) do update set at = excluded.at;
  return json_build_object('items', items,
    'other_read', (select at from msg_reads where group_id = g.id and student_id = p_student and side = v_other));
end $$;

-- Учитель: список чатов группы.
create or replace function msg_threads(p_token text, p_slug text) returns json
language plpgsql stable security definer set search_path = public, extensions as $$
declare t teachers; g groups;
begin
  t := _who(p_token); g := _g(p_slug);
  if not _can(t, g.id) then raise exception 'forbidden'; end if;
  return coalesce((select json_agg(x order by x.last_at desc) from (
    select m.student_id, max(m.created_at) as last_at, _msg_unread(g.id, m.student_id, 't') as unread,
           (select json_build_object('by_teacher', l.by_teacher, 'body', left(l.body, 80), 'voice', l.dur is not null, 'file', l.file_id is not null, 'sura', l.sura)
              from messages l where l.group_id = g.id and l.student_id = m.student_id order by l.created_at desc limit 1) as last
      from messages m where m.group_id = g.id group by m.student_id) x), '[]'::json);
end $$;

-- ---------- пуш-уведомления ----------
create or replace function push_info() returns json
language sql stable security definer set search_path = public, extensions as $$
  select json_build_object('vapid', (select vapid_public from push_config))
$$;

-- Админ сохраняет ключи (создаются в браузере). Старые подписки после смены ключей недействительны.
create or replace function push_setup(p_token text, p_public text, p_secret text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t teachers;
begin
  t := _who(p_token);
  if not t.is_admin then raise exception 'forbidden'; end if;
  if coalesce(p_public, '') !~ '^[A-Za-z0-9_-]{80,100}$' or length(coalesce(p_secret, '')) < 32 then raise exception 'bad_input'; end if;
  insert into push_config(id, vapid_public, secret_hash) values (1, p_public, _hash(p_secret))
  on conflict (id) do update set vapid_public = excluded.vapid_public, secret_hash = excluded.secret_hash, updated_at = now();
  delete from push_subs where true; delete from push_queue where true;   -- Supabase требует WHERE у DELETE
  return json_build_object('ok', true);
end $$;

create or replace function push_subscribe(p_slug text, p_endpoint text, p_p256dh text, p_auth text, p_token text default null, p_stoken text default null) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; a jsonb := '{}'::jsonb;
begin
  if coalesce(p_endpoint, '') !~ '^https://' or length(p_endpoint) > 1000 or length(coalesce(p_p256dh, '')) not between 40 and 200
     or length(coalesce(p_auth, '')) not between 8 and 100 then raise exception 'bad_input'; end if;
  g := _g(p_slug);
  if coalesce(p_token, '') <> '' or coalesce(p_stoken, '') <> '' then a := _actor(g, p_token, p_stoken); end if;
  delete from push_subs where endpoint = p_endpoint;
  if (select count(*) from push_subs where group_id = g.id) > 2000 then raise exception 'quota'; end if;
  insert into push_subs(endpoint, p256dh, auth, group_id, student_id, teacher_id)
  values (p_endpoint, p_p256dh, p_auth, case when a->>'t' is null then g.id end, a->>'s', (a->>'t')::uuid);
  return json_build_object('ok', true, 'as', case when a->>'t' is not null then 'teacher' when a->>'s' is not null then 'student' else 'guest' end);
end $$;

create or replace function push_unsubscribe(p_endpoint text) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from push_subs where endpoint = p_endpoint;
  return json_build_object('ok', true);
end $$;

-- Вызывает функция Supabase «push» (Edge Function): забирает очередь уведомлений вместе с адресатами.
create or replace function push_take(p_secret text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare out_ json; ids bigint[];
begin
  if not exists (select 1 from push_config where secret_hash = _hash(coalesce(p_secret, ''))) then raise exception 'forbidden'; end if;
  delete from push_queue where created_at < now() - interval '1 day';
  select array_agg(id) into ids from (select id from push_queue order by id limit 200) q;
  if ids is null then return '[]'::json; end if;
  select coalesce(json_agg(json_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth,
           'payload', json_build_object('title', q.title, 'body', q.body, 'url', q.url, 'tag', 'h' || q.id))), '[]'::json) into out_
    from push_queue q
    join push_subs s on
         (q.to_group and s.group_id = q.group_id)
      or (q.student_id is not null and not q.to_group and s.group_id = q.group_id and s.student_id = q.student_id)
      or (q.teacher_id is not null and s.teacher_id = q.teacher_id)
      or (q.to_teachers and s.teacher_id is not null and (
            s.teacher_id in (select tg.teacher_id from teacher_groups tg where tg.group_id = q.group_id)
            or s.teacher_id in (select id from teachers where is_admin)))
   where q.id = any(ids);
  delete from push_queue where id = any(ids);
  return out_;
end $$;

-- Учитель: пробное уведомление себе.
create or replace function push_test(p_token text, p_slug text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare t teachers; g groups;
begin
  t := _who(p_token); g := _g(p_slug);
  if not _can(t, g.id) then raise exception 'forbidden'; end if;
  if not exists (select 1 from push_config) then raise exception 'no_push'; end if;
  insert into push_queue(group_id, teacher_id, title, body, url)
  values (g.id, t.id, 'Проверка уведомлений 🔔', 'Ассаляму алейкум! Уведомления работают.', '#/g/' || g.slug || '/hw');
  return json_build_object('ok', true);
end $$;

create or replace function push_gone(p_secret text, p_endpoints text[]) returns json
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from push_config where secret_hash = _hash(coalesce(p_secret, ''))) then raise exception 'forbidden'; end if;
  delete from push_subs where endpoint = any(p_endpoints);
  return json_build_object('ok', true);
end $$;

revoke all on function _sname(groups, text), _push(uuid, text, boolean, boolean, text, text, text), _msg_unread(uuid, text, text), _msg_json(messages)
  from public, anon, authenticated;
revoke all on function msg_file_begin(text, text, text, text, bigint, text, text), msg_send(text, text, text, uuid, int, text, text, text),
  msg_list(text, text, timestamptz, text, text), msg_threads(text, text), push_info(), push_setup(text, text, text),
  push_subscribe(text, text, text, text, text, text), push_unsubscribe(text), push_take(text), push_gone(text, text[]), push_test(text, text) from public;
grant execute on function msg_file_begin(text, text, text, text, bigint, text, text), msg_send(text, text, text, uuid, int, text, text, text),
  msg_list(text, text, timestamptz, text, text), msg_threads(text, text), push_info(), push_setup(text, text, text),
  push_subscribe(text, text, text, text, text, text), push_unsubscribe(text), push_take(text), push_gone(text, text[]), push_test(text, text) to anon, authenticated;

update messages set dur = null where file_id is null and dur is not null;   -- исправление: у текстовых сообщений нет длины

-- ---------- прослушивания сур в плеере ----------
-- Каждое полное прослушивание суры учеником (от первого до последнего аята, без перемотки) — одна строка.
-- Сервер не засчитывает прослушивание, если с прошлого прошло меньше времени, чем длится сура:
-- так счётчик нельзя «накрутить» — запись нужно действительно проиграть до конца.
create table if not exists listens (
  id         bigserial primary key,
  group_id   uuid not null references groups(id) on delete cascade,
  student_id text not null,
  sura       text not null,
  at         timestamptz not null default now()
);
create index if not exists listens_idx on listens(group_id, student_id, sura, at);
create table if not exists sura_secs (sura text primary key, secs int not null);   -- длительность записи с басмалой, секунд (обычное чтение аль-Хусари, audio/hm)
alter table listens enable row level security;
alter table sura_secs enable row level security;
revoke all on listens, sura_secs from anon, authenticated;
revoke all on sequence listens_id_seq from anon, authenticated;
insert into sura_secs(sura, secs) values
  ('Аль-Фатиха', 47),
  ('Ан-Наба', 398),
  ('Ан-Назиат', 396),
  ('Абаса', 278),
  ('Ат-Таквир', 212),
  ('Аль-Инфитар', 175),
  ('Аль-Мутаффифин', 401),
  ('Аль-Иншикак', 227),
  ('Аль-Бурудж', 233),
  ('Ат-Тарик', 131),
  ('Аль-Аля', 155),
  ('Аль-Гашия', 214),
  ('Аль-Фаджр', 319),
  ('Аль-Балад', 177),
  ('Аш-Шамс', 121),
  ('Аль-Лейль', 160),
  ('Ад-Духа', 87),
  ('Аш-Шарх', 56),
  ('Ат-Тин', 78),
  ('Аль-Алак', 149),
  ('Аль-Кадр', 60),
  ('Аль-Баййина', 180),
  ('Аз-Зальзаля', 82),
  ('Аль-Адият', 87),
  ('Аль-Кариа', 83),
  ('Ат-Такасур', 68),
  ('Аль-Аср', 34),
  ('Аль-Хумаза', 72),
  ('Аль-Филь', 51),
  ('Курайш', 45),
  ('Аль-Маун', 61),
  ('Аль-Кяусар', 27),
  ('Аль-Кафирун', 59),
  ('Ан-Наср', 43),
  ('Аль-Масад', 48),
  ('Аль-Ихлас', 30),
  ('Аль-Фалак', 41),
  ('Ан-Нас', 51),
  ('Аят аль-Курси', 60)
on conflict (sura) do update set secs = excluded.secs;

create or replace function listen_add(p_slug text, p_stoken text, p_sura text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; a jsonb; sid text; sec int; last timestamptz; n int;
begin
  g := _g(p_slug); a := _actor(g, null, p_stoken); sid := a->>'s';
  if sid is null then raise exception 'sauth'; end if;
  select secs into sec from sura_secs where sura = p_sura;
  if sec is null then raise exception 'not_found'; end if;
  perform pg_advisory_xact_lock(hashtext(g.id::text || sid));
  select max(at) into last from listens where group_id = g.id and student_id = sid;
  if last is not null and now() - last < make_interval(secs => greatest(3, floor(sec * 0.9)::int)) then
    return json_build_object('ok', false, 'why', 'too_fast');
  end if;
  if (select count(*) from listens where group_id = g.id and student_id = sid and at > now() - interval '1 day') >= 300 then
    return json_build_object('ok', false, 'why', 'limit');
  end if;
  insert into listens(group_id, student_id, sura) values (g.id, sid, p_sura);
  select count(*) into n from listens where group_id = g.id and student_id = sid and sura = p_sura;
  return json_build_object('ok', true, 'total', n);
end $$;
revoke all on function listen_add(text, text, text) from public;
grant execute on function listen_add(text, text, text) to anon, authenticated;

-- ---------- хранилище файлов (Supabase Storage) ----------
-- Закрытая «папка» hw: до 25 МБ на файл. Загрузить, прочитать или удалить файл можно
-- только с временным пропуском, который выдают функции выше.
insert into storage.buckets (id, name, public, file_size_limit)
values ('hw', 'hw', false, 26214400)
on conflict (id) do update set public = false, file_size_limit = 26214400;

drop policy if exists "hw read"   on storage.objects;
drop policy if exists "hw upload" on storage.objects;
drop policy if exists "hw delete" on storage.objects;
create policy "hw read"   on storage.objects for select to anon, authenticated
  using (bucket_id = 'hw' and public.hw_file_ok(name, 'any'));
create policy "hw upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'hw' and public.hw_file_ok(name, 'w'));
create policy "hw delete" on storage.objects for delete to anon, authenticated
  using (bucket_id = 'hw' and public.hw_file_ok(name, 'd'));


notify pgrst, 'reload schema';
