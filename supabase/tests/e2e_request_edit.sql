-- 요청 수정 E2E (트랜잭션 후 롤백).
-- 검증: matching 중 수정(급여·인원) + 옛 오퍼 취소 + open 복귀 · 최저임금 차단 · 확정후 불가 · 타인 차단.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('c9000000-0000-0000-0000-0000000000e1','employer','사장'),
  ('c9000000-0000-0000-0000-0000000000e2','employer','타사장'),
  ('c9000000-0000-0000-0000-0000000000d1','worker','근로자');
insert into employer_profiles (profile_id, business_name) values
  ('c9000000-0000-0000-0000-0000000000e1','카페'),('c9000000-0000-0000-0000-0000000000e2','타카페');

-- 요청1: matching + 오퍼(수정 대상), 8시간 근무
insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount, status) values
  ('c9000000-0000-0000-0000-0000000000a1','c9000000-0000-0000-0000-0000000000e1','요청1',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '3 hours', now()+interval '11 hours', 100000, 1, 'matching');
insert into match_offers (id, request_id, worker_id, rank, score, status, expires_at) values
  ('c9000000-0000-0000-0000-0000000000f1','c9000000-0000-0000-0000-0000000000a1',
   'c9000000-0000-0000-0000-0000000000d1', 1, 0.9, 'offered', now()+interval '60 seconds');

set local request.jwt.claims = '{"sub":"c9000000-0000-0000-0000-0000000000e1","role":"authenticated"}';

-- 1) 급여 12만·인원 3으로 수정
do $$ begin perform edit_job_request('c9000000-0000-0000-0000-0000000000a1', null, null, null, 120000, 3); end $$;
select '① 수정 후 급여/인원/상태' as step, pay_amount, headcount, status::text
  from job_requests where id='c9000000-0000-0000-0000-0000000000a1';
select '① 옛 오퍼 취소됨(기대 cancelled)' as step, status::text as v
  from match_offers where id='c9000000-0000-0000-0000-0000000000f1';

-- 2) 최저임금 미달 수정 차단(8시간에 5만원 = 시급 6250 < 10320)
do $$ begin
  perform edit_job_request('c9000000-0000-0000-0000-0000000000a1', null, null, null, 50000);
  raise notice '② FAIL: 최저임금 미달 통과됨';
exception when others then
  raise notice '② OK: 최저임금 미달 차단 (%)', sqlerrm;
end $$;

-- 3) 확정 상태로 바꾼 뒤 수정 불가 확인
update job_requests set status='confirmed' where id='c9000000-0000-0000-0000-0000000000a1';
do $$ begin
  perform edit_job_request('c9000000-0000-0000-0000-0000000000a1', '변경시도');
  raise notice '③ FAIL: 확정 요청 수정 통과됨';
exception when others then
  raise notice '③ OK: 확정 요청 수정 차단 (%)', sqlerrm;
end $$;

-- 4) 타인 요청 수정 차단
update job_requests set status='matching' where id='c9000000-0000-0000-0000-0000000000a1';
set local request.jwt.claims = '{"sub":"c9000000-0000-0000-0000-0000000000e2","role":"authenticated"}';
do $$ begin
  perform edit_job_request('c9000000-0000-0000-0000-0000000000a1', '탈취');
  raise notice '④ FAIL: 타인 요청 수정 통과됨';
exception when others then
  raise notice '④ OK: 타인 요청 수정 차단 (%)', sqlerrm;
end $$;

rollback;
