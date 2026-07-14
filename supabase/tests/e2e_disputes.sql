-- 분쟁 플로우 E2E (트랜잭션 후 롤백). 실제 auth.uid() 컨텍스트로 open/evidence/조회 검증.
-- 시나리오: employer E ↔ workerA 배정. workerB 는 비당사자.
--   ① workerA 가 분쟁 open → status=open, 증거 1건, i_opened=true, SLA ~72h
--   ② employer E 가 증거 추가 → 증거 2건
--   ③ 가드: 중복 open / 공백 사유 / 비당사자 open / 비당사자 증거 / 공백 증거 / 해소후 증거(not_open)
\set ON_ERROR_STOP on
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('de000000-0000-0000-0000-0000000000e1','employer','사장E'),
  ('de000000-0000-0000-0000-0000000000a1','worker','workerA'),
  ('de000000-0000-0000-0000-0000000000b1','worker','workerB');

insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount) values
  ('de000000-0000-0000-0000-0000000000f1','de000000-0000-0000-0000-0000000000e1','카페 대타',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()-interval '6 hours', now()-interval '1 hours', 95000, 1);

insert into assignments (id, request_id, worker_id, status) values
  ('de000000-0000-0000-0000-000000000a51','de000000-0000-0000-0000-0000000000f1',
   'de000000-0000-0000-0000-0000000000a1','no_show');

-- ── workerA 로그인 ──
set local request.jwt.claims = '{"sub":"de000000-0000-0000-0000-0000000000a1","role":"authenticated"}';

-- ① 분쟁 open
select '① open_dispute' as step, open_dispute('de000000-0000-0000-0000-000000000a51','no_show','저는 정상 출근했는데 노쇼 처리됐어요') as value;

do $$
declare d jsonb;
begin
  select dispute_for_assignment('de000000-0000-0000-0000-000000000a51') into d;
  if d is null then raise exception 'FAIL: 조회 null'; end if;
  if d->>'status' <> 'open' then raise exception 'FAIL: status != open'; end if;
  if (d->>'i_opened')::boolean is not true then raise exception 'FAIL: i_opened != true'; end if;
  if jsonb_array_length(d->'evidence') <> 1 then raise exception 'FAIL: 증거 1건 아님'; end if;
  if d->>'sla_deadline' is null then raise exception 'FAIL: SLA 미설정'; end if;
  raise notice 'PASS ①: open + 첫 증거 + SLA';
end $$;

-- ② 상대 당사자(업주)가 증거 추가
set local request.jwt.claims = '{"sub":"de000000-0000-0000-0000-0000000000e1","role":"authenticated"}';
do $$
declare d jsonb; did uuid;
begin
  select (dispute_for_assignment('de000000-0000-0000-0000-000000000a51')->>'id')::uuid into did;
  perform add_dispute_evidence(did, '체크인 GPS 기록이 없습니다');
  select dispute_for_assignment('de000000-0000-0000-0000-000000000a51') into d;
  if jsonb_array_length(d->'evidence') <> 2 then raise exception 'FAIL: 증거 2건 아님(%)', jsonb_array_length(d->'evidence'); end if;
  if (d->>'i_opened')::boolean is not false then raise exception 'FAIL: 업주 i_opened != false'; end if;
  raise notice 'PASS ②: 상대 증거 추가';
end $$;

-- ③-a 중복 open (workerA)
set local request.jwt.claims = '{"sub":"de000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
do $$ declare ok boolean := false; begin
  begin perform open_dispute('de000000-0000-0000-0000-000000000a51','x','또 신고'); exception when others then ok := true; end;
  if not ok then raise exception 'FAIL: 중복 open 허용됨'; end if; raise notice 'PASS ③-a: 중복 open 거부';
end $$;

-- ③-b 공백 사유
do $$ declare ok boolean := false; begin
  begin perform open_dispute('de000000-0000-0000-0000-000000000a51','x','   '); exception when others then ok := true; end;
  if not ok then raise exception 'FAIL: 공백 사유 허용됨'; end if; raise notice 'PASS ③-b: 공백 사유 거부';
end $$;

-- ③-c 비당사자 open (workerB)
set local request.jwt.claims = '{"sub":"de000000-0000-0000-0000-0000000000b1","role":"authenticated"}';
do $$ declare ok boolean := false; begin
  begin perform open_dispute('de000000-0000-0000-0000-000000000a51','x','남의 배정'); exception when others then ok := true; end;
  if not ok then raise exception 'FAIL: 비당사자 open 허용됨'; end if; raise notice 'PASS ③-c: 비당사자 open 거부';
end $$;

-- ③-d 비당사자 증거
do $$ declare ok boolean := false; did uuid; begin
  -- workerB 는 조회도 안 되므로 id 를 직접 얻는다(테스트 목적).
  select id into did from disputes where assignment_id = 'de000000-0000-0000-0000-000000000a51' and status='open';
  begin perform add_dispute_evidence(did, '끼어들기'); exception when others then ok := true; end;
  if not ok then raise exception 'FAIL: 비당사자 증거 허용됨'; end if; raise notice 'PASS ③-d: 비당사자 증거 거부';
end $$;

-- ③-e 공백 증거 (workerA)
set local request.jwt.claims = '{"sub":"de000000-0000-0000-0000-0000000000a1","role":"authenticated"}';
do $$ declare ok boolean := false; did uuid; begin
  select (dispute_for_assignment('de000000-0000-0000-0000-000000000a51')->>'id')::uuid into did;
  begin perform add_dispute_evidence(did, '  '); exception when others then ok := true; end;
  if not ok then raise exception 'FAIL: 공백 증거 허용됨'; end if; raise notice 'PASS ③-e: 공백 증거 거부';
end $$;

-- ③-f 해소된 분쟁에 증거 (운영자가 resolved 처리했다고 가정)
set local session_replication_role = replica;
update disputes set status='resolved', resolution='증거불충분 종결' where assignment_id='de000000-0000-0000-0000-000000000a51';
do $$ declare ok boolean := false; did uuid; begin
  select id into did from disputes where assignment_id='de000000-0000-0000-0000-000000000a51';
  begin perform add_dispute_evidence(did, '종결후 추가시도'); exception when others then ok := true; end;
  if not ok then raise exception 'FAIL: 해소된 분쟁에 증거 허용됨'; end if; raise notice 'PASS ③-f: 해소후 증거 거부(not_open)';
end $$;

select '✅ 분쟁 E2E 전부 통과' as result;
rollback;
