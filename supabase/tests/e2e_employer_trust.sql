-- 업주 신뢰 뱃지 E2E (트랜잭션 후 롤백). 대상: 0033_employer_trust_badge.sql.
-- 검증: 제안받은 근로자는 사업장 인증여부를 조회 · 인증/미인증 정확 · 제안 없는
--       요청은 미노출(정보 차단) · 배정만 있어도 조회 가능.
-- UUID 프리픽스 e6.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('e6000000-0000-0000-0000-0000000000e1','employer','인증사장'),
  ('e6000000-0000-0000-0000-0000000000e2','employer','미인증사장'),
  ('e6000000-0000-0000-0000-0000000000d1','worker','근로자'),
  ('e6000000-0000-0000-0000-0000000000d9','worker','무관근로자');
insert into employer_profiles (profile_id, business_name, biz_verified) values
  ('e6000000-0000-0000-0000-0000000000e1','인증카페', true),
  ('e6000000-0000-0000-0000-0000000000e2','미인증카페', false);
insert into worker_profiles (profile_id, is_available, identity_verified_at) values
  ('e6000000-0000-0000-0000-0000000000d1', true, now()),
  ('e6000000-0000-0000-0000-0000000000d9', true, now());

-- 요청1(인증사장) → 근로자d1에 제안 / 요청2(미인증사장) → d1에 제안 / 요청3(인증사장) → d1 제안 없음
insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount, status) values
  ('e6000000-0000-0000-0000-00000000a001','e6000000-0000-0000-0000-0000000000e1','요청1',
   st_setsrid(st_makepoint(127.0,37.5),4326)::geography, now()+interval '3 hours', now()+interval '9 hours', 90000,1,'matching'),
  ('e6000000-0000-0000-0000-00000000a002','e6000000-0000-0000-0000-0000000000e2','요청2',
   st_setsrid(st_makepoint(127.0,37.5),4326)::geography, now()+interval '3 hours', now()+interval '9 hours', 90000,1,'matching'),
  ('e6000000-0000-0000-0000-00000000a003','e6000000-0000-0000-0000-0000000000e1','요청3',
   st_setsrid(st_makepoint(127.0,37.5),4326)::geography, now()+interval '3 hours', now()+interval '9 hours', 90000,1,'matching');
insert into match_offers (id, request_id, worker_id, rank, score, status, expires_at) values
  ('e6000000-0000-0000-0000-00000000f001','e6000000-0000-0000-0000-00000000a001','e6000000-0000-0000-0000-0000000000d1',1,0.9,'offered',now()+interval '60 seconds'),
  ('e6000000-0000-0000-0000-00000000f002','e6000000-0000-0000-0000-00000000a002','e6000000-0000-0000-0000-0000000000d1',1,0.9,'offered',now()+interval '60 seconds');

-- 근로자 d1 컨텍스트
set local request.jwt.claims = '{"sub":"e6000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
do $$
declare v_verified boolean; v_name text; v_cnt int;
begin
  -- ① 인증사장 요청 → employer_verified true + 상호
  select employer_verified, business_name into v_verified, v_name
    from employer_trust_for_requests(array['e6000000-0000-0000-0000-00000000a001']::uuid[]);
  if not v_verified or v_name <> '인증카페' then
    raise exception 'FAIL ①: 인증사장 조회 오류(verified=% name=%)', v_verified, v_name; end if;

  -- ② 미인증사장 요청 → false
  select employer_verified into v_verified
    from employer_trust_for_requests(array['e6000000-0000-0000-0000-00000000a002']::uuid[]);
  if v_verified then raise exception 'FAIL ②: 미인증인데 verified=true'; end if;

  -- ③ 제안 없는 요청3 → 미노출(0행)
  select count(*) into v_cnt
    from employer_trust_for_requests(array['e6000000-0000-0000-0000-00000000a003']::uuid[]);
  if v_cnt <> 0 then raise exception 'FAIL ③: 제안 없는 요청이 노출됨(%행)', v_cnt; end if;

  -- ④ 여러 개 한 번에(제안받은 2건만 반환)
  select count(*) into v_cnt from employer_trust_for_requests(
    array['e6000000-0000-0000-0000-00000000a001','e6000000-0000-0000-0000-00000000a002',
          'e6000000-0000-0000-0000-00000000a003']::uuid[]);
  if v_cnt <> 2 then raise exception 'FAIL ④: 배치 조회가 2건이 아님(%행)', v_cnt; end if;
  raise notice 'PASS ①②③④: 제안받은 요청만·인증여부 정확·정보차단·배치조회';
end $$;

-- ⑤ 무관 근로자(제안 없음)는 아무것도 못 봄
set local request.jwt.claims = '{"sub":"e6000000-0000-0000-0000-0000000000d9","role":"authenticated"}';
do $$ declare v_cnt int; begin
  select count(*) into v_cnt from employer_trust_for_requests(
    array['e6000000-0000-0000-0000-00000000a001','e6000000-0000-0000-0000-00000000a002']::uuid[]);
  if v_cnt <> 0 then raise exception 'FAIL ⑤: 무관 근로자가 조회됨(%행)', v_cnt; end if;
  raise notice 'PASS ⑤: 제안 없는 근로자는 정보 미노출';
end $$;

-- ⑥ 배정만 있어도(제안 만료 후 확정) 조회 가능
insert into assignments (id, request_id, worker_id, status) values
  ('e6000000-0000-0000-0000-00000000b001','e6000000-0000-0000-0000-00000000a003','e6000000-0000-0000-0000-0000000000d9','confirmed');
do $$ declare v_verified boolean; begin
  select employer_verified into v_verified
    from employer_trust_for_requests(array['e6000000-0000-0000-0000-00000000a003']::uuid[]);
  if not v_verified then raise exception 'FAIL ⑥: 배정 근로자가 인증사장 요청을 못 봄'; end if;
  raise notice 'PASS ⑥: 배정만 있어도 조회 가능';
end $$;

rollback;
