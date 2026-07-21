-- 급여 정산 에스크로 E2E (트랜잭션 후 롤백).
-- 대상: 0017_payment_escrow.sql — escrow_payment / release_payment / refund_payment / payment_status.
-- 검증: ① 정상 예치 — 수수료 = round(pay_amount * commission_rate)::int.
--         rate는 platform_settings 실값을 읽어 RPC와 동일 수식으로 기대값 산출(하드코딩 금지).
--       ② 이중 예치 차단(payment_exists)
--       ③ 미완료(confirmed) 근무 지급 차단(work_not_completed) — 예치 자체는 확정 시점 선결제로 허용
--       ④ 완료 후 release → released 전이(released_at 기록)
--       ⑤ released 후 재지급/환불 차단(no_escrowed_payment)
--       ⑥ escrowed → refund 전이
--       ⑦ 비당사자 차단(not_your_assignment) + payment_status는 계약 당사자에게만 내용 반환
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;  -- 셋업용 FK/트리거 비활성

-- 참여자 (UUID 프리픽스 ce — 기존 테스트 파일들과 미충돌)
insert into profiles (id, role, display_name) values
  ('ce000000-0000-0000-0000-0000000000e1','employer','사장'),
  ('ce000000-0000-0000-0000-0000000000e2','employer','타사장'),
  ('ce000000-0000-0000-0000-0000000000d1','worker','근로자');
insert into employer_profiles (profile_id, business_name) values
  ('ce000000-0000-0000-0000-0000000000e1','카페'),
  ('ce000000-0000-0000-0000-0000000000e2','타카페');
insert into worker_profiles (profile_id, is_available, identity_verified_at) values
  ('ce000000-0000-0000-0000-0000000000d1', true, now());

-- 요청/배정: a1=완료 근무(b1 completed → release 경로) / a2=확정만(b2 confirmed → refund 경로).
-- pay_amount 100333: rate 0.04 기준 4013.32 → round 경계를 실제로 밟게 한다.
insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount, status) values
  ('ce000000-0000-0000-0000-0000000000a1','ce000000-0000-0000-0000-0000000000e1','완료건',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()-interval '9 hours', now()-interval '1 hour', 100333, 1, 'completed'),
  ('ce000000-0000-0000-0000-0000000000a2','ce000000-0000-0000-0000-0000000000e1','확정건',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '3 hours', now()+interval '9 hours', 99991, 1, 'confirmed');
insert into assignments (id, request_id, worker_id, status, check_in_at, check_out_at) values
  ('ce000000-0000-0000-0000-0000000000b1','ce000000-0000-0000-0000-0000000000a1',
   'ce000000-0000-0000-0000-0000000000d1','completed', now()-interval '9 hours', now()-interval '1 hour'),
  ('ce000000-0000-0000-0000-0000000000b2','ce000000-0000-0000-0000-0000000000a2',
   'ce000000-0000-0000-0000-0000000000d1','confirmed', null, null);

set local request.jwt.claims = '{"sub":"ce000000-0000-0000-0000-0000000000e1","role":"authenticated"}';

-- ① 정상 예치: 반환 uuid의 payments 행 — amount=pay_amount, commission=round(pay*rate),
--    status=escrowed, authorized_at/escrowed_at 기록.
do $$ declare
  v_rate numeric; v_pay int; v_exp int; v_id uuid; p payments;
begin
  select (value)::numeric into v_rate from platform_settings where key = 'commission_rate';
  if v_rate is null then
    raise notice 'WARN ①: commission_rate 미시드 — RPC와 동일하게 coalesce(0) 기준 검증';
  end if;
  select pay_amount into v_pay from job_requests where id = 'ce000000-0000-0000-0000-0000000000a1';
  v_exp := round(v_pay * coalesce(v_rate, 0))::int;  -- 0017 escrow_payment와 동일 수식

  v_id := escrow_payment('ce000000-0000-0000-0000-0000000000b1', 'tx-test-1');
  select * into p from payments where id = v_id;
  if p.id is null then raise exception 'FAIL ①: 반환 uuid의 payments 행 없음'; end if;
  if p.assignment_id <> 'ce000000-0000-0000-0000-0000000000b1' then
    raise exception 'FAIL ①: assignment_id 불일치'; end if;
  if p.amount <> v_pay then
    raise exception 'FAIL ①: amount 기대 %, 실제 %', v_pay, p.amount; end if;
  if p.commission <> v_exp then
    raise exception 'FAIL ①: commission 기대 round(%×%)=%, 실제 %', v_pay, v_rate, v_exp, p.commission; end if;
  if p.status <> 'escrowed' then
    raise exception 'FAIL ①: status 기대 escrowed, 실제 %', p.status; end if;
  if p.authorized_at is null or p.escrowed_at is null then
    raise exception 'FAIL ①: authorized_at/escrowed_at 미기록'; end if;
  raise notice 'PASS ①: 예치 성공 — amount %, commission %(rate %)', v_pay, p.commission, v_rate;
end $$;

-- ② 같은 배정에 재예치 → payment_exists
do $$ declare ok boolean := false; begin
  begin
    perform escrow_payment('ce000000-0000-0000-0000-0000000000b1', 'tx-test-dup');
  exception when others then
    ok := (sqlerrm like '%payment_exists%');
    if not ok then raise exception 'FAIL ②: 기대 payment_exists, 실제 %', sqlerrm; end if;
  end;
  if not ok then raise exception 'FAIL ②: 이중 예치가 차단되지 않음'; end if;
  raise notice 'PASS ②: 이중 예치 차단(payment_exists)';
end $$;

-- ③ 미완료(confirmed) 배정: 예치는 허용(선결제 설계), release는 work_not_completed
do $$ declare ok boolean := false; begin
  perform escrow_payment('ce000000-0000-0000-0000-0000000000b2', 'tx-test-2');
  if (select status from payments
       where assignment_id = 'ce000000-0000-0000-0000-0000000000b2') <> 'escrowed' then
    raise exception 'FAIL ③: confirmed 배정 선예치가 escrowed가 아님';
  end if;
  begin
    perform release_payment('ce000000-0000-0000-0000-0000000000b2');
  exception when others then
    ok := (sqlerrm like '%work_not_completed%');
    if not ok then raise exception 'FAIL ③: 기대 work_not_completed, 실제 %', sqlerrm; end if;
  end;
  if not ok then raise exception 'FAIL ③: 미완료 근무 지급이 차단되지 않음'; end if;
  raise notice 'PASS ③: confirmed 선예치 허용 + 미완료 지급 차단(work_not_completed)';
end $$;

-- ④ 완료 배정 release → released 전이 + released_at 기록
do $$ declare p payments; begin
  perform release_payment('ce000000-0000-0000-0000-0000000000b1');
  select * into p from payments where assignment_id = 'ce000000-0000-0000-0000-0000000000b1';
  if p.status <> 'released' then
    raise exception 'FAIL ④: status 기대 released, 실제 %', p.status; end if;
  if p.released_at is null then raise exception 'FAIL ④: released_at 미기록'; end if;
  raise notice 'PASS ④: 완료 근무 release → released';
end $$;

-- ⑤ released 후 재지급/환불 → 둘 다 no_escrowed_payment
do $$ declare ok boolean := false; begin
  begin
    perform release_payment('ce000000-0000-0000-0000-0000000000b1');
  exception when others then
    ok := (sqlerrm like '%no_escrowed_payment%');
    if not ok then raise exception 'FAIL ⑤: 재지급 기대 no_escrowed_payment, 실제 %', sqlerrm; end if;
  end;
  if not ok then raise exception 'FAIL ⑤: released 후 재지급이 차단되지 않음'; end if;

  ok := false;
  begin
    perform refund_payment('ce000000-0000-0000-0000-0000000000b1', '취소');
  exception when others then
    ok := (sqlerrm like '%no_escrowed_payment%');
    if not ok then raise exception 'FAIL ⑤: 환불 기대 no_escrowed_payment, 실제 %', sqlerrm; end if;
  end;
  if not ok then raise exception 'FAIL ⑤: released 후 환불이 차단되지 않음'; end if;
  raise notice 'PASS ⑤: released 후 재지급/환불 차단(no_escrowed_payment)';
end $$;

-- ⑥ escrowed(b2) refund → refunded 전이
do $$ begin
  perform refund_payment('ce000000-0000-0000-0000-0000000000b2', '업주 취소');
  if (select status from payments
       where assignment_id = 'ce000000-0000-0000-0000-0000000000b2') <> 'refunded' then
    raise exception 'FAIL ⑥: refund 후 status가 refunded가 아님';
  end if;
  raise notice 'PASS ⑥: escrowed → refunded 전이';
end $$;

-- ⑦-1 타사장(비소유): 예치/지급/환불 전부 not_your_assignment
--     (소유 검증이 payment_exists보다 먼저 — b1에 payments가 있어도 not_your_assignment여야 한다)
set local request.jwt.claims = '{"sub":"ce000000-0000-0000-0000-0000000000e2","role":"authenticated"}';
do $$ declare ok boolean; begin
  ok := false;
  begin
    perform escrow_payment('ce000000-0000-0000-0000-0000000000b1', 'tx-intrude');
  exception when others then
    ok := (sqlerrm like '%not_your_assignment%');
    if not ok then raise exception 'FAIL ⑦: 예치 기대 not_your_assignment, 실제 %', sqlerrm; end if;
  end;
  if not ok then raise exception 'FAIL ⑦: 타인 배정 예치가 차단되지 않음'; end if;

  ok := false;
  begin
    perform release_payment('ce000000-0000-0000-0000-0000000000b1');
  exception when others then
    ok := (sqlerrm like '%not_your_assignment%');
    if not ok then raise exception 'FAIL ⑦: 지급 기대 not_your_assignment, 실제 %', sqlerrm; end if;
  end;
  if not ok then raise exception 'FAIL ⑦: 타인 배정 지급이 차단되지 않음'; end if;

  ok := false;
  begin
    perform refund_payment('ce000000-0000-0000-0000-0000000000b2', '침입');
  exception when others then
    ok := (sqlerrm like '%not_your_assignment%');
    if not ok then raise exception 'FAIL ⑦: 환불 기대 not_your_assignment, 실제 %', sqlerrm; end if;
  end;
  if not ok then raise exception 'FAIL ⑦: 타인 배정 환불이 차단되지 않음'; end if;

  -- 비당사자 payment_status → 빈 jsonb
  if payment_status('ce000000-0000-0000-0000-0000000000b1') <> '{}'::jsonb then
    raise exception 'FAIL ⑦: 비당사자 payment_status가 내용을 반환함';
  end if;
  raise notice 'PASS ⑦-1: 비소유자 예치/지급/환불 차단 + payment_status 빈 jsonb';
end $$;

-- ⑦-2 당사자 payment_status: 근로자(d1)와 업주(e1)는 내용 조회 가능
set local request.jwt.claims = '{"sub":"ce000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
do $$ declare j jsonb; begin
  j := payment_status('ce000000-0000-0000-0000-0000000000b1');
  if (j->>'status') is distinct from 'released' then
    raise exception 'FAIL ⑦: 근로자 payment_status 기대 released, 실제 %', j; end if;
  raise notice 'PASS ⑦-2a: 근로자 당사자 payment_status = released';
end $$;
set local request.jwt.claims = '{"sub":"ce000000-0000-0000-0000-0000000000e1","role":"authenticated"}';
do $$ declare j jsonb; begin
  j := payment_status('ce000000-0000-0000-0000-0000000000b2');
  if (j->>'status') is distinct from 'refunded' then
    raise exception 'FAIL ⑦: 업주 payment_status 기대 refunded, 실제 %', j; end if;
  raise notice 'PASS ⑦-2b: 업주 당사자 payment_status = refunded';
end $$;

-- (보너스) 존재하지 않는 배정 → assignment_not_found
do $$ declare ok boolean := false; begin
  begin
    perform escrow_payment('ce000000-0000-0000-0000-0000000000ff', null);
  exception when others then
    ok := (sqlerrm like '%assignment_not_found%');
    if not ok then raise exception 'FAIL: 기대 assignment_not_found, 실제 %', sqlerrm; end if;
  end;
  if not ok then raise exception 'FAIL: 없는 배정 예치가 차단되지 않음'; end if;
  raise notice 'PASS: 없는 배정 → assignment_not_found';
end $$;

rollback;
