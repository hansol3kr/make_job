-- 재예약 + 평점 자동공개 E2E (트랜잭션 후 롤백).
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('cd000000-0000-0000-0000-0000000000e1','employer','사장'),
  ('cd000000-0000-0000-0000-0000000000d1','worker','단골근로자');
insert into employer_profiles (profile_id, business_name) values
  ('cd000000-0000-0000-0000-0000000000e1','카페');
insert into worker_profiles (profile_id, is_available, identity_verified_at, current_geog) values
  ('cd000000-0000-0000-0000-0000000000d1', true, now(),
   st_setsrid(st_makepoint(127.0290,37.4990),4326)::geography);
insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount, status) values
  ('cd000000-0000-0000-0000-0000000000a1','cd000000-0000-0000-0000-0000000000e1','완료된 대타',
   st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
   now()-interval '10 hours', now()-interval '2 hours', 96000, 1, 'completed');
insert into assignments (id, request_id, worker_id, status, check_out_at) values
  ('cd000000-0000-0000-0000-0000000000b1','cd000000-0000-0000-0000-0000000000a1',
   'cd000000-0000-0000-0000-0000000000d1','completed', now()-interval '2 hours');
-- 평점: 근로자→업주 한쪽만, 15일 전 제출(자동공개 대상)
insert into ratings (assignment_id, rater_id, ratee_id, direction, stars, submitted_at) values
  ('cd000000-0000-0000-0000-0000000000b1','cd000000-0000-0000-0000-0000000000d1',
   'cd000000-0000-0000-0000-0000000000e1','worker_to_employer',5, now()-interval '15 days');

-- ── 재예약 ──
set local request.jwt.claims = '{"sub":"cd000000-0000-0000-0000-0000000000e1","role":"authenticated"}';
do $$ declare rid uuid; begin
  select rebook_worker('cd000000-0000-0000-0000-0000000000b1',
                       now()+interval '20 hours', now()+interval '28 hours') into rid;
  raise notice '① 재예약 요청 생성: %', rid is not null;
end $$;
select '① 지명 오퍼(기대: 단골근로자·rebook=true·TTL>60s)' as step,
  p.display_name, (o.reason->>'rebook') as rebook,
  (o.expires_at > now() + interval '5 minutes') as long_ttl
from match_offers o join profiles p on p.id=o.worker_id
where o.reason->>'rebook' = 'true';

-- 지명 오퍼를 근로자가 수락 → 확정
set local request.jwt.claims = '{"sub":"cd000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
do $$ declare aid uuid; begin
  select accept_offer(o.id) into aid from match_offers o where o.reason->>'rebook'='true';
  raise notice '② 지명 수락 → 배정: %', aid is not null;
end $$;
select '② 재예약 요청 상태(기대 confirmed)' as step, status::text as v
  from job_requests where title='완료된 대타' and status='confirmed';

-- ── 평점 14일 자동공개 (lazy: ratings_for_assignment 조회 시) ──
select '③ 조회 전 미공개' as step, (revealed_at is null) as v
  from ratings where assignment_id='cd000000-0000-0000-0000-0000000000b1';
set local request.jwt.claims = '{"sub":"cd000000-0000-0000-0000-0000000000e1","role":"authenticated"}';
select '③ 업주 조회 → theirs 공개(기대 stars 5)' as step,
  (ratings_for_assignment('cd000000-0000-0000-0000-0000000000b1')->'theirs'->>'stars') as v;
select '③ 조회 후 revealed_at 세팅' as step, (revealed_at is not null) as v
  from ratings where assignment_id='cd000000-0000-0000-0000-0000000000b1';

-- ── 완료 안 된 배정 재예약 차단 ──
do $$ begin
  perform rebook_worker('cd000000-0000-0000-0000-0000000000b1', now()-interval '1 hour', now()+interval '1 hour');
  raise notice '④ FAIL: 과거 시작시간 통과됨';
exception when others then
  raise notice '④ OK: 잘못된 시간 차단 (%)', sqlerrm;
end $$;

rollback;
