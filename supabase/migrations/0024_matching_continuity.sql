-- =====================================================================
-- 0024 매칭 연속성 — "오퍼 전원 무응답" 데드엔드 수정 (코어 결함)
--  · 기존: run_match 1회 → 오퍼 3건 전원 만료 시 요청이 'matching'에 영원히 정체.
--  · 수정: continue_matching이 만료 오퍼 정리 → 다음 후보 웨이브 + 반경 확장
--    (3→5→7→9→10km) → 후보 소진 시 'expired'로 정직한 실패(수수료 0 약속).
--  · 구동: 사장 매칭화면 폴링(주) + pg_cron sweep(보조, 가용 환경에서만).
--  · 사장님 '다시 찾기': expired 요청을 소유자가 호출하면 이력 리셋 후 재탐색.
-- =====================================================================
set search_path = public, extensions;

alter table job_requests add column if not exists match_attempts int not null default 0;

create or replace function public.continue_matching(p_request_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_req    job_requests;
  v_live   int;
  v_new    int;
  v_radius int;
  c_max_radius constant int := 10000;
  c_max_attempts constant int := 5;  -- 최대반경 도달 후 추가 탐색 횟수 포함
begin
  select * into v_req from job_requests where id = p_request_id for update;
  if v_req.id is null then raise exception 'request_not_found'; end if;
  -- 사용자 컨텍스트에서는 소유자만. (cron/service_role은 auth.uid()가 null → 통과)
  if auth.uid() is not null and v_req.employer_id <> auth.uid() then
    raise exception 'not_your_request';
  end if;

  -- 사장님 '다시 찾기': 만료 요청 → 무응답 이력 지우고 처음부터 재탐색
  if v_req.status = 'expired' and auth.uid() is not null then
    delete from match_offers where request_id = p_request_id
      and status in ('expired','declined','cancelled');
    update job_requests set status = 'open', match_attempts = 0
      where id = p_request_id;
    v_req.status := 'open'; v_req.match_attempts := 0;
  end if;

  if v_req.status not in ('open','matching')
     or v_req.filled_count >= v_req.headcount then
    return jsonb_build_object('state','noop','status',v_req.status::text);
  end if;

  -- 시작 시간이 지난 요청: 미확정 오퍼 정리 후, 부분충원(filled>0)이면 확정 수용,
  -- 아무도 없으면 정직한 실패(expired). '매칭 실패'로 오표기하지 않는다.
  if v_req.start_at <= now() then
    update match_offers set status = 'expired'
      where request_id = p_request_id and status = 'offered';
    update job_requests
       set status = (case when filled_count > 0 then 'confirmed' else 'expired' end)::request_status
     where id = p_request_id;
    return jsonb_build_object('state', case when v_req.filled_count > 0 then 'partial' else 'exhausted' end,
                              'reason','start_passed');
  end if;

  -- 시간 만료된 오퍼 정리
  update match_offers set status = 'expired'
    where request_id = p_request_id and status = 'offered' and expires_at < now();

  -- 아직 살아있는 오퍼가 있으면 대기
  select count(*) into v_live from match_offers
    where request_id = p_request_id and status = 'offered';
  if v_live > 0 then
    return jsonb_build_object('state','waiting','live_offers',v_live,
                              'attempts',v_req.match_attempts);
  end if;

  -- 다음 웨이브: 반경 확장 후 재매칭(이미 오퍼받은 근로자는 run_match가 자동 제외)
  v_radius := least(3000 + v_req.match_attempts * 2000, c_max_radius);
  v_new := public.run_match(p_request_id, v_radius, 0, 3, 60,
                            coalesce(v_req.requires_professional, false));
  update job_requests set match_attempts = match_attempts + 1
    where id = p_request_id;

  if v_new > 0 then
    return jsonb_build_object('state','rewaved','new_offers',v_new,
                              'radius_m',v_radius,'attempts',v_req.match_attempts + 1);
  end if;

  -- 신규 0명: 최대 반경까지 두어 번 훑었으면 종료. 부분충원이면 확정 수용, 없으면 expired.
  if v_radius >= c_max_radius and v_req.match_attempts + 1 >= c_max_attempts then
    update job_requests
       set status = (case when filled_count > 0 then 'confirmed' else 'expired' end)::request_status
     where id = p_request_id;
    return jsonb_build_object('state', case when v_req.filled_count > 0 then 'partial' else 'exhausted' end,
                              'radius_m',v_radius);
  end if;
  return jsonb_build_object('state','searching','new_offers',0,
                            'radius_m',v_radius,'attempts',v_req.match_attempts + 1);
end; $$;

-- 백그라운드 sweep: 정체된 open/matching 요청 전체를 전진시킨다(cron용).
-- 건별 예외를 삼켜(poisoned 요청 1건이 전체를 막지 않게) 견고하게 순회.
create or replace function public.sweep_matching()
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare r record; n int := 0;
begin
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

-- anon/PUBLIC이 null-uid로 소유자검증을 우회하지 못하게 명시 차단.
-- run_match는 내부 헬퍼(소유검증 없음) — request_matching 등 DEFINER 경유로만 호출돼야 하므로
-- PUBLIC 직접 실행을 차단(owner/DEFINER 호출엔 영향 없음).
revoke execute on function public.continue_matching(uuid) from public;
revoke execute on function public.sweep_matching() from public;
revoke execute on function public.run_match(uuid, int, numeric, int, int, boolean) from public;
grant execute on function public.continue_matching(uuid) to authenticated;
-- sweep_matching·run_match은 cron/DEFINER 전용(authenticated grant 없음).

-- pg_cron 스케줄(가용 환경에서만 — 실패해도 마이그레이션은 계속).
do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('sweep-matching', '30 seconds',
                        'select public.sweep_matching()');
exception when others then
  raise notice 'pg_cron 스케줄 생략(가용하지 않음): %', sqlerrm;
end $$;
