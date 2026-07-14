-- 실시간 위치공유 E2E (트랜잭션 후 롤백).
-- 검증: 근로자 위치 갱신 + 근무지 거리계산 · upsert(1행) · 당사자 열람 · 외부인 차단.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('c4000000-0000-0000-0000-0000000000e1','employer','사장'),
  ('c4000000-0000-0000-0000-0000000000d1','worker','근로자'),
  ('c4000000-0000-0000-0000-0000000000c3','worker','외부인');
insert into employer_profiles (profile_id, business_name) values
  ('c4000000-0000-0000-0000-0000000000e1','카페');
insert into worker_profiles (profile_id, is_available, identity_verified_at) values
  ('c4000000-0000-0000-0000-0000000000d1', true, now()),
  ('c4000000-0000-0000-0000-0000000000c3', true, now());
insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount) values
  ('c4000000-0000-0000-0000-0000000000a1','c4000000-0000-0000-0000-0000000000e1','대타',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '1 hour', now()+interval '9 hours', 96000, 1);
insert into assignments (id, request_id, worker_id, status) values
  ('c4000000-0000-0000-0000-0000000000b1','c4000000-0000-0000-0000-0000000000a1',
   'c4000000-0000-0000-0000-0000000000d1','checked_in');

set local session_replication_role = origin;

-- 1) 근로자가 근무지에서 ~180m 떨어진 지점 공유 → 거리 계산 확인.
set local request.jwt.claims = '{"sub":"c4000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
do $$ begin perform update_live_location('c4000000-0000-0000-0000-0000000000b1', 37.4990, 127.0290); end $$;
select '① 거리 계산됨(>0)' as step, (dist_to_site_m > 0) as ok
  from live_locations where assignment_id='c4000000-0000-0000-0000-0000000000b1';

-- 2) 재호출 시 upsert(같은 행 갱신, 1행 유지).
do $$ begin perform update_live_location('c4000000-0000-0000-0000-0000000000b1', 37.4980, 127.0278); end $$;
select '② 공유행 수(기대 1)' as step, count(*) as value
  from live_locations where assignment_id='c4000000-0000-0000-0000-0000000000b1';
select '② 근무지 근접(거리 감소)' as step, (dist_to_site_m < 100) as ok
  from live_locations where assignment_id='c4000000-0000-0000-0000-0000000000b1';

-- 3) 상대 당사자(업주)가 실시간 위치 열람.
set local role authenticated;
set local request.jwt.claims = '{"sub":"c4000000-0000-0000-0000-0000000000e1","role":"authenticated"}';
select '③ 업주가 보는 공유 수(기대 1)' as step, count(*) as value
  from live_locations where assignment_id='c4000000-0000-0000-0000-0000000000b1';

-- 4) 외부인은 열람 불가.
set local request.jwt.claims = '{"sub":"c4000000-0000-0000-0000-0000000000c3","role":"authenticated"}';
select '④ 외부인이 보는 공유 수(기대 0)' as step, count(*) as value
  from live_locations where assignment_id='c4000000-0000-0000-0000-0000000000b1';
reset role;

-- 5) 비당사자 갱신 차단.
set local request.jwt.claims = '{"sub":"c4000000-0000-0000-0000-0000000000c3","role":"authenticated"}';
do $$ begin
  perform update_live_location('c4000000-0000-0000-0000-0000000000b1', 37.5, 127.0);
  raise notice '⑤ FAIL: 비당사자 갱신 통과됨';
exception when others then
  raise notice '⑤ OK: 비당사자 갱신 차단 (%)', sqlerrm;
end $$;

-- 6) 체크아웃(공유 종료) → 행 삭제.
set local request.jwt.claims = '{"sub":"c4000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
do $$ begin perform stop_live_location('c4000000-0000-0000-0000-0000000000b1'); end $$;
select '⑥ 종료 후 공유행(기대 0)' as step, count(*) as value
  from live_locations where assignment_id='c4000000-0000-0000-0000-0000000000b1';

rollback;
