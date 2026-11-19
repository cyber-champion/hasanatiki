-- ---------- Лимиты времени считаются и на сервере: сколько уроков пройдено сегодня ----------
alter table student_activity add column if not exists lessons int not null default 0;

create or replace function _wallet_lesson(g uuid, sid text, p_stars int, p_correct int, p_old int) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare w wallets; gain int; pr int := 0; ch int := 0; td date := _today(); room int; note text := '';
begin
  w := _wallet(g, sid);
  insert into student_activity as a (group_id, student_id, day, lessons) values (g, sid, _today(), 1)
    on conflict (group_id, student_id, day) do update set lessons = a.lessons + 1;
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

create or replace function wallet_get(p_slug text, p_stoken text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare s student_sessions; w wallets; t json;
begin
  s := _wauth(p_slug, p_stoken); w := _wallet(s.group_id, s.student_id);
  select json_build_object('l', coalesce(lessons, 0), 's', coalesce(secs, 0)) into t from student_activity
   where group_id = s.group_id and student_id = s.student_id and day = _today();
  return (_wjson(w)::jsonb || jsonb_build_object('plim', _plim(s.group_id, s.student_id), 'today', coalesce(t, '{"l":0,"s":0}'::json)))::json;
end $$;
notify pgrst, 'reload schema';
