-- 데이터 모델 + PostGIS 매칭 함수 검증 (트랜잭션 후 롤백 → DB 오염 없음)
-- 기대 결과: 강남역 인근 인증 근로자 1명만 후보로 반환
--   · worker_near   : 반경 내 + 인증됨          → 포함
--   · worker_far    : ~6km(반경 3km 밖)          → 제외
--   · worker_unverif: 인증 안 됨                 → 제외
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;  -- 테스트용 FK/트리거 비활성

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

rollback;
