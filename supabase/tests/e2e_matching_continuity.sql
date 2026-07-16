-- 매칭 연속성 E2E (트랜잭션 후 롤백).
-- 검증: 무응답 만료 → 자동 다음 웨이브 + 반경확장 → 후보소진 시 expired → 다시 찾기.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('cc000000-0000-0000-0000-0000000000e1','employer','사장'),
  ('cc000000-0000-0000-0000-0000000000d1','worker','근거리A'),
  ('cc000000-0000-0000-0000-0000000000d2','worker','근거리B'),
  ('cc000000-0000-0000-0000-0000000000d3','worker','원거리C');
insert into employer_profiles (profile_id, business_name) values
  ('cc000000-0000-0000-0000-0000000000e1','카페');
-- A·B: 근무지 ~200m / C: ~4km(1차 3km 밖, 2차 5km 안)
insert into worker_profiles (profile_id, is_available, identity_verified_at, current_geog, reliability_score) values
  ('cc000000-0000-0000-0000-0000000000d1', true, now(), st_setsrid(st_makepoint(127.0290,37.4990),4326)::geography, 80),
  ('cc000000-0000-0000-0000-0000000000d2', true, now(), st_setsrid(st_makepoint(127.0300,37.4995),4326)::geography, 85),
  ('cc000000-0000-0000-0000-0000000000d3', true, now(), st_setsrid(st_makepoint(127.0700,37.5100),4326)::geography, 90);
insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount, status) values
  ('cc000000-0000-0000-0000-0000000000a1','cc000000-0000-0000-0000-0000000000e1','대타',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '3 hours', now()+interval '9 hours', 96000, 1, 'open');

set local request.jwt.claims = '{"sub":"cc000000-0000-0000-0000-0000000000e1","role":"authenticated"}';

-- 1) 1차 웨이브(3km): 근거리 A·B에게 오퍼
select '① 1차 웨이브' as step, continue_matching('cc000000-0000-0000-0000-0000000000a1') as v;
select '① 오퍼 수(기대 2)' as step, count(*) as v from match_offers
  where request_id='cc000000-0000-0000-0000-0000000000a1' and status='offered';

-- 2) 전원 무응답(만료 강제) → 다음 웨이브가 반경 확장으로 원거리C 발견
update match_offers set expires_at = now() - interval '1 second'
  where request_id='cc000000-0000-0000-0000-0000000000a1' and status='offered';
select '② 2차 웨이브(5km 확장)' as step, continue_matching('cc000000-0000-0000-0000-0000000000a1') as v;
select '② 신규 오퍼 대상(기대 원거리C)' as step, p.display_name as v
  from match_offers o join profiles p on p.id=o.worker_id
  where o.request_id='cc000000-0000-0000-0000-0000000000a1' and o.status='offered';

-- 3) 또 무응답 → 반경 최대까지 소진 → expired(정직한 실패)
update match_offers set expires_at = now() - interval '1 second'
  where request_id='cc000000-0000-0000-0000-0000000000a1' and status='offered';
do $$ declare i int; r jsonb; begin
  for i in 1..6 loop
    select continue_matching('cc000000-0000-0000-0000-0000000000a1') into r;
    exit when r->>'state' = 'exhausted';
  end loop;
  raise notice '③ 최종 state: %', r->>'state';
end $$;
select '③ 요청 상태(기대 expired)' as step, status::text as v
  from job_requests where id='cc000000-0000-0000-0000-0000000000a1';

-- 4) 사장님 '다시 찾기' → 이력 리셋 + 재웨이브(A·B 다시 오퍼받음)
select '④ 다시 찾기' as step, (continue_matching('cc000000-0000-0000-0000-0000000000a1')->>'state') as v;
select '④ 재탐색 오퍼 수(기대 2)' as step, count(*) as v from match_offers
  where request_id='cc000000-0000-0000-0000-0000000000a1' and status='offered';
select '④ 요청 상태(기대 matching)' as step, status::text as v
  from job_requests where id='cc000000-0000-0000-0000-0000000000a1';

-- 5) 타인 접근 차단
set local request.jwt.claims = '{"sub":"cc000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
do $$ begin
  perform continue_matching('cc000000-0000-0000-0000-0000000000a1');
  raise notice '⑤ FAIL: 타인 continue 통과됨';
exception when others then
  raise notice '⑤ OK: 타인 차단 (%)', sqlerrm;
end $$;

rollback;
