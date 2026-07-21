-- 데이터 모델 + PostGIS 매칭 함수 검증 (트랜잭션 후 롤백 → DB 오염 없음)
-- 기대 결과: 강남역 인근 인증 근로자 1명만 후보로 반환
--   · worker_near   : 반경 내 + 인증됨          → 포함
--   · worker_far    : ~6km(반경 3km 밖)          → 제외
--   · worker_unverif: 인증 안 됨                 → 제외
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;  -- 테스트용 FK/트리거 비활성

-- http_core_loop.sh가 같은 UUID를 커밋 방식으로 쓰다 중단되면 잔류가 남는다.
-- 트랜잭션 내 방어적 제거 — rollback으로 원복되므로 DB에는 영향 없음.
delete from assignments  where request_id='99999999-9999-9999-9999-999999999999';
delete from match_offers where request_id='99999999-9999-9999-9999-999999999999';
delete from job_requests where id='99999999-9999-9999-9999-999999999999';

insert into profiles (id, role, display_name) values
  ('11111111-1111-1111-1111-111111111111','employer','테스트카페사장'),
  ('22222222-2222-2222-2222-222222222222','worker','worker_near'),
  ('33333333-3333-3333-3333-333333333333','worker','worker_far'),
  ('44444444-4444-4444-4444-444444444444','worker','worker_unverif');

insert into employer_profiles (profile_id, business_name, default_geog) values
  ('11111111-1111-1111-1111-111111111111','강남 테스트카페',
   st_setsrid(st_makepoint(127.0276, 37.4979),4326)::geography);   -- 강남역

insert into worker_profiles (profile_id, is_available, identity_verified_at, current_geog, reliability_score) values
  ('22222222-2222-2222-2222-222222222222', true, now(),
   st_setsrid(st_makepoint(127.0290, 37.4990),4326)::geography, 80),   -- ~180m
  ('33333333-3333-3333-3333-333333333333', true, now(),
   st_setsrid(st_makepoint(127.1000, 37.5100),4326)::geography, 90),   -- ~6.6km
  ('44444444-4444-4444-4444-444444444444', true, null,
   st_setsrid(st_makepoint(127.0280, 37.4980),4326)::geography, 70);   -- 미인증

insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount) values
  ('99999999-9999-9999-9999-999999999999',
   '11111111-1111-1111-1111-111111111111','강남 카페 홀 대타',
   st_setsrid(st_makepoint(127.0276, 37.4979),4326)::geography,
   now() + interval '2 hours', now() + interval '8 hours', 90000);

select display_name, round(dist_m)::int as dist_m, reliability_score
from nearby_candidates('99999999-9999-9999-9999-999999999999', 3000, 0, 10) c
join profiles p on p.id = c.worker_id;

-- 자동 assert — 시드/타 데이터가 섞여도 픽스처 3명의 포함/제외만 판정.
-- (위 select는 사람 눈 확인용으로 유지)
do $$
declare
  hit_near    boolean;
  hit_far     boolean;
  hit_unverif boolean;
begin
  select
    bool_or(worker_id = '22222222-2222-2222-2222-222222222222'),
    bool_or(worker_id = '33333333-3333-3333-3333-333333333333'),
    bool_or(worker_id = '44444444-4444-4444-4444-444444444444')
  into hit_near, hit_far, hit_unverif
  from nearby_candidates('99999999-9999-9999-9999-999999999999', 3000, 0, 10);

  if not coalesce(hit_near, false) then
    raise exception 'FAIL: worker_near(반경 내·인증)가 후보에 없음';
  end if;
  if coalesce(hit_far, false) then
    raise exception 'FAIL: worker_far(반경 밖)가 후보에 포함됨';
  end if;
  if coalesce(hit_unverif, false) then
    raise exception 'FAIL: worker_unverif(미인증)가 후보에 포함됨';
  end if;
  raise notice 'PASS: nearby_candidates 포함/제외 판정 정상';
end $$;

-- ── 0021~0027 스키마 스모크 — 컬럼·테이블·설정·신규 RPC 존재 검증 ──────────────
-- (데이터 불필요 — 카탈로그 조회만. 위 픽스처와 무관하게 판정)
do $$
declare
  missing text;
begin
  -- ① job_requests 신규 컬럼 3종 (0021 store_id / 0027 archived_at / 0024 match_attempts)
  select string_agg(c.col, ', ') into missing
  from (values ('store_id'), ('archived_at'), ('match_attempts')) c(col)
  where not exists (
    select 1 from information_schema.columns ic
    where ic.table_schema = 'public' and ic.table_name = 'job_requests'
      and ic.column_name = c.col);
  if missing is not null then
    raise exception 'FAIL: job_requests 컬럼 누락 — %', missing;
  end if;

  -- ② stores 테이블 (0021)
  if to_regclass('public.stores') is null then
    raise exception 'FAIL: stores 테이블 없음 (0021 미적용?)';
  end if;

  -- ③ platform_settings.cancel_fee_tiers (0022 취소 수수료 티어)
  if not exists (select 1 from platform_settings where key = 'cancel_fee_tiers') then
    raise exception 'FAIL: platform_settings에 cancel_fee_tiers 키 없음 (0022 미적용?)';
  end if;

  -- ④ 신규 함수 8종 (0021~0027)
  select string_agg(f.fn, ', ') into missing
  from (values ('cancel_job_request'), ('edit_job_request'), ('continue_matching'),
               ('sweep_matching'), ('rebook_worker'), ('archive_job_request'),
               ('my_stores'), ('add_store')) f(fn)
  where not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = f.fn);
  if missing is not null then
    raise exception 'FAIL: 0021~0027 신규 함수 누락 — %', missing;
  end if;

  raise notice 'PASS: 0021~0027 스키마 스모크(컬럼 3종·stores·cancel_fee_tiers·함수 8종) 정상';
end $$;

rollback;
