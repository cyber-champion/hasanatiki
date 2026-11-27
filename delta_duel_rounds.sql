-- Банк вопросов и ответы доступны только серверным функциям.
create table if not exists public.duel_bank (
  course text not null, lesson integer not null, question jsonb not null, answer integer not null,
  primary key (course, lesson, question)
);
create table if not exists public.duel_rounds (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  player text not null, opponent text not null, course text not null, accepting boolean not null,
  invitation bigint references public.duels(id) on delete cascade,
  questions jsonb not null, started_at timestamptz not null default clock_timestamp(), result jsonb
);
create index if not exists duel_round_player_idx on public.duel_rounds(group_id,player,started_at desc);
create index if not exists duel_round_invite_idx on public.duel_rounds(invitation) where invitation is not null;
alter table public.duel_bank enable row level security;
alter table public.duel_rounds enable row level security;
revoke all on public.duel_bank, public.duel_rounds from public, anon, authenticated;

create or replace function public._duel_round_prompt(p_round public.duel_rounds) returns json
language sql stable set search_path = '' as $$
  select json_build_object('id',p_round.id,'course',p_round.course,'opp',p_round.opponent,'accepting',p_round.accepting,
    'elapsed_ms', greatest(0,floor(extract(epoch from (clock_timestamp()-p_round.started_at))*1000)::int),
    'qs',(select jsonb_agg(q - 'answer' order by i) from jsonb_array_elements(p_round.questions) with ordinality a(q,i)))
$$;

create or replace function public.duel_round_start(p_slug text,p_stoken text,p_opp text,p_course text,p_invite bigint)
returns json language plpgsql security definer set search_path = '' as $$
declare s public.student_sessions; g public.groups; d public.duels; r public.duel_rounds;
        cfg jsonb; qs jsonb; today text := public._today()::text; accepting boolean := p_invite is not null;
begin
  s := public._wauth(p_slug,p_stoken);
  select * into g from public.groups where id=s.group_id for update;
  if (g.data->'teen') is distinct from 'true'::jsonb then raise exception 'teen_only'; end if;
  if accepting then
    select * into d from public.duels where id=p_invite and group_id=g.id and b=s.student_id and b_score is null;
    if not found then raise exception 'not_found'; end if;
    p_opp := d.a; p_course := d.course;
  end if;
  if p_opp is null or p_opp=s.student_id or not public._student_ok(g,p_opp) then raise exception 'bad_input'; end if;
  cfg := coalesce(g.data->'lsn','{}'::jsonb);
  if p_course is null or p_course not in ('hd','ax','aq','fq','si','tj','an','nm','h4','du') then raise exception 'bad_input'; end if;
  if not exists(select 1 from jsonb_array_elements(g.data->'students') as a(st)
                where st->>'id'=p_opp and (st->>'hid') is distinct from 'true') then raise exception 'bad_input'; end if;
  if not accepting and not (
       coalesce(cfg->'at'->>p_course,'9999-12-31') <= today or
       (case when p_course in ('an','nm','h4','du') then cfg->'on'->p_course='true'::jsonb
             else (cfg->'on'->p_course) is distinct from 'false'::jsonb end) is true
     ) then raise exception 'duel_locked'; end if;
  select * into r from public.duel_rounds
    where group_id=g.id and player=s.student_id and opponent=p_opp and course=p_course
      and duel_rounds.accepting=(p_invite is not null) and invitation is not distinct from p_invite
      and result is null and started_at > clock_timestamp()-interval '20 minutes'
    order by started_at desc limit 1;
  if found then return public._duel_round_prompt(r); end if;
  if (select count(*) from public.duel_rounds where group_id=g.id and player=s.student_id and started_at>now()-interval '1 day')>=20
    then raise exception 'duel_daily'; end if;
  if accepting then
    select questions into qs from public.duel_rounds where invitation=d.id and player=d.a and duel_rounds.accepting=false and result is not null;
    if not found then raise exception 'duel_legacy'; end if;
  else
    if (select count(*) from public.duels where group_id=g.id and a=s.student_id and created_at>now()-interval '1 day')>=5
      then raise exception 'duel_daily'; end if;
    if exists(select 1 from public.duels x join public.duel_rounds k on k.invitation=x.id and not k.accepting
               where x.group_id=g.id and x.a=s.student_id and x.b=p_opp and x.b_score is null)
      then raise exception 'pending'; end if;
    select jsonb_agg(p.question || jsonb_build_object('answer',p.answer)) into qs
      from (select b.question,b.answer from public.duel_bank b
             where b.course=p_course and (
               jsonb_typeof(cfg->'open'->p_course) is distinct from 'array'
               or (cfg->'open'->p_course) ? b.lesson::text
               or coalesce(cfg->'lat'->>(p_course||'|'||b.lesson),'9999-12-31')<=today
               or exists (select 1 from public.lesson_progress lp
                     where lp.group_id=g.id and lp.student_id=s.student_id and lp.course=p_course
                       and lp.lesson=p_course||(b.lesson+1) and lp.best_stars>0)
             ) order by random() limit 6) p;
    if coalesce(jsonb_array_length(qs),0)<3 then raise exception 'duel_short'; end if;
  end if;
  insert into public.duel_rounds(group_id,player,opponent,course,accepting,invitation,questions)
    values(g.id,s.student_id,p_opp,p_course,p_invite is not null,p_invite,qs) returning * into r;
  return public._duel_round_prompt(r);
end $$;

create or replace function public.duel_round_finish(p_slug text,p_stoken text,p_round uuid,p_answers integer[])
returns json language plpgsql security definer set search_path = '' as $$
declare s public.student_sessions; g public.groups; r public.duel_rounds; d public.duels;
        n int; i int; q jsonb; score int := 0; elapsed int; winner_id text; receipt jsonb;
begin
  s := public._wauth(p_slug,p_stoken);
  select * into g from public.groups where id=s.group_id for update;
  if (g.data->'teen') is distinct from 'true'::jsonb then raise exception 'teen_only'; end if;
  select * into r from public.duel_rounds where id=p_round and group_id=g.id and player=s.student_id for update;
  if not found then raise exception 'not_found'; end if;
  if r.result is not null then return (r.result||jsonb_build_object('replayed',true))::json; end if;
  if r.started_at<clock_timestamp()-interval '20 minutes' then raise exception 'duel_expired'; end if;
  n := jsonb_array_length(r.questions);
  if coalesce(array_length(p_answers,1),0)<>n or array_ndims(p_answers)<>1 or array_lower(p_answers,1)<>1 then
    raise exception 'bad_input'; end if;
  for i in 1..n loop
    q := r.questions->(i-1);
    if p_answers[i] is null or p_answers[i]<0 or p_answers[i]>=jsonb_array_length(q->'opts') then raise exception 'bad_input'; end if;
    if p_answers[i]=(q->>'answer')::int then score:=score+1; end if;
  end loop;
  elapsed := greatest(0,floor(extract(epoch from (clock_timestamp()-r.started_at))*1000)::int);
  if not r.accepting then
    if (select count(*) from public.duels where group_id=g.id and a=s.student_id and created_at>now()-interval '1 day')>=5
      then raise exception 'duel_daily'; end if;
    if exists(select 1 from public.duels x join public.duel_rounds k on k.invitation=x.id and not k.accepting
               where x.group_id=g.id and x.a=r.player and x.b=r.opponent and x.b_score is null)
      then raise exception 'pending'; end if;
    insert into public.duels(group_id,a,b,course,qs,a_score,a_ms)
      values(g.id,r.player,r.opponent,r.course, (public._duel_round_prompt(r)->'qs')::jsonb,score,elapsed) returning * into d;
  else
    select * into d from public.duels where id=r.invitation and group_id=g.id and b=s.student_id for update;
    if not found then raise exception 'not_found'; end if;
    if d.b_score is not null then raise exception 'done'; end if;
    winner_id := case when score>d.a_score then d.b when score<d.a_score then d.a
                  when elapsed<d.a_ms then d.b when elapsed>d.a_ms then d.a else 'draw' end;
    update public.duels set b_score=score,b_ms=elapsed,winner=winner_id,done_at=now() where id=d.id returning * into d;
    if winner_id<>'draw' then
      perform public._wallet(g.id,winner_id);
      update public.wallets set dates=dates+10,earned=earned+10,updated_at=now()
        where group_id=g.id and student_id=winner_id;
      insert into public.wallet_log(group_id,student_id,kind,dates,pearls,note)
        values(g.id,winner_id,'duel',10,0,'победа в дуэли');
    end if;
  end if;
  receipt := jsonb_build_object('ok',true,'score',score,'ms',elapsed,'id',d.id,'winner',winner_id,
                                 'a_score',d.a_score,'a_ms',d.a_ms,'b_score',d.b_score,'b_ms',d.b_ms);
  update public.duel_rounds set result=receipt,invitation=d.id where id=r.id;
  return receipt::json;
end $$;

create or replace function public.duel_list(p_slug text,p_stoken text) returns json
language plpgsql security definer set search_path = '' as $$
declare s public.student_sessions;
begin
  s := public._wauth(p_slug,p_stoken);
  if not exists(select 1 from public.groups where id=s.group_id and data->'teen'='true'::jsonb) then return '[]'::json; end if;
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select d.id,d.a,d.b,d.course,d.a_score,d.a_ms,d.b_score,d.b_ms,d.winner,d.created_at,d.done_at,
      jsonb_array_length(d.qs) as total,
      exists(select 1 from public.duel_rounds r where r.invitation=d.id and not r.accepting and r.result is not null) as verified
      from public.duels d where d.group_id=s.group_id and (d.a=s.student_id or d.b=s.student_id)
      order by d.created_at desc limit 20)x),'[]'::json);
end $$;

-- Старые приложения больше не могут прислать самостоятельно посчитанные баллы.
create or replace function public.duel_create(p_slug text,p_stoken text,p_opp text,p_course text,p_qs jsonb,p_score integer,p_ms integer)
returns json language plpgsql security definer set search_path = '' as $$
begin
  perform public._wauth(p_slug,p_stoken);
  raise exception 'update_required';
end $$;

create or replace function public.duel_play(p_slug text,p_stoken text,p_id bigint,p_score integer,p_ms integer)
returns json language plpgsql security definer set search_path = '' as $$
begin
  perform public._wauth(p_slug,p_stoken);
  raise exception 'update_required';
end $$;

revoke all on function public._duel_round_prompt(public.duel_rounds) from public, anon, authenticated;
revoke all on function public.duel_round_start(text,text,text,text,bigint),
  public.duel_round_finish(text,text,uuid,integer[]) from public;
grant execute on function public.duel_round_start(text,text,text,text,bigint),
  public.duel_round_finish(text,text,uuid,integer[]) to anon, authenticated;
notify pgrst, 'reload schema';
