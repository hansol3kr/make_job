-- run_match / nearby_candidates 엣지 E2E (트랜잭션 후 롤백).
-- 대상: 0020_ranking_reason.sql의 run_match 최종 정의 + 0010의 nearby_candidates.
-- 검증: ① 후보 0명 → 0 반환·status 전이 없음(open 유지)
--       ② identity_verified_at null 제외 ③ is_available=false 제외
--       ④ 시간대 겹치는 confirmed 배정 보유 근로자 제외(더블부킹 방지)
--       ⑤ requires_professional 요청 → professional_verified 근로자만
--       ⑥ 이미 오퍼받은 근로자는 재-run_match에서 중복 오퍼 제외
--       ⑦ min_reliability 필터(하한 30 차단 → 하한 0 해제 시 합류)
-- 좌표는 공해상 고립 지점 사용 — http_*.sh가 커밋해 둔 강남(127.0276,37.4979)
-- 잔류 근로자와의 간섭을 차단해 count assert를 결정적으로 만든다.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;  -- 셋업용 FK/트리거 비활성

-- 참여자 (UUID 프리픽스 cb — 기존 테스트 파일들과 미충돌)
insert into profiles (id, role, display_name) values
  ('cb000000-0000-0000-0000-0000000000e1','employer','사장'),
  ('cb000000-0000-0000-0000-0000000000d1','worker','정상'),
  ('cb000000-0000-0000-0000-0000000000d2','worker','미인증'),
  ('cb000000-0000-0000-0000-0000000000d3','worker','비가용'),
  ('cb000000-0000-0000-0000-0000000000d4','worker','더블부킹'),
  ('cb000000-0000-0000-0000-0000000000d5','worker','전문가'),
  ('cb000000-0000-0000-0000-0000000000d6','worker','저신뢰');
insert into employer_profiles (profile_id, business_name) values
  ('cb000000-0000-0000-0000-0000000000e1','카페');

-- 근로자 6명: 요청점(125.0000,34.0000) 반경 ~250m. 각자 "단 하나의 제외 사유"만
-- 갖게 구성해 어떤 필터가 작동했는지 모호하지 않게 한다.
insert into worker_profiles (profile_id, is_available, identity_verified_at,
                             professional_verified_at, current_geog, reliability_score) values
  ('cb000000-0000-0000-0000-0000000000d1', true,  now(), null,
   st_setsrid(st_makepoint(125.0010,34.0005),4326)::geography, 80),  -- 결격 없음
  ('cb000000-0000-0000-0000-0000000000d2', true,  null,  null,
   st_setsrid(st_makepoint(125.0012,34.0006),4326)::geography, 80),  -- ② identity 미인증
  ('cb000000-0000-0000-0000-0000000000d3', false, now(), null,
   st_setsrid(st_makepoint(125.0014,34.0007),4326)::geography, 80),  -- ③ 비가용
  ('cb000000-0000-0000-0000-0000000000d4', true,  now(), null,
   st_setsrid(st_makepoint(125.0016,34.0008),4326)::geography, 80),  -- ④ 확정배정 겹침(아래 a3)
  ('cb000000-0000-0000-0000-0000000000d5', true,  now(), now(),
   st_setsrid(st_makepoint(125.0018,34.0009),4326)::geography, 90),  -- ⑤ 전문인력(결격 없음)
  ('cb000000-0000-0000-0000-0000000000d6', true,  now(), null,
   st_setsrid(st_makepoint(125.0020,34.0010),4326)::geography, 20);  -- ⑦ 저신뢰(20)

-- 요청: a0=후보 전무 지점(동해 공해) / a1=본검증 / a2=전문요구 / a3=d4의 기존 확정건
insert into job_requests (id, employer_id, title, geog, start_at, end_at,
                          pay_amount, headcount, status) values
  ('cb000000-0000-0000-0000-0000000000a0','cb000000-0000-0000-0000-0000000000e1','후보없음',
   st_setsrid(st_makepoint(131.5000,37.3000),4326)::geography,
   now()+interval '3 hours', now()+interval '9 hours', 100000, 1, 'open'),
  ('cb000000-0000-0000-0000-0000000000a1','cb000000-0000-0000-0000-0000000000e1','본검증',
   st_setsrid(st_makepoint(125.0000,34.0000),4326)::geography,
   now()+interval '3 hours', now()+interval '9 hours', 100000, 3, 'open'),
  ('cb000000-0000-0000-0000-0000000000a2','cb000000-0000-0000-0000-0000000000e1','전문요구',
   st_setsrid(st_makepoint(125.0000,34.0000),4326)::geography,
   now()+interval '3 hours', now()+interval '9 hours', 200000, 1, 'open'),
  ('cb000000-0000-0000-0000-0000000000a3','cb000000-0000-0000-0000-0000000000e1','기존확정',
   st_setsrid(st_makepoint(125.0000,34.0000),4326)::geography,
   now()+interval '4 hours', now()+interval '8 hours', 100000, 1, 'confirmed');

-- d4: a1(+3h~+9h)과 시간대가 겹치는(+4h~+8h) confirmed 배정 보유 → 더블부킹 차단 대상
insert into assignments (id, request_id, worker_id, status) values
  ('cb000000-0000-0000-0000-0000000000f4','cb000000-0000-0000-0000-0000000000a3',
   'cb000000-0000-0000-0000-0000000000d4','confirmed');

-- ① 후보 0명 → 0 반환 + 전이 없음.
--    구현 명세(0020): v_count>0일 때만 open→matching 전이 → 0명이면 open 그대로.
do $$ declare v int; begin
  v := run_match('cb000000-0000-0000-0000-0000000000a0', 3000, 0, 10, 60, false);
  if v <> 0 then
    raise exception 'FAIL ①: 후보 0명인데 run_match가 % 반환', v;
  end if;
  if (select status from job_requests where id='cb000000-0000-0000-0000-0000000000a0') <> 'open' then
    raise exception 'FAIL ①: 후보 0명인데 status가 open에서 전이됨';
  end if;
  if exists (select 1 from match_offers where request_id='cb000000-0000-0000-0000-0000000000a0') then
    raise exception 'FAIL ①: 후보 0명인데 오퍼 행이 생성됨';
  end if;
  raise notice 'PASS ①: 후보 0명 → 0 반환 + open 유지 + 오퍼 0건';
end $$;

-- ②③④⑦(차단면): min_reliability=30, wave 넉넉히(10) → 포함은 d1·d5뿐이어야 한다.
--    제외 사유 — d2:미인증 / d3:비가용 / d4:더블부킹 / d6:신뢰 20<30.
do $$ declare
  v int;
  in_d1 boolean; in_d2 boolean; in_d3 boolean;
  in_d4 boolean; in_d5 boolean; in_d6 boolean;
begin
  v := run_match('cb000000-0000-0000-0000-0000000000a1', 3000, 30, 10, 60, false);
  select coalesce(bool_or(worker_id = 'cb000000-0000-0000-0000-0000000000d1'), false),
         coalesce(bool_or(worker_id = 'cb000000-0000-0000-0000-0000000000d2'), false),
         coalesce(bool_or(worker_id = 'cb000000-0000-0000-0000-0000000000d3'), false),
         coalesce(bool_or(worker_id = 'cb000000-0000-0000-0000-0000000000d4'), false),
         coalesce(bool_or(worker_id = 'cb000000-0000-0000-0000-0000000000d5'), false),
         coalesce(bool_or(worker_id = 'cb000000-0000-0000-0000-0000000000d6'), false)
    into in_d1, in_d2, in_d3, in_d4, in_d5, in_d6
    from match_offers where request_id = 'cb000000-0000-0000-0000-0000000000a1';
  if not in_d1 then raise exception 'FAIL: 결격 없는 d1이 오퍼를 못 받음'; end if;
  if in_d2 then raise exception 'FAIL ②: identity_verified_at null 근로자가 오퍼받음'; end if;
  if in_d3 then raise exception 'FAIL ③: is_available=false 근로자가 오퍼받음'; end if;
  if in_d4 then raise exception 'FAIL ④: 시간대 겹침 confirmed 배정 보유 근로자가 오퍼받음(더블부킹)'; end if;
  if not in_d5 then raise exception 'FAIL: 전문인력 d5는 일반 요청에도 포함돼야 함'; end if;
  if in_d6 then raise exception 'FAIL ⑦: min_reliability=30인데 신뢰 20 근로자가 오퍼받음'; end if;
  if v <> 2 then raise exception 'FAIL: 오퍼 수 기대 2(d1·d5), 실제 %', v; end if;
  if (select status from job_requests where id='cb000000-0000-0000-0000-0000000000a1') <> 'matching' then
    raise exception 'FAIL: 오퍼 생성됐는데 open→matching 전이 안 됨';
  end if;
  raise notice 'PASS ②③④⑦: 미인증·비가용·더블부킹·저신뢰 제외, d1·d5만 오퍼 + open→matching';
end $$;

-- ⑥ + ⑦(해제면): 하한 0으로 재-run_match → 신규는 d6뿐이어야 하고(신뢰 필터만이
--    직전 제외 사유였음을 증명), 기오퍼 d1·d5는 중복 오퍼 없이 각 1건 유지.
do $$ declare v int; begin
  v := run_match('cb000000-0000-0000-0000-0000000000a1', 3000, 0, 10, 60, false);
  if v <> 1 then
    raise exception 'FAIL ⑥: 재-run_match 신규 오퍼 기대 1(d6), 실제 %', v;
  end if;
  if not exists (select 1 from match_offers
                 where request_id = 'cb000000-0000-0000-0000-0000000000a1'
                   and worker_id  = 'cb000000-0000-0000-0000-0000000000d6') then
    raise exception 'FAIL ⑦: 하한 해제 후에도 d6 미오퍼';
  end if;
  if (select count(*) from match_offers
      where request_id = 'cb000000-0000-0000-0000-0000000000a1'
        and worker_id  = 'cb000000-0000-0000-0000-0000000000d1') <> 1 then
    raise exception 'FAIL ⑥: d1에게 중복 오퍼 발생';
  end if;
  if (select count(*) from match_offers
      where request_id = 'cb000000-0000-0000-0000-0000000000a1'
        and worker_id  = 'cb000000-0000-0000-0000-0000000000d5') <> 1 then
    raise exception 'FAIL ⑥: d5에게 중복 오퍼 발생';
  end if;
  raise notice 'PASS ⑥⑦: 기오퍼 d1·d5 중복 제외 + 하한 해제 시 d6 합류(총 신규 1건)';
end $$;

-- ⑤ 전문요구: p_require_professional=true → professional_verified_at 보유자(d5)만.
do $$ declare v int; in_d5 boolean; in_others boolean; begin
  v := run_match('cb000000-0000-0000-0000-0000000000a2', 3000, 0, 10, 60, true);
  select coalesce(bool_or(worker_id =  'cb000000-0000-0000-0000-0000000000d5'), false),
         coalesce(bool_or(worker_id <> 'cb000000-0000-0000-0000-0000000000d5'), false)
    into in_d5, in_others
    from match_offers where request_id = 'cb000000-0000-0000-0000-0000000000a2';
  if not in_d5 then raise exception 'FAIL ⑤: 전문인력 d5가 전문요구 요청 오퍼를 못 받음'; end if;
  if in_others then raise exception 'FAIL ⑤: 비전문 근로자가 전문요구 요청 오퍼를 받음'; end if;
  if v <> 1 then raise exception 'FAIL ⑤: 오퍼 수 기대 1(d5), 실제 %', v; end if;
  raise notice 'PASS ⑤: 전문요구 요청은 professional_verified 근로자만 오퍼';
end $$;

rollback;
