-- 업장(stores) E2E (트랜잭션 후 롤백).
-- 검증: 온보딩 기본매장 생성 · 매장 추가/기본전환/삭제 · 매장별 요청 생성 · 타인 매장 차단.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;
insert into profiles (id, role, display_name) values
  ('c7000000-0000-0000-0000-0000000000e1','employer','사장A'),
  ('c7000000-0000-0000-0000-0000000000e2','employer','사장B');
-- replica 유지: 테스트 프로필이 auth.users에 없어 FK를 우회해야 함(RLS는 별개로 유효).

-- 0030: 온보딩 RPC가 서버측 동의 게이트를 요구 → 사장A 필수 동의 5종 선시드.
insert into consents (profile_id, type, granted, version) values
  ('c7000000-0000-0000-0000-0000000000e1','tos',true,'v1'),
  ('c7000000-0000-0000-0000-0000000000e1','privacy',true,'v1'),
  ('c7000000-0000-0000-0000-0000000000e1','privacy_3rd',true,'v1'),
  ('c7000000-0000-0000-0000-0000000000e1','location',true,'v1'),
  ('c7000000-0000-0000-0000-0000000000e1','age14',true,'v1');

-- 1) 사장A 온보딩 → 기본 매장 자동 생성
set local request.jwt.claims = '{"sub":"c7000000-0000-0000-0000-0000000000e1","role":"authenticated"}';
do $$ begin perform complete_employer_onboarding('강남점', 127.0276, 37.4979, '서울 강남구'); end $$;
select '① 온보딩 후 매장 수(기대 1)' as step, jsonb_array_length(my_stores()) as v;
select '① 기본매장 이름' as step, (my_stores()->0->>'name') as v;

-- 2) 둘째 매장 추가(기본 아님) → 매장 2개, 기본은 여전히 강남점
do $$ begin perform add_store('홍대점', 37.5563, 126.9236, '서울 마포구', false); end $$;
select '② 매장 수(기대 2)' as step, jsonb_array_length(my_stores()) as v;
select '② 기본 매장(강남점 유지)' as step,
  (select s->>'name' from jsonb_array_elements(my_stores()) s where (s->>'is_default')::bool) as v;

-- 3) 홍대점을 기본으로 전환
select '③ 홍대점 id로 기본전환' as step,
  (select set_default_store((s->>'id')::uuid) is null
   from jsonb_array_elements(my_stores()) s where s->>'name'='홍대점') as ok;
select '③ 새 기본 매장' as step,
  (select s->>'name' from jsonb_array_elements(my_stores()) s where (s->>'is_default')::bool) as v;

-- 4) 홍대점으로 요청 생성 → job_requests.store_id·위치가 홍대점 기준
insert into categories (id, slug, name) values ('c7000000-0000-0000-0000-0000000000ca','store','매장')
  on conflict do nothing;
select '④ 매장 지정 요청 생성' as step,
  (select create_job_request('홍대 대타', now()+interval '2 hours', now()+interval '8 hours',
     95000, 1, null, null, null, null, 'daily', false, (s->>'id')::uuid) is not null
   from jsonb_array_elements(my_stores()) s where s->>'name'='홍대점') as ok;
select '④ 요청 위치가 홍대점 근처(위도 37.55x)' as step,
  round(st_y(geog::geometry)::numeric, 2) as lat
  from job_requests where employer_id='c7000000-0000-0000-0000-0000000000e1' order by created_at desc limit 1;

-- 5) 타인(사장B) 매장 접근 차단
set local request.jwt.claims = '{"sub":"c7000000-0000-0000-0000-0000000000e2","role":"authenticated"}';
select '⑤ 사장B가 보는 매장 수(기대 0)' as step, jsonb_array_length(my_stores()) as v;
do $$
declare hongdae uuid;
begin
  -- 사장A의 홍대점 id를 직접 조회(셋업 편의, superuser 함수 밖)
  select id into hongdae from stores where name='홍대점';
  perform update_store(hongdae, '탈취시도');
  raise notice '⑤ FAIL: 타인 매장 수정 통과됨';
exception when others then
  raise notice '⑤ OK: 타인 매장 수정 차단 (%)', sqlerrm;
end $$;

rollback;
