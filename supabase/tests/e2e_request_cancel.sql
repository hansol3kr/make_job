-- 요청 취소 E2E (트랜잭션 후 롤백).
-- 검증: matching 무료취소(오퍼취소) · 확정 후 티어 보상수수료 · 타인 요청 차단.
-- 추가(⑧~⑫): mid/far 티어 수수료 · 부분충원 취소 · headcount 2 인당 합산 · 에스크로 환불.
-- 티어 기대값은 platform_settings.cancel_fee_tiers 실값으로 산출(하드코딩 금지).
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

-- =====================================================================
-- ⑧~⑫ 확장 케이스 — 티어별 수수료·부분충원·다인원·에스크로 환불
-- (replica 모드는 set local로 트랜잭션 내내 유효 — 추가 시드 가능)
-- =====================================================================

-- 추가 근로자 d2 (부분충원·다인원용)
insert into profiles (id, role, display_name) values
  ('c8000000-0000-0000-0000-0000000000d2','worker','근로자2');
insert into worker_profiles (profile_id, is_available, identity_verified_at) values
  ('c8000000-0000-0000-0000-0000000000d2', true, now());

-- 요청3: mid 티어(+10h, 2h≤x<24h). pay 33333 → 30% = 9999.9 → round 경계를 밟게 한다.
-- 요청4: far 티어(+48h, ≥24h) → 수수료 0 기대.
-- 요청5: 부분충원(headcount 2, confirmed 1 + offered 1), near 티어(+1h).
-- 요청6: headcount 2·확정 2명, mid 티어(+10h). pay 55555 → 인당 16666.5 → round.
-- 요청7: 확정 1명 + escrowed 결제 시드, near 티어(+1h).
insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount, status) values
  ('c8000000-0000-0000-0000-0000000000a3','c8000000-0000-0000-0000-0000000000e1','요청3-mid',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '10 hours', now()+interval '16 hours', 33333, 1, 'confirmed'),
  ('c8000000-0000-0000-0000-0000000000a4','c8000000-0000-0000-0000-0000000000e1','요청4-far',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '48 hours', now()+interval '54 hours', 100000, 1, 'confirmed'),
  ('c8000000-0000-0000-0000-0000000000a5','c8000000-0000-0000-0000-0000000000e1','요청5-부분충원',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '1 hour', now()+interval '7 hours', 100000, 2, 'matching'),
  ('c8000000-0000-0000-0000-0000000000a6','c8000000-0000-0000-0000-0000000000e1','요청6-2인확정',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '10 hours', now()+interval '16 hours', 55555, 2, 'confirmed'),
  ('c8000000-0000-0000-0000-0000000000a7','c8000000-0000-0000-0000-0000000000e1','요청7-에스크로',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '1 hour', now()+interval '7 hours', 100000, 1, 'confirmed');
insert into assignments (id, request_id, worker_id, status) values
  ('c8000000-0000-0000-0000-0000000000b3','c8000000-0000-0000-0000-0000000000a3',
   'c8000000-0000-0000-0000-0000000000d1','confirmed'),
  ('c8000000-0000-0000-0000-0000000000b4','c8000000-0000-0000-0000-0000000000a4',
   'c8000000-0000-0000-0000-0000000000d1','confirmed'),
  ('c8000000-0000-0000-0000-0000000000b5','c8000000-0000-0000-0000-0000000000a5',
   'c8000000-0000-0000-0000-0000000000d1','confirmed'),
  ('c8000000-0000-0000-0000-0000000000b6','c8000000-0000-0000-0000-0000000000a6',
   'c8000000-0000-0000-0000-0000000000d1','confirmed'),
  ('c8000000-0000-0000-0000-0000000000b7','c8000000-0000-0000-0000-0000000000a6',
   'c8000000-0000-0000-0000-0000000000d2','confirmed'),
  ('c8000000-0000-0000-0000-0000000000b8','c8000000-0000-0000-0000-0000000000a7',
   'c8000000-0000-0000-0000-0000000000d1','confirmed');
-- 요청5의 미확정 오퍼(d2) — 취소 시 offered → cancelled 기대
insert into match_offers (id, request_id, worker_id, rank, score, status, expires_at) values
  ('c8000000-0000-0000-0000-0000000000f2','c8000000-0000-0000-0000-0000000000a5',
   'c8000000-0000-0000-0000-0000000000d2', 1, 0.8, 'offered', now()+interval '60 seconds');
-- 요청7의 에스크로 예치 시드(0017 escrow_payment 결과와 동형)
insert into payments (id, assignment_id, pg_provider, amount, commission, status, authorized_at, escrowed_at) values
  ('c8000000-0000-0000-0000-0000000000c1','c8000000-0000-0000-0000-0000000000b8',
   'escrow', 100000, 4000, 'escrowed', now(), now());

set local request.jwt.claims = '{"sub":"c8000000-0000-0000-0000-0000000000e1","role":"authenticated"}';

-- ⑧ mid 티어(2h≤x<24h): fee_pct=mid_pct, fee_total=round(pay*mid_pct/100), 페널티 1건 동일 금액
do $$ declare
  t jsonb; pct int; v_pay int; exp_fee int; res jsonb; pen_cnt int; pen_amt int;
begin
  t := coalesce((select value from platform_settings where key = 'cancel_fee_tiers'),
                '{"far_h":24,"near_h":2,"far_pct":0,"mid_pct":30,"near_pct":50}'::jsonb);  -- RPC와 동일 fallback
  pct := (t->>'mid_pct')::int;
  select pay_amount into v_pay from job_requests where id = 'c8000000-0000-0000-0000-0000000000a3';
  exp_fee := round(v_pay::numeric * pct / 100.0)::int;  -- 0022와 동일 수식

  res := cancel_job_request('c8000000-0000-0000-0000-0000000000a3');
  if (res->>'fee_pct')::int <> pct then
    raise exception 'FAIL ⑧: fee_pct 기대 %(mid), 실제 %', pct, res->>'fee_pct'; end if;
  if (res->>'fee_total')::int <> exp_fee then
    raise exception 'FAIL ⑧: fee_total 기대 %, 실제 %', exp_fee, res->>'fee_total'; end if;
  if (res->>'confirmed_cancelled')::int <> 1 then
    raise exception 'FAIL ⑧: confirmed_cancelled 기대 1, 실제 %', res->>'confirmed_cancelled'; end if;
  if (select status from assignments where id='c8000000-0000-0000-0000-0000000000b3') <> 'cancelled_employer' then
    raise exception 'FAIL ⑧: 배정이 cancelled_employer로 전이되지 않음'; end if;
  select count(*), coalesce(sum(amount),0) into pen_cnt, pen_amt
    from penalties where assignment_id='c8000000-0000-0000-0000-0000000000b3' and kind='employer_cancel';
  if pen_cnt <> (case when exp_fee > 0 then 1 else 0 end) then
    raise exception 'FAIL ⑧: 페널티 건수 기대 %, 실제 %', (case when exp_fee > 0 then 1 else 0 end), pen_cnt; end if;
  if exp_fee > 0 and pen_amt <> exp_fee then
    raise exception 'FAIL ⑧: 페널티 금액 기대 %, 실제 %', exp_fee, pen_amt; end if;
  raise notice 'PASS ⑧: mid 티어(pct %) → 수수료 % + 페널티 %건', pct, exp_fee, pen_cnt;
end $$;

-- ⑨ far 티어(≥24h): fee_pct=far_pct(기본 0) → fee_total 0·페널티 insert 없음
do $$ declare
  t jsonb; pct int; v_pay int; exp_fee int; res jsonb; pen_cnt int;
begin
  t := coalesce((select value from platform_settings where key = 'cancel_fee_tiers'),
                '{"far_h":24,"near_h":2,"far_pct":0,"mid_pct":30,"near_pct":50}'::jsonb);
  pct := (t->>'far_pct')::int;
  select pay_amount into v_pay from job_requests where id = 'c8000000-0000-0000-0000-0000000000a4';
  exp_fee := round(v_pay::numeric * pct / 100.0)::int;

  res := cancel_job_request('c8000000-0000-0000-0000-0000000000a4');
  if (res->>'fee_pct')::int <> pct then
    raise exception 'FAIL ⑨: fee_pct 기대 %(far), 실제 %', pct, res->>'fee_pct'; end if;
  if (res->>'fee_total')::int <> exp_fee then
    raise exception 'FAIL ⑨: fee_total 기대 %, 실제 %', exp_fee, res->>'fee_total'; end if;
  select count(*) into pen_cnt
    from penalties where assignment_id='c8000000-0000-0000-0000-0000000000b4';
  if pen_cnt <> (case when exp_fee > 0 then 1 else 0 end) then
    raise exception 'FAIL ⑨: far 티어 페널티 건수 기대 %, 실제 %', (case when exp_fee > 0 then 1 else 0 end), pen_cnt; end if;
  if (select status from assignments where id='c8000000-0000-0000-0000-0000000000b4') <> 'cancelled_employer' then
    raise exception 'FAIL ⑨: far 티어도 배정은 cancelled_employer여야 함'; end if;
  if (select status from job_requests where id='c8000000-0000-0000-0000-0000000000a4') <> 'cancelled' then
    raise exception 'FAIL ⑨: 요청이 cancelled로 전이되지 않음'; end if;
  raise notice 'PASS ⑨: far 티어(pct %) → 수수료 % (기본 시드면 0·페널티 없음)', pct, exp_fee;
end $$;

-- ⑩ 부분충원(confirmed 1 + offered 1) 취소: 확정분(1인)만 과금 + 오퍼는 cancelled
do $$ declare
  t jsonb; pct int; v_pay int; exp_fee int; res jsonb;
begin
  t := coalesce((select value from platform_settings where key = 'cancel_fee_tiers'),
                '{"far_h":24,"near_h":2,"far_pct":0,"mid_pct":30,"near_pct":50}'::jsonb);
  pct := (t->>'near_pct')::int;  -- +1h → near 티어
  select pay_amount into v_pay from job_requests where id = 'c8000000-0000-0000-0000-0000000000a5';
  exp_fee := round(v_pay::numeric * pct / 100.0)::int;

  res := cancel_job_request('c8000000-0000-0000-0000-0000000000a5');
  if (res->>'confirmed_cancelled')::int <> 1 then
    raise exception 'FAIL ⑩: 확정 취소 수 기대 1(offered는 미포함), 실제 %', res->>'confirmed_cancelled'; end if;
  if (res->>'fee_total')::int <> exp_fee then
    raise exception 'FAIL ⑩: fee_total 기대 %(확정 1인분), 실제 %', exp_fee, res->>'fee_total'; end if;
  if (select status from assignments where id='c8000000-0000-0000-0000-0000000000b5') <> 'cancelled_employer' then
    raise exception 'FAIL ⑩: 확정 배정이 cancelled_employer로 전이되지 않음'; end if;
  if (select status from match_offers where id='c8000000-0000-0000-0000-0000000000f2') <> 'cancelled' then
    raise exception 'FAIL ⑩: offered 오퍼가 cancelled로 전이되지 않음'; end if;
  if exists (select 1 from penalties p join assignments a on a.id = p.assignment_id
              where a.request_id='c8000000-0000-0000-0000-0000000000a5'
                and a.id <> 'c8000000-0000-0000-0000-0000000000b5') then
    raise exception 'FAIL ⑩: 미확정 인원에 페널티가 기록됨'; end if;
  raise notice 'PASS ⑩: 부분충원 취소 — 확정 1인만 과금(%), 오퍼 cancelled', exp_fee;
end $$;

-- ⑪ headcount 2·확정 2명: fee_total=인당 합산(×2), 페널티 2건·합계 일치
do $$ declare
  t jsonb; pct int; v_pay int; per_fee int; exp_cnt int; res jsonb; pen_cnt int; pen_sum int;
begin
  t := coalesce((select value from platform_settings where key = 'cancel_fee_tiers'),
                '{"far_h":24,"near_h":2,"far_pct":0,"mid_pct":30,"near_pct":50}'::jsonb);
  pct := (t->>'mid_pct')::int;  -- +10h → mid 티어
  select pay_amount into v_pay from job_requests where id = 'c8000000-0000-0000-0000-0000000000a6';
  per_fee := round(v_pay::numeric * pct / 100.0)::int;
  exp_cnt := case when per_fee > 0 then 2 else 0 end;

  res := cancel_job_request('c8000000-0000-0000-0000-0000000000a6');
  if (res->>'confirmed_cancelled')::int <> 2 then
    raise exception 'FAIL ⑪: 확정 취소 수 기대 2, 실제 %', res->>'confirmed_cancelled'; end if;
  if (res->>'fee_total')::int <> per_fee * 2 then
    raise exception 'FAIL ⑪: fee_total 기대 %(인당 %×2), 실제 %', per_fee*2, per_fee, res->>'fee_total'; end if;
  select count(*), coalesce(sum(amount),0) into pen_cnt, pen_sum
    from penalties where assignment_id in ('c8000000-0000-0000-0000-0000000000b6',
                                           'c8000000-0000-0000-0000-0000000000b7');
  if pen_cnt <> exp_cnt then
    raise exception 'FAIL ⑪: 페널티 건수 기대 %, 실제 %', exp_cnt, pen_cnt; end if;
  if pen_sum <> per_fee * 2 then
    raise exception 'FAIL ⑪: 페널티 합계 기대 %, 실제 %', per_fee*2, pen_sum; end if;
  if (select count(*) from assignments
       where request_id='c8000000-0000-0000-0000-0000000000a6' and status='cancelled_employer') <> 2 then
    raise exception 'FAIL ⑪: 확정 2건 모두 cancelled_employer여야 함'; end if;
  raise notice 'PASS ⑪: 2인 확정 취소 — fee_total %(인당 %), 페널티 %건', per_fee*2, per_fee, pen_cnt;
end $$;

-- ⑫ escrowed 결제 보유 요청 취소 → payments escrowed → refunded 전이
do $$ begin
  perform cancel_job_request('c8000000-0000-0000-0000-0000000000a7');
  if (select status from payments where id='c8000000-0000-0000-0000-0000000000c1') <> 'refunded' then
    raise exception 'FAIL ⑫: 취소 후 escrowed 결제가 refunded로 전이되지 않음 (실제 %)',
      (select status from payments where id='c8000000-0000-0000-0000-0000000000c1');
  end if;
  if (select status from assignments where id='c8000000-0000-0000-0000-0000000000b8') <> 'cancelled_employer' then
    raise exception 'FAIL ⑫: 배정이 cancelled_employer로 전이되지 않음'; end if;
  raise notice 'PASS ⑫: 취소 시 에스크로 escrowed → refunded';
end $$;

rollback;
