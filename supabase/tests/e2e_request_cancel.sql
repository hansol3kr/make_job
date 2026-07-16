-- 요청 취소 E2E (트랜잭션 후 롤백).
-- 검증: matching 무료취소(오퍼취소) · 확정 후 티어 보상수수료 · 타인 요청 차단.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('c8000000-0000-0000-0000-0000000000e1','employer','사장'),
  ('c8000000-0000-0000-0000-0000000000e2','employer','타사장'),
  ('c8000000-0000-0000-0000-0000000000d1','worker','근로자');
insert into employer_profiles (profile_id, business_name) values
  ('c8000000-0000-0000-0000-0000000000e1','카페'),('c8000000-0000-0000-0000-0000000000e2','타카페');
insert into worker_profiles (profile_id, is_available, identity_verified_at) values
  ('c8000000-0000-0000-0000-0000000000d1', true, now());

-- 요청1: matching 상태 + 미확정 오퍼 (무료 취소 대상)
insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount, status) values
  ('c8000000-0000-0000-0000-0000000000a1','c8000000-0000-0000-0000-0000000000e1','요청1',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '5 hours', now()+interval '9 hours', 100000, 1, 'matching');
insert into match_offers (id, request_id, worker_id, rank, score, status, expires_at) values
  ('c8000000-0000-0000-0000-0000000000f1','c8000000-0000-0000-0000-0000000000a1',
   'c8000000-0000-0000-0000-0000000000d1', 1, 0.9, 'offered', now()+interval '60 seconds');

-- 요청2: 확정 배정, 근무 시작 1시간 전(→ near_pct 50%)
insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount, status) values
  ('c8000000-0000-0000-0000-0000000000a2','c8000000-0000-0000-0000-0000000000e1','요청2',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '1 hour', now()+interval '7 hours', 100000, 1, 'confirmed');
insert into assignments (id, request_id, worker_id, status) values
  ('c8000000-0000-0000-0000-0000000000b2','c8000000-0000-0000-0000-0000000000a2',
   'c8000000-0000-0000-0000-0000000000d1','confirmed');

set local request.jwt.claims = '{"sub":"c8000000-0000-0000-0000-0000000000e1","role":"authenticated"}';

-- 1) matching 요청 취소 → 무료(fee 0), 오퍼 취소, 요청 cancelled
select '① 무료 취소 fee_total(기대 0)' as step,
  (cancel_job_request('c8000000-0000-0000-0000-0000000000a1')->>'fee_total') as v;
select '① 오퍼 상태(기대 cancelled)' as step, status::text as v
  from match_offers where id='c8000000-0000-0000-0000-0000000000f1';
select '① 요청 상태(기대 cancelled)' as step, status::text as v
  from job_requests where id='c8000000-0000-0000-0000-0000000000a1';

-- 2) 확정 요청 취소(1h 전 → 50%) → 보상 100000*50%=50000, 배정 cancelled_employer
select '② 확정취소 결과' as step, cancel_job_request('c8000000-0000-0000-0000-0000000000a2') as v;
select '② 배정 상태(기대 cancelled_employer)' as step, status::text as v
  from assignments where id='c8000000-0000-0000-0000-0000000000b2';
select '② 업주 페널티 기록(기대 employer_cancel 50000)' as step, kind, amount
  from penalties where assignment_id='c8000000-0000-0000-0000-0000000000b2';

-- 3) 타인(타사장)이 사장 요청 취소 시도 → 차단
set local request.jwt.claims = '{"sub":"c8000000-0000-0000-0000-0000000000e2","role":"authenticated"}';
do $$ begin
  perform cancel_job_request('c8000000-0000-0000-0000-0000000000a2');
  raise notice '③ FAIL: 타인 요청 취소 통과됨';
exception when others then
  raise notice '③ OK: 타인 요청 취소 차단 (%)', sqlerrm;
end $$;

rollback;
