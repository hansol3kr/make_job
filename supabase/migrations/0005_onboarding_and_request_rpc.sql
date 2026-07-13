-- =====================================================================
-- 앱 와이어링용 RPC  [M1b]
-- 온보딩(근로자/업주 프로필 생성) · 요청 생성 · 매칭 시작.
-- geography는 전부 서버에서 st_makepoint로 구성(클라이언트 직렬화 위험 회피).
-- 모든 함수 SECURITY DEFINER + auth.uid()로 호출자 귀속.
-- =====================================================================
set search_path = public, extensions;

-- 근로자 온보딩: profiles.role 확정 + worker_profiles upsert(+홈/현재 위치)
-- NOTE: identity_verified_at 은 매칭 후보 조건(nearby_candidates)이라 dev에서 now()로 세팅.
--       실제 본인확인(본인확인기관 연동)은 M2에서 이 자리를 대체한다.
create or replace function public.complete_worker_onboarding(
  p_display_name text,
  p_lng double precision,
  p_lat double precision
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_geog extensions.geography;
begin
  v_geog := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  update profiles
     set role = case when exists (select 1 from employer_profiles where profile_id = auth.uid())
                     then 'both'::user_role else 'worker'::user_role end,
         display_name = coalesce(p_display_name, display_name)
   where id = auth.uid();
  insert into worker_profiles (profile_id, home_geog, current_geog, is_available, identity_verified_at)
  values (auth.uid(), v_geog, v_geog, false, now())
  on conflict (profile_id) do update
     set home_geog = excluded.home_geog,
         current_geog = coalesce(worker_profiles.current_geog, excluded.current_geog),
         identity_verified_at = coalesce(worker_profiles.identity_verified_at, excluded.identity_verified_at);
end; $$;

-- 업주 온보딩: profiles.role 확정 + employer_profiles upsert(+기본 위치/주소)
create or replace function public.complete_employer_onboarding(
  p_business_name text,
  p_lng double precision,
  p_lat double precision,
  p_address text default null
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_geog extensions.geography;
begin
  v_geog := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  update profiles
     set role = case when exists (select 1 from worker_profiles where profile_id = auth.uid())
                     then 'both'::user_role else 'employer'::user_role end,
         display_name = coalesce(p_business_name, display_name)
   where id = auth.uid();
  insert into employer_profiles (profile_id, business_name, default_geog, default_address)
  values (auth.uid(), p_business_name, v_geog, p_address)
  on conflict (profile_id) do update
     set business_name = excluded.business_name,
         default_geog = excluded.default_geog,
         default_address = excluded.default_address;
end; $$;

-- 요청 생성: 위치는 인자(p_lng/p_lat)가 있으면 사용, 없으면 업주 기본 위치.
create or replace function public.create_job_request(
  p_title       text,
  p_start_at    timestamptz,
  p_end_at      timestamptz,
  p_pay_amount  int,
  p_headcount   int default 1,
  p_category_id uuid default null,
  p_lng         double precision default null,
  p_lat         double precision default null,
  p_address     text default null,
  p_pay_type    text default 'daily'
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_geog extensions.geography; v_addr text; v_id uuid;
begin
  select default_geog, default_address into v_geog, v_addr
    from employer_profiles where profile_id = auth.uid();
  if v_geog is null and (p_lng is null or p_lat is null) then
    raise exception 'no_location';   -- 업주 프로필 위치도 없고 인자도 없음
  end if;
  if p_lng is not null and p_lat is not null then
    v_geog := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  end if;

  insert into job_requests (employer_id, category_id, title, geog, address,
                            start_at, end_at, headcount, pay_type, pay_amount, status)
  values (auth.uid(), p_category_id, p_title, v_geog, coalesce(p_address, v_addr),
          p_start_at, p_end_at, greatest(1, p_headcount), p_pay_type, greatest(0, p_pay_amount), 'open')
  returning id into v_id;
  return v_id;
end; $$;

-- 매칭 시작: 요청 소유(업주) 검증 후 run_match 호출. 오퍼 생성 수 반환.
create or replace function public.request_matching(p_request_id uuid)
returns int
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_employer_of_request(p_request_id) then
    raise exception 'not_your_request';
  end if;
  return public.run_match(p_request_id);
end; $$;

-- 매칭 현황 스냅샷: 업주가 자기 요청의 상태/오퍼수/확정 근로자(제한정보)를 한 번에.
-- profiles/worker_profiles는 본인전용 RLS라 업주가 직접 못 읽음 → 소유 검증 후 여기서만 노출.
create or replace function public.matching_snapshot(p_request_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare v jsonb;
begin
  if not public.is_employer_of_request(p_request_id) then
    raise exception 'not_your_request';
  end if;
  select jsonb_build_object(
    'status',        r.status,
    'headcount',     r.headcount,
    'filled_count',  r.filled_count,
    'offered_count', (select count(*) from match_offers o
                       where o.request_id = r.id and o.status = 'offered'),
    'workers', coalesce((
       select jsonb_agg(jsonb_build_object(
         'assignment_id', a.id,
         'status',        a.status,
         'display_name',  p.display_name,
         'reliability',   w.reliability_score,
         'dist_m',        round(st_distance(w.current_geog, r.geog))
       ) order by a.confirmed_at)
       from assignments a
       join profiles p        on p.id = a.worker_id
       join worker_profiles w on w.profile_id = a.worker_id
       where a.request_id = r.id
    ), '[]'::jsonb)
  ) into v
  from job_requests r where r.id = p_request_id;
  return v;
end; $$;

-- 실행 권한(명시). PostgREST 롤에서 호출 가능해야 함.
grant execute on function public.complete_worker_onboarding(text,double precision,double precision) to authenticated;
grant execute on function public.complete_employer_onboarding(text,double precision,double precision,text) to authenticated;
grant execute on function public.create_job_request(text,timestamptz,timestamptz,int,int,uuid,double precision,double precision,text,text) to authenticated;
grant execute on function public.request_matching(uuid) to authenticated;
grant execute on function public.matching_snapshot(uuid) to authenticated;
