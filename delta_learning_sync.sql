-- Каждое завершение урока принимается только один раз.
create table if not exists public.lesson_receipts (
  group_id uuid not null references public.groups(id) on delete cascade,
  student_id text not null,
  completion_id uuid not null,
  result jsonb not null,
  accepted_at timestamptz not null default now(),
  primary key (group_id, student_id, completion_id)
);
alter table public.lesson_receipts enable row level security;
revoke all on public.lesson_receipts from public, anon, authenticated;

create or replace function public.lesson_done_once(
  p_slug text, p_stoken text, p_completion uuid, p_course text, p_lesson text,
  p_title text, p_stars integer, p_correct integer, p_total integer
) returns json
language plpgsql security definer set search_path = '' as $$
declare
  s public.student_sessions;
  saved jsonb;
begin
  s := public._wauth(p_slug, p_stoken);
  if p_completion is null then raise exception 'bad_input'; end if;
  -- Тот же порядок блокировок, что у lesson_done и параллельных обработчиков.
  perform 1 from public.groups where id = s.group_id for update;
  if not found then raise exception 'not_found'; end if;
  select r.result into saved from public.lesson_receipts r
    where (r.group_id,r.student_id,r.completion_id)=(s.group_id,s.student_id,p_completion);
  if found then
    return (saved || jsonb_build_object('replayed', true))::json;
  end if;
  saved := public.lesson_done(p_slug,p_stoken,p_course,p_lesson,p_title,p_stars,p_correct,p_total)::jsonb;
  insert into public.lesson_receipts(group_id,student_id,completion_id,result)
  values (s.group_id,s.student_id,p_completion,
          case when jsonb_typeof(saved->'reward')='object' then saved #- '{reward,wallet}' else saved end);
  return saved::json;
end $$;

create or replace function public.progress_get(
  p_code text, p_student text, p_token text default null, p_stoken text default null, p_ptoken text default null
) returns json
language plpgsql stable security definer set search_path = '' as $$
declare g public.groups; v jsonb;
begin
  g := public._g(p_code);
  v := public._viewer(g, p_token, p_stoken, p_ptoken);
  if v is null or (not (v ? 't') and coalesce(v->>'s',v->>'p') is distinct from p_student) then
    return '[]'::json;
  end if;
  return coalesce((select json_agg(json_build_object('course',course,'lesson',lesson,'stars',stars,'best_stars',best_stars,
                  'correct',correct,'total',total,'attempts',attempts,'updated_at',updated_at) order by course,lesson)
                    from public.lesson_progress where group_id=g.id and student_id=p_student),'[]'::json);
end $$;

revoke all on function public.lesson_done_once(text,text,uuid,text,text,text,integer,integer,integer),
  public.progress_get(text,text,text,text,text) from public;
grant execute on function public.lesson_done_once(text,text,uuid,text,text,text,integer,integer,integer),
  public.progress_get(text,text,text,text,text) to anon, authenticated;
notify pgrst, 'reload schema';
