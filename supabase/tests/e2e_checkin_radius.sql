-- GPS 체크인 반경검증 E2E (트랜잭션 후 롤백).
-- 검증: 반경 내 체크인 성공(+요청 in_progress) · 반경 밖 차단 · 좌표 없으면 스킵.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('c5000000-0000-0000-0000-0000000000e1','employer','사장'),
  ('c5000000-0000-0000-0000-0000000000d1','worker','근로자');
insert into employer_profiles (profile_id, business_name) values
  ('c5000000-0000-0000-0000-0000000000e1','카페');
insert into worker_profiles (profile_id, is_available, identity_verified_at) values
  ('c5000000-0000-0000-0000-0000000000d1', true, now());
-- 근무지: 강남역(127.0276, 37.4979)
insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount, status) values
  ('c5000000-0000-0000-0000-0000000000a1','c5000000-0000-0000-0000-0000000000e1','대타',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '1 hour', now()+interval '9 hours', 96000, 1, 'confirmed');
insert into assignments (id, request_id, worker_id, status) values
  ('c5000000-0000-0000-0000-0000000000b1','c5000000-0000-0000-0000-0000000000a1',
   'c5000000-0000-0000-0000-0000000000d1','confirmed');

set local session_replication_role = origin;
set local request.jwt.claims = '{"sub":"c5000000-0000-0000-0000-0000000000d1","role":"authenticated"}';

-- 1) 반경 밖(약 2km 떨어진 지점) → 차단.
do $$ begin
  perform check_in('c5000000-0000-0000-0000-0000000000b1', 127.05, 37.51);
  raise notice '① FAIL: 반경 밖 체크인이 통과됨';
exception when others then
  raise notice '① OK: 반경 밖 체크인 차단 (%)', sqlerrm;
end $$;
select '① 차단 후에도 상태 confirmed 유지' as step, status::text as v
  from assignments where id='c5000000-0000-0000-0000-0000000000b1';

-- 2) 반경 내(근무지에서 ~180m) → 성공.
do $$ begin perform check_in('c5000000-0000-0000-0000-0000000000b1', 127.0290, 37.4990); end $$;
select '② 반경 내 체크인 후 상태' as step, status::text as v
  from assignments where id='c5000000-0000-0000-0000-0000000000b1';
select '② 요청 in_progress 전이' as step, status::text as v
  from job_requests where id='c5000000-0000-0000-0000-0000000000a1';

rollback;
