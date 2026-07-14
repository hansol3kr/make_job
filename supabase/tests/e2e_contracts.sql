-- 전자 근로계약서 E2E (트랜잭션 후 롤백).
-- 검증: 확정 조건으로 계약 생성 · 멱등(1건) · 양측 서명 · 비당사자 차단 · 당사자=요청자 명문화.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('c2000000-0000-0000-0000-0000000000e1','employer','김사장'),
  ('c2000000-0000-0000-0000-0000000000d1','worker','이근로'),
  ('c2000000-0000-0000-0000-0000000000c3','worker','박외부');

insert into employer_profiles (profile_id, business_name) values
  ('c2000000-0000-0000-0000-0000000000e1','강남편의점');
insert into worker_profiles (profile_id, is_available, identity_verified_at) values
  ('c2000000-0000-0000-0000-0000000000d1', true, now()),
  ('c2000000-0000-0000-0000-0000000000c3', true, now());

insert into job_requests (id, employer_id, title, geog, address, start_at, end_at, pay_type, pay_amount, headcount) values
  ('c2000000-0000-0000-0000-0000000000a1',
   'c2000000-0000-0000-0000-0000000000e1','편의점 야간 대타',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography, '서울 강남구 …',
   now()+interval '2 hours', now()+interval '10 hours', 'daily', 96000, 1);

insert into assignments (id, request_id, worker_id, status) values
  ('c2000000-0000-0000-0000-0000000000b1',
   'c2000000-0000-0000-0000-0000000000a1',
   'c2000000-0000-0000-0000-0000000000d1','confirmed');

set local session_replication_role = origin;

-- 1) 근로자가 계약 최초 조회 → 생성. 당사자=요청자 명문화 + 일용근로소득 확인.
set local request.jwt.claims = '{"sub":"c2000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
select '① 계약 생성: 소득유형' as step, (get_or_create_contract('c2000000-0000-0000-0000-0000000000b1')->>'income_type') as value;
select '① 계약 생성: 당사자=요청자' as step, (get_or_create_contract('c2000000-0000-0000-0000-0000000000b1')->'terms'->>'employer_is_user') as value;
select '① 계약 생성: 급여' as step, (get_or_create_contract('c2000000-0000-0000-0000-0000000000b1')->'terms'->>'pay_amount') as value;

-- 2) 멱등: 여러 번 호출해도 계약 1건.
select '② 계약 행 수(기대 1)' as step, count(*) as value
  from contracts where assignment_id='c2000000-0000-0000-0000-0000000000b1';

-- 3) 근로자 서명 → signed_worker_at 세팅, employer는 아직 미서명.
select '③ 근로자 서명 후 worker_signed' as step,
  (sign_contract('c2000000-0000-0000-0000-0000000000b1')->>'signed_worker_at') is not null as ok;
select '③ 아직 employer 미서명' as step,
  (get_or_create_contract('c2000000-0000-0000-0000-0000000000b1')->>'signed_employer_at') is null as ok;

-- 4) 업주 서명 → signed_employer_at 세팅.
set local request.jwt.claims = '{"sub":"c2000000-0000-0000-0000-0000000000e1","role":"authenticated"}';
select '④ 업주 서명 후 employer_signed' as step,
  (sign_contract('c2000000-0000-0000-0000-0000000000b1')->>'signed_employer_at') is not null as ok;

-- 5) 최종: 양측 서명 완료.
select '⑤ worker_signed & employer_signed' as step,
  ((get_or_create_contract('c2000000-0000-0000-0000-0000000000b1')->>'signed_worker_at') is not null
   and (get_or_create_contract('c2000000-0000-0000-0000-0000000000b1')->>'signed_employer_at') is not null) as ok;

-- 6) 비당사자는 조회/서명 차단.
set local request.jwt.claims = '{"sub":"c2000000-0000-0000-0000-0000000000c3","role":"authenticated"}';
do $$ begin
  perform get_or_create_contract('c2000000-0000-0000-0000-0000000000b1');
  raise notice '⑥ FAIL: 비당사자 조회 통과됨';
exception when others then
  raise notice '⑥ OK: 비당사자 조회 차단 (%)', sqlerrm;
end $$;

rollback;
