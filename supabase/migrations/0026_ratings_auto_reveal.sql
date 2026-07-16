-- =====================================================================
-- 0026 평점 14일 자동공개 — 한쪽만 제출 시 영구 미공개 버그 해소
--  · 설계(0001 주석): "양측 제출 or 14일 후 동시공개" — 후자가 미구현이었음.
--  · lazy(조회 시) + sweep(cron) 이중 경로로 cron 없는 환경에서도 동작.
-- =====================================================================
set search_path = public, extensions;

create or replace function public.reveal_stale_ratings()
returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update ratings set revealed_at = now()
   where revealed_at is null and not locked
     and submitted_at < now() - interval '14 days';
  get diagnostics n = row_count;
  return n;
end; $$;

-- 조회 시 lazy 공개: 14일 경과 평점을 먼저 공개 처리 후, 0009 원본과
-- 동일한 형태({mine, theirs, revealed})로 반환. (stable 제거 — UPDATE 포함)
create or replace function public.ratings_for_assignment(p_assignment_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_worker uuid; v_employer uuid; v jsonb;
begin
  select a.worker_id, r.employer_id into v_worker, v_employer
    from assignments a join job_requests r on r.id = a.request_id where a.id = p_assignment_id;
  if v_uid <> v_worker and v_uid <> v_employer then raise exception 'not_a_party'; end if;
  update ratings set revealed_at = now()
   where assignment_id = p_assignment_id and revealed_at is null and not locked
     and submitted_at < now() - interval '14 days';
  select jsonb_build_object(
    'mine', (select jsonb_build_object('stars', stars, 'comment', comment, 'sub_scores', sub_scores)
             from ratings where assignment_id = p_assignment_id and rater_id = v_uid),
    'theirs', (select jsonb_build_object('stars', stars, 'comment', comment, 'sub_scores', sub_scores)
               from ratings where assignment_id = p_assignment_id and rater_id <> v_uid
                 and revealed_at is not null),
    'revealed', exists (select 1 from ratings where assignment_id = p_assignment_id
                          and rater_id <> v_uid and revealed_at is not null)
  ) into v;
  return v;
end; $$;

-- sweep(0024)이 평점 공개도 겸하도록 재정의(단일 cron 잡 유지).
-- reveal을 먼저 실행(매칭 순회 예외와 독립) + 건별 예외 격리 + open/matching 포함.
create or replace function public.sweep_matching()
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare r record; n int := 0;
begin
  perform public.reveal_stale_ratings();  -- 매칭과 독립 — 먼저 실행해 굶지 않게
  for r in select id from job_requests
            where status in ('open','matching')
              and filled_count < headcount
  loop
    begin
      perform public.continue_matching(r.id);
      n := n + 1;
    exception when others then
      raise notice 'sweep continue_matching 실패(무시): % %', r.id, sqlerrm;
    end;
  end loop;
  return n;
end; $$;

-- reveal_stale_ratings는 cron/service 전용(authenticated grant 없음 — 남의 평점 강제공개 방지).
revoke execute on function public.reveal_stale_ratings() from public;
grant execute on function public.ratings_for_assignment(uuid) to authenticated;

notify pgrst, 'reload schema';
