-- 안전 번들 E2E (트랜잭션 후 롤백) — 인앱 채팅 + 원터치 SOS.
-- 검증: 당사자만 send_message/열람, 외부인 차단(RLS), trigger_sos 기록 + 상대 열람.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;  -- 셋업용 FK/트리거 비활성

-- 참여자: 업주 · 근로자(배정 당사자) · 외부인(비당사자)
insert into profiles (id, role, display_name) values
  ('c1000000-0000-0000-0000-0000000000e1','employer','사장'),
  ('c1000000-0000-0000-0000-0000000000d1','worker','workerA'),
  ('c1000000-0000-0000-0000-0000000000c3','worker','outsiderC');

insert into employer_profiles (profile_id, business_name) values
  ('c1000000-0000-0000-0000-0000000000e1','강남카페');
insert into worker_profiles (profile_id, is_available, identity_verified_at) values
  ('c1000000-0000-0000-0000-0000000000d1', true, now()),
  ('c1000000-0000-0000-0000-0000000000c3', true, now());

insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount) values
  ('c1000000-0000-0000-0000-0000000000a1',
   'c1000000-0000-0000-0000-0000000000e1','강남 카페 홀 대타',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '2 hours', now()+interval '8 hours', 95000, 1);

insert into assignments (id, request_id, worker_id, status) values
  ('c1000000-0000-0000-0000-0000000000b1',
   'c1000000-0000-0000-0000-0000000000a1',
   'c1000000-0000-0000-0000-0000000000d1','confirmed');

set local session_replication_role = origin;  -- 이후 FK/RLS 정상 동작

-- 1) 근로자가 메시지 전송 (SECURITY DEFINER, auth.uid는 jwt로 주입)
set local request.jwt.claims = '{"sub":"c1000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
select '① 근로자 send_message id' as step, send_message('c1000000-0000-0000-0000-0000000000b1','안녕하세요, 곧 도착합니다') is not null as ok;

-- 2) 업주가 답장
set local request.jwt.claims = '{"sub":"c1000000-0000-0000-0000-0000000000e1","role":"authenticated"}';
select '② 업주 send_message id' as step, send_message('c1000000-0000-0000-0000-0000000000b1','네, 정문에서 뵐게요') is not null as ok;

-- 3) RLS: 당사자(업주)는 두 메시지 모두 열람 (기대 2)
set local role authenticated;
set local request.jwt.claims = '{"sub":"c1000000-0000-0000-0000-0000000000e1","role":"authenticated"}';
select '③ 업주가 읽는 메시지 수(기대 2)' as step, count(*) as value
  from messages where assignment_id='c1000000-0000-0000-0000-0000000000b1';

-- 4) RLS: 외부인은 열람 불가 (기대 0)
set local request.jwt.claims = '{"sub":"c1000000-0000-0000-0000-0000000000c3","role":"authenticated"}';
select '④ 외부인이 읽는 메시지 수(기대 0)' as step, count(*) as value
  from messages where assignment_id='c1000000-0000-0000-0000-0000000000b1';
reset role;

-- 5) SOS: 근로자가 GPS와 함께 발동
set local request.jwt.claims = '{"sub":"c1000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
select '⑤ trigger_sos id' as step, trigger_sos('c1000000-0000-0000-0000-0000000000b1', 37.4979, 127.0276, '위급 상황') is not null as ok;

-- 6) RLS: 상대 당사자(업주)가 SOS를 실시간 확인 (기대 1)
set local role authenticated;
set local request.jwt.claims = '{"sub":"c1000000-0000-0000-0000-0000000000e1","role":"authenticated"}';
select '⑥ 업주가 보는 open SOS 수(기대 1)' as step, count(*) as value
  from sos_alerts where assignment_id='c1000000-0000-0000-0000-0000000000b1' and status='open';
reset role;

-- 7) 비당사자 전송 차단 (예외 발생 기대)
set local request.jwt.claims = '{"sub":"c1000000-0000-0000-0000-0000000000c3","role":"authenticated"}';
do $$ begin
  perform send_message('c1000000-0000-0000-0000-0000000000b1','침입 메시지');
  raise notice '⑦ FAIL: 비당사자 전송이 통과됨';
exception when others then
  raise notice '⑦ OK: 비당사자 전송 차단 (%)', sqlerrm;
end $$;

rollback;
