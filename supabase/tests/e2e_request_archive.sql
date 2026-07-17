-- 요청 보관(목록 숨김) E2E (트랜잭션 후 롤백).
-- 검증: 종료 요청 보관 · 진행 중 요청 차단 · 타인 요청 차단 · 재보관 멱등.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('ca000000-0000-0000-0000-0000000000e1','employer','사장'),
  ('ca000000-0000-0000-0000-0000000000e2','employer','타사장');
insert into employer_profiles (profile_id, business_name) values
  ('ca000000-0000-0000-0000-0000000000e1','카페'),('ca000000-0000-0000-0000-0000000000e2','타카페');

-- a1: cancelled(보관 가능) / a2: matching(보관 불가) / a3: completed(보관 가능)
insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount, status) values
  ('ca000000-0000-0000-0000-0000000000a1','ca000000-0000-0000-0000-0000000000e1','취소된요청',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()-interval '2 hours', now()+interval '2 hours', 100000, 1, 'cancelled'),
  ('ca000000-0000-0000-0000-0000000000a2','ca000000-0000-0000-0000-0000000000e1','매칭중요청',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '5 hours', now()+interval '9 hours', 100000, 1, 'matching'),
  ('ca000000-0000-0000-0000-0000000000a3','ca000000-0000-0000-0000-0000000000e1','완료요청',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()-interval '9 hours', now()-interval '2 hours', 100000, 1, 'completed');

set local request.jwt.claims = '{"sub":"ca000000-0000-0000-0000-0000000000e1","role":"authenticated"}';

-- 1) cancelled 요청 보관 → archived_at 세팅
select archive_job_request('ca000000-0000-0000-0000-0000000000a1');
select '① cancelled 보관(기대 true)' as step,
  (archived_at is not null)::text as v
  from job_requests where id='ca000000-0000-0000-0000-0000000000a1';

-- 2) completed 요청 보관 → archived_at 세팅
select archive_job_request('ca000000-0000-0000-0000-0000000000a3');
select '② completed 보관(기대 true)' as step,
  (archived_at is not null)::text as v
  from job_requests where id='ca000000-0000-0000-0000-0000000000a3';

-- 3) 재보관 멱등 — 기존 archived_at 유지(coalesce)
update job_requests set archived_at = now() - interval '1 day'
 where id='ca000000-0000-0000-0000-0000000000a1';
select archive_job_request('ca000000-0000-0000-0000-0000000000a1');
select '③ 재보관 멱등(기대 true)' as step,
  (archived_at = now() - interval '1 day')::text as v
  from job_requests where id='ca000000-0000-0000-0000-0000000000a1';

-- 4) matching(진행 중) 요청 보관 시도 → not_closed 차단
do $$ begin
  perform archive_job_request('ca000000-0000-0000-0000-0000000000a2');
  raise notice '④ FAIL: 진행 중 요청 보관 통과됨';
exception when others then
  raise notice '④ OK: 진행 중 요청 보관 차단 (%)', sqlerrm;
end $$;

-- 5) 타인 요청 보관 시도 → not_your_request 차단
set local request.jwt.claims = '{"sub":"ca000000-0000-0000-0000-0000000000e2","role":"authenticated"}';
do $$ begin
  perform archive_job_request('ca000000-0000-0000-0000-0000000000a3');
  raise notice '⑤ FAIL: 타인 요청 보관 통과됨';
exception when others then
  raise notice '⑤ OK: 타인 요청 보관 차단 (%)', sqlerrm;
end $$;

rollback;
