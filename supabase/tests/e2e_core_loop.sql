-- 코어 루프 E2E (트랜잭션 후 롤백). 실제 auth.uid() 컨텍스트로 accept_offer 검증.
-- 시나리오: 후보 2명 → run_match(오퍼 2건) → workerA 수락 → 요청 확정 + workerB 오퍼 자동 취소
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;  -- 셋업용 FK/트리거 비활성

-- http_core_loop.sh가 같은 UUID를 커밋 방식으로 쓰다 중단되면 잔류가 남는다.
-- 트랜잭션 내 방어적 제거 — rollback으로 원복되므로 DB에는 영향 없음.
delete from assignments  where request_id='99999999-9999-9999-9999-999999999999';
delete from match_offers where request_id='99999999-9999-9999-9999-999999999999';
delete from job_requests where id='99999999-9999-9999-9999-999999999999';

-- 참여자
insert into profiles (id, role, display_name) values
  ('11111111-1111-1111-1111-111111111111','employer','사장'),
  ('22222222-2222-2222-2222-222222222222','worker','workerA'),
  ('55555555-5555-5555-5555-555555555555','worker','workerB');

insert into employer_profiles (profile_id, business_name, default_geog) values
  ('11111111-1111-1111-1111-111111111111','강남카페',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography);

insert into worker_profiles (profile_id, is_available, identity_verified_at, current_geog, reliability_score) values
  ('22222222-2222-2222-2222-222222222222', true, now(),
   st_setsrid(st_makepoint(127.0290,37.4990),4326)::geography, 80),   -- ~180m
  ('55555555-5555-5555-5555-555555555555', true, now(),
   st_setsrid(st_makepoint(127.0330,37.5010),4326)::geography, 90);   -- ~500m

insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount) values
  ('99999999-9999-9999-9999-999999999999',
   '11111111-1111-1111-1111-111111111111','강남 카페 홀 대타',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()+interval '2 hours', now()+interval '8 hours', 95000, 1);

-- 1) 매칭 실행
select '① run_match 오퍼 생성 수' as step, run_match('99999999-9999-9999-9999-999999999999',3000,0,3,60) as value;

select '② 생성된 오퍼' as step, p.display_name, o.rank, o.score, o.status
from match_offers o join profiles p on p.id=o.worker_id
where o.request_id='99999999-9999-9999-9999-999999999999' order by o.rank;

-- 2) workerA가 수락 (실제 auth.uid() = workerA)
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select '③ accept_offer → assignment id' as step,
  accept_offer((select id from match_offers
                where request_id='99999999-9999-9999-9999-999999999999'
                  and worker_id='22222222-2222-2222-2222-222222222222')) as value;

-- 3) 최종 상태 검증
select '④ 요청 상태' as k, status::text as v from job_requests where id='99999999-9999-9999-9999-999999999999'
union all
select '④ workerA 오퍼', o.status::text from match_offers o where o.request_id='99999999-9999-9999-9999-999999999999' and o.worker_id='22222222-2222-2222-2222-222222222222'
union all
select '④ workerB 오퍼(자동취소 기대)', o.status::text from match_offers o where o.request_id='99999999-9999-9999-9999-999999999999' and o.worker_id='55555555-5555-5555-5555-555555555555'
union all
select '④ 배정 상태', a.status::text from assignments a where a.request_id='99999999-9999-9999-9999-999999999999';

rollback;
