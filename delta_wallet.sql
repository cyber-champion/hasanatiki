-- ---------- Оазис: финики 🌴, жемчужины 💎, сундуки, наряды Сабура, шатёр, мечеть ----------
create table if not exists wallets (
  group_id   uuid not null references groups(id) on delete cascade,
  student_id text not null,
  dates      int  not null default 0,          -- финики
  pearls     int  not null default 0,          -- жемчужины
  chests     int  not null default 0,          -- неоткрытые сундуки
  lessons    int  not null default 0,          -- пройдено уроков (каждые 3 — сундук)
  streak     int  not null default 0,          -- дней подряд
  last_day   date,
  day        date,
  day_dates  int  not null default 0,          -- финики за сегодня (не больше 80)
  earned     int  not null default 0,          -- всего заработано фиников (для рейтинга)
  items      jsonb not null default '[]',      -- купленные вещи
  equip      jsonb not null default '{}',      -- что надето: hat / sc / bl
  mosque     int  not null default 0,          -- построено частей мечети (0..7)
  offer      jsonb,                            -- 3 подарка в открытом сундуке
  updated_at timestamptz not null default now(),
  primary key (group_id, student_id)
);
alter table wallets enable row level security;
revoke all on wallets from anon, authenticated;

create table if not exists wallet_log (
  id         bigserial primary key,
  group_id   uuid not null references groups(id) on delete cascade,
  student_id text not null,
  kind       text not null,
  dates      int not null default 0,
  pearls     int not null default 0,
  note       text,
  created_at timestamptz not null default now()
);
create index if not exists wallet_log_gs on wallet_log(group_id, student_id, created_at desc);
alter table wallet_log enable row level security;
revoke all on wallet_log from anon, authenticated;

-- Каталог: слот, валюта, цена
create or replace function _shop(p text) returns table(slot text, cur text, price int)
language sql immutable as $$
  select x.slot, x.cur, x.price from (values
    ('h_tub','hat','d',40),('h_tub2','hat','d',50),('h_kuf','hat','d',70),('h_gold','hat','p',2),
    ('sc_red','sc','d',25),('sc_grn','sc','d',25),('sc_str','sc','d',45),
    ('bl_tur','bl','d',50),('bl_blu','bl','d',70),('bl_grn','bl','d',70),('bl_gold','bl','p',3),
    ('t_rug','tent','d',40),('t_pil','tent','d',25),('t_lamp','tent','d',30),('t_shelf','tent','d',60),
    ('t_rehal','tent','d',50),('t_palm','tent','d',45),('t_jug','tent','d',20),('t_fanus','tent','p',2)
  ) as x(id, slot, cur, price) where x.id = p
$$;

create or replace function _wallet(g uuid, sid text) returns wallets
language plpgsql security definer set search_path = public, extensions as $$
declare w wallets;
begin
  insert into wallets (group_id, student_id) values (g, sid) on conflict do nothing;
  select * into w from wallets where group_id = g and student_id = sid for update;
  return w;
end $$;

create or replace function _wjson(w wallets) returns json language sql stable as $$
  select json_build_object('dates', w.dates, 'pearls', w.pearls, 'chests', w.chests, 'lessons', w.lessons,
    'streak', case when w.last_day >= _today() - 1 then w.streak else 0 end, 'earned', w.earned,
    'items', w.items, 'equip', w.equip, 'mosque', w.mosque, 'offer', w.offer)
$$;

-- Начисление за урок (вызывается из lesson_done)
create or replace function _wallet_lesson(g uuid, sid text, p_stars int, p_correct int, p_old int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare w wallets; gain int; pr int := 0; ch int := 0; td date := _today(); room int; note text := '';
begin
  w := _wallet(g, sid);
  if w.day is distinct from td then w.day := td; w.day_dates := 0; end if;
  gain := greatest(0, coalesce(p_correct, 0)) + greatest(0, p_stars) * 2;
  room := greatest(0, 80 - w.day_dates);
  gain := least(gain, room);
  -- серия дней
  if w.last_day is null or w.last_day < td - 1 then w.streak := 1;
  elsif w.last_day = td - 1 then w.streak := w.streak + 1;
    if w.streak % 3 = 0 then pr := pr + 1; note := 'серия ' || w.streak || ' дн.'; end if;
  end if;
  w.last_day := td;
  if p_stars >= 1 then
    w.lessons := w.lessons + 1;
    if w.lessons % 3 = 0 then ch := 1; end if;
    if w.lessons % 5 = 0 then pr := pr + 1; end if;
  end if;
  update wallets set dates = dates + gain, pearls = pearls + pr, chests = chests + ch, lessons = w.lessons,
         streak = w.streak, last_day = w.last_day, day = w.day, day_dates = w.day_dates + gain,
         earned = earned + gain, updated_at = now()
   where group_id = g and student_id = sid returning * into w;
  if gain > 0 or pr > 0 then
    insert into wallet_log (group_id, student_id, kind, dates, pearls, note) values (g, sid, 'lesson', gain, pr, nullif(note, ''));
  end if;
  return json_build_object('dates', gain, 'pearls', pr, 'chest', ch, 'wallet', _wjson(w));
end $$;

-- Урок пройден: прежняя логика + финики
create or replace function lesson_done(p_slug text, p_stoken text, p_course text, p_lesson text, p_title text, p_stars int, p_correct int, p_total int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; s student_sessions; old int; gain int; used int; idx int; st jsonb; d jsonb; entry jsonb; ver int; wl json;
begin
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, ''))) for update;
  if not found then raise exception 'not_found'; end if;
  s := _swho(p_stoken); if s.group_id <> g.id or not _student_ok(g, s.student_id) then raise exception 'sauth'; end if;
  if coalesce(p_course, '') !~ '^[a-z0-9_-]{1,32}$' or coalesce(p_lesson, '') !~ '^[a-z0-9_-]{1,32}$' then raise exception 'bad_input'; end if;
  if p_stars is null or p_stars < 0 or p_stars > 3 then raise exception 'bad_input'; end if;
  if p_correct is not null and (p_correct < 0 or p_correct > 40) then raise exception 'bad_input'; end if;
  select best_stars into old from lesson_progress where group_id = g.id and student_id = s.student_id and course = p_course and lesson = p_lesson;
  old := coalesce(old, 0);
  insert into lesson_progress as lp (group_id, student_id, course, lesson, stars, best_stars, correct, total, attempts)
       values (g.id, s.student_id, p_course, p_lesson, p_stars, p_stars, greatest(coalesce(p_correct, 0), 0), greatest(coalesce(p_total, 0), 0), 1)
  on conflict (group_id, student_id, course, lesson) do update
       set stars = excluded.stars, best_stars = greatest(lp.best_stars, excluded.stars),
           correct = excluded.correct, total = excluded.total, attempts = lp.attempts + 1, updated_at = now();
  gain := greatest(0, p_stars - old);
  select coalesce(lpts, 0) into used from student_activity where group_id = g.id and student_id = s.student_id and day = _today();
  gain := least(gain, greatest(0, 30 - coalesce(used, 0)));
  ver := g.version;
  if gain > 0 then
    insert into student_activity as a (group_id, student_id, day, lpts) values (g.id, s.student_id, _today(), gain)
    on conflict (group_id, student_id, day) do update set lpts = a.lpts + gain;
    select (e.ord - 1)::int into idx from jsonb_array_elements(g.data->'students') with ordinality as e(v, ord) where e.v->>'id' = s.student_id limit 1;
    st := g.data->'students'->idx; d := g.data;
    if d->'log' is null or jsonb_typeof(d->'log') <> 'array' then d := jsonb_set(d, '{log}', '[]'::jsonb); end if;
    st := st || jsonb_build_object('x', coalesce((st->>'x')::numeric, 0)::int + gain, 'xp', coalesce((st->>'xp')::numeric, 0)::int + gain);
    entry := jsonb_build_object('id', encode(extensions.gen_random_bytes(6), 'hex'), 's', s.student_id, 't', 'x', 'v', gain,
                                'g', encode(extensions.gen_random_bytes(6), 'hex'), 'note', left('🎓 ' || coalesce(nullif(btrim(p_title), ''), 'Урок'), 80),
                                'd', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
    d := jsonb_set(jsonb_set(d, '{log}', jsonb_build_array(entry) || (d->'log')), array['students', idx::text], st);
    update groups set data = d, version = version + 1, updated_at = now() where id = g.id returning version into ver;
  end if;
  wl := _wallet_lesson(g.id, s.student_id, p_stars, p_correct, old);
  return json_build_object('ok', true, 'points', gain, 'version', ver, 'reward', wl);
end $$;

create or replace function _wauth(p_slug text, p_stoken text) returns student_sessions
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; s student_sessions;
begin
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, '')));
  if not found then raise exception 'not_found'; end if;
  s := _swho(p_stoken); if s.group_id <> g.id or not _student_ok(g, s.student_id) then raise exception 'sauth'; end if;
  return s;
end $$;

create or replace function wallet_get(p_slug text, p_stoken text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s student_sessions; w wallets;
begin
  s := _wauth(p_slug, p_stoken); w := _wallet(s.group_id, s.student_id);
  return _wjson(w);
end $$;

-- Открыть сундук: сервер выбирает 3 подарка
create or replace function chest_open(p_slug text, p_stoken text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s student_sessions; w wallets; o jsonb := '[]'; it text; pool text[];
begin
  s := _wauth(p_slug, p_stoken); w := _wallet(s.group_id, s.student_id);
  if w.offer is not null then return _wjson(w); end if;
  if w.chests < 1 then raise exception 'no_chest'; end if;
  o := o || jsonb_build_object('k', 'd', 'n', 10 + floor(random() * 3)::int * 5);
  o := o || case when random() < 0.5 then jsonb_build_object('k', 'p', 'n', 1) else jsonb_build_object('k', 'd', 'n', 30) end;
  select array_agg(x) into pool from unnest(array['h_tub','h_tub2','sc_red','sc_grn','sc_str','bl_tur','t_rug','t_pil','t_lamp','t_jug','t_palm','t_rehal']) x
   where not (w.items ? x);
  if pool is not null and array_length(pool, 1) > 0 then
    it := pool[1 + floor(random() * array_length(pool, 1))::int];
    o := o || jsonb_build_object('k', 'i', 'id', it);
  else o := o || jsonb_build_object('k', 'd', 'n', 40); end if;
  update wallets set chests = chests - 1, offer = o, updated_at = now() where group_id = s.group_id and student_id = s.student_id returning * into w;
  return _wjson(w);
end $$;

create or replace function chest_pick(p_slug text, p_stoken text, p_idx int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s student_sessions; w wallets; x jsonb;
begin
  s := _wauth(p_slug, p_stoken); w := _wallet(s.group_id, s.student_id);
  if w.offer is null then raise exception 'no_offer'; end if;
  if p_idx is null or p_idx < 0 or p_idx > 2 then raise exception 'bad_input'; end if;
  x := w.offer->p_idx;
  if x->>'k' = 'd' then update wallets set dates = dates + (x->>'n')::int, earned = earned + (x->>'n')::int where group_id = s.group_id and student_id = s.student_id;
  elsif x->>'k' = 'p' then update wallets set pearls = pearls + (x->>'n')::int where group_id = s.group_id and student_id = s.student_id;
  elsif x->>'k' = 'i' and not (w.items ? (x->>'id')) then update wallets set items = items || jsonb_build_array(x->>'id') where group_id = s.group_id and student_id = s.student_id;
  end if;
  update wallets set offer = null, updated_at = now() where group_id = s.group_id and student_id = s.student_id returning * into w;
  insert into wallet_log (group_id, student_id, kind, dates, pearls, note)
    values (s.group_id, s.student_id, 'chest', case when x->>'k' = 'd' then (x->>'n')::int else 0 end, case when x->>'k' = 'p' then (x->>'n')::int else 0 end, x->>'id');
  return _wjson(w);
end $$;

create or replace function shop_buy(p_slug text, p_stoken text, p_item text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s student_sessions; w wallets; c record;
begin
  s := _wauth(p_slug, p_stoken); w := _wallet(s.group_id, s.student_id);
  select * into c from _shop(p_item);
  if not found then raise exception 'bad_item'; end if;
  if w.items ? p_item then raise exception 'owned'; end if;
  if c.cur = 'd' and w.dates < c.price or c.cur = 'p' and w.pearls < c.price then raise exception 'poor'; end if;
  update wallets set dates = dates - case when c.cur = 'd' then c.price else 0 end,
                     pearls = pearls - case when c.cur = 'p' then c.price else 0 end,
                     items = items || jsonb_build_array(p_item),
                     equip = case when c.slot in ('hat','sc','bl') then equip || jsonb_build_object(c.slot, p_item) else equip end,
                     updated_at = now()
   where group_id = s.group_id and student_id = s.student_id returning * into w;
  insert into wallet_log (group_id, student_id, kind, dates, pearls, note)
    values (s.group_id, s.student_id, 'buy', case when c.cur = 'd' then -c.price else 0 end, case when c.cur = 'p' then -c.price else 0 end, p_item);
  return _wjson(w);
end $$;

-- Надеть / снять (p_item пустой = снять, вернуть обычное)
create or replace function shop_equip(p_slug text, p_stoken text, p_slot text, p_item text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s student_sessions; w wallets; c record;
begin
  s := _wauth(p_slug, p_stoken); w := _wallet(s.group_id, s.student_id);
  if p_slot not in ('hat','sc','bl') then raise exception 'bad_input'; end if;
  if coalesce(p_item, '') = '' then
    update wallets set equip = equip - p_slot, updated_at = now() where group_id = s.group_id and student_id = s.student_id returning * into w;
  else
    select * into c from _shop(p_item);
    if not found or c.slot <> p_slot or not (w.items ? p_item) then raise exception 'bad_item'; end if;
    update wallets set equip = equip || jsonb_build_object(p_slot, p_item), updated_at = now() where group_id = s.group_id and student_id = s.student_id returning * into w;
  end if;
  return _wjson(w);
end $$;

-- Мечеть строится по частям
create or replace function mosque_build(p_slug text, p_stoken text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s student_sessions; w wallets; cd int[] := array[30,50,70,90,110,140,170]; cp int[] := array[0,0,0,0,1,1,2];
begin
  s := _wauth(p_slug, p_stoken); w := _wallet(s.group_id, s.student_id);
  if w.mosque >= 7 then raise exception 'done'; end if;
  if w.dates < cd[w.mosque + 1] or w.pearls < cp[w.mosque + 1] then raise exception 'poor'; end if;
  update wallets set dates = dates - cd[w.mosque + 1], pearls = pearls - cp[w.mosque + 1], mosque = mosque + 1, updated_at = now()
   where group_id = s.group_id and student_id = s.student_id returning * into w;
  insert into wallet_log (group_id, student_id, kind, dates, pearls, note)
    values (s.group_id, s.student_id, 'mosque', -cd[w.mosque], -cp[w.mosque], 'часть ' || w.mosque);
  return _wjson(w);
end $$;

-- Посмотреть оазис одноклассника (и для учителя/родителя): только наряд, шатёр, мечеть
create or replace function wallet_peek(p_slug text, p_token text, p_stoken text, p_ptoken text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare g groups; v jsonb;
begin
  select * into g from groups where slug = lower(btrim(coalesce(p_slug, '')));
  if not found then raise exception 'not_found'; end if;
  v := _viewer(g, p_token, p_stoken, p_ptoken);
  if v is null then raise exception 'auth'; end if;
  return coalesce((select json_object_agg(student_id, json_build_object('items', items, 'equip', equip, 'mosque', mosque, 'earned', earned,
                    'streak', case when last_day >= _today() - 1 then streak else 0 end))
                     from wallets where group_id = g.id), '{}'::json);
end $$;

revoke all on function _shop(text), _wallet(uuid, text), _wjson(wallets), _wallet_lesson(uuid, text, int, int, int), _wauth(text, text) from public, anon, authenticated;
revoke all on function wallet_get(text, text), chest_open(text, text), chest_pick(text, text, int), shop_buy(text, text, text),
  shop_equip(text, text, text, text), mosque_build(text, text), wallet_peek(text, text, text, text) from public;
grant execute on function wallet_get(text, text), chest_open(text, text), chest_pick(text, text, int), shop_buy(text, text, text),
  shop_equip(text, text, text, text), mosque_build(text, text), wallet_peek(text, text, text, text) to anon, authenticated;
notify pgrst, 'reload schema';
