-- =====================================================================
-- 0010 전문인력(Professional) — 인증된 사람만 등록·매칭
-- "전문가 필요" 요청은 전문인력 인증을 받은 근로자에게만 매칭.
-- =====================================================================
set search_path = public, extensions;

alter table worker_profiles add column if not exists professional_verified_at timestamptz;
alter table job_requests   add column if not exists requires_professional boolean not null default false;

-- 파라미터 추가로 인한 오버로드 충돌(ambiguous) 방지: 구 시그니처 먼저 제거.
drop function if exists public.nearby_candidates(uuid, integer, numeric, integer);
drop function if exists public.run_match(uuid, int, numeric, int, int);
drop function if exists public.create_job_request(text,timestamptz,timestamptz,int,int,uuid,double precision,double precision,text,text);

-- 전문인력 등록: 본인확인(identity) 선행 필수 → 자격증/경력 제출 → 승인(MVP 스텁 즉시).
create or replace function public.register_professional(
  p_cert_name text,
  p_cert_ref  text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from worker_profiles
                 where profile_id = auth.uid() and identity_verified_at is not null) then
    raise exception 'identity_required';   -- 본인확인 먼저
  end if;
  insert into verifications (profile_id, type, status, provider, ref, verified_at)
    values (auth.uid(), 'background', 'verified', 'stub', p_cert_ref, now());
  update worker_profiles
     set professional_verified_at = coalesce(professional_verified_at, now()),
         tier = 'top_pro'
   where profile_id = auth.uid();
end; $$;

-- 매칭 후보: 전문인력 요구 필터 추가(맨 끝 파라미터, 기본 false → 기존 호출 무영향).
create or replace function public.nearby_candidates(
  p_request_id          uuid,
  p_radius_m            integer default 5000,
  p_min_reliability     numeric default 0,
  p_limit               integer default 10,
  p_require_professional boolean default false
) returns table (worker_id uuid, dist_m double precision, reliability_score numeric, tier text)
language sql stable security definer set search_path = public, extensions as $$
  select w.profile_id,
         st_distance(w.current_geog, r.geog) as dist_m,
         w.reliability_score,
         w.tier
  from worker_profiles w
  cross join lateral (
    select geog, start_at, end_at from job_requests where id = p_request_id
  ) r
  where w.is_available
    and w.identity_verified_at is not null
    and w.reliability_score >= p_min_reliability
    and w.current_geog is not null
    and st_dwithin(w.current_geog, r.geog, p_radius_m)
    and (not p_require_professional or w.professional_verified_at is not null)
    and not exists (
      select 1 from assignments a
      join job_requests jr on jr.id = a.request_id
      where a.worker_id = w.profile_id
        and a.status in ('confirmed','checked_in')
        and tstzrange(jr.start_at, jr.end_at) && tstzrange(r.start_at, r.end_at)
    )
  order by w.current_geog <-> r.geog
  limit p_limit;
$$;

-- run_match: 전문인력 요구 전달.
create or replace function public.run_match(
  p_request_id      uuid,
  p_radius_m        int default 3000,
  p_min_reliability numeric default 0,
  p_wave            int default 3,
  p_ttl_seconds     int default 60,
  p_require_professional boolean default false
) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare v_count int;
begin
  with cand as (
    select c.worker_id, c.dist_m, c.reliability_score,
           (0.6 * greatest(0, 1 - c.dist_m / p_radius_m)
            + 0.4 * least(1, c.reliability_score / 100.0)) as score
    from nearby_candidates(p_request_id, p_radius_m, p_min_reliability, 50, p_require_professional) c
    where not exists (select 1 from match_offers o
                      where o.request_id = p_request_id and o.worker_id = c.worker_id)
    order by score desc limit p_wave
  ), ins as (
    insert into match_offers (request_id, worker_id, rank, score, reason, status, expires_at)
    select p_request_id, worker_id, row_number() over (order by score desc),
           round(score::numeric, 4),
           jsonb_build_object('distance_m', round(dist_m)::int, 'reliability', reliability_score),
           'offered', now() + make_interval(secs => p_ttl_seconds)
    from cand returning 1
  )
  select count(*) into v_count from ins;
  if v_count > 0 then
    update job_requests set status = 'matching' where id = p_request_id and status = 'open';
  end if;
  return v_count;
end; $$;

-- 요청 생성: 전문인력 필요 플래그 추가.
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
  p_pay_type    text default 'daily',
  p_requires_professional boolean default false
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_geog extensions.geography; v_addr text; v_id uuid;
begin
  select default_geog, default_address into v_geog, v_addr
    from employer_profiles where profile_id = auth.uid();
  if v_geog is null and (p_lng is null or p_lat is null) then raise exception 'no_location'; end if;
  if p_lng is not null and p_lat is not null then
    v_geog := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  end if;
  insert into job_requests (employer_id, category_id, title, geog, address,
                            start_at, end_at, headcount, pay_type, pay_amount, status, requires_professional)
  values (auth.uid(), p_category_id, p_title, v_geog, coalesce(p_address, v_addr),
          p_start_at, p_end_at, greatest(1, p_headcount), p_pay_type, greatest(0, p_pay_amount), 'open',
          coalesce(p_requires_professional, false))
  returning id into v_id;
  return v_id;
end; $$;

-- 매칭 시작: 요청의 전문인력 요구를 반영해 run_match.
create or replace function public.request_matching(p_request_id uuid)
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare v_pro boolean;
begin
  if not public.is_employer_of_request(p_request_id) then raise exception 'not_your_request'; end if;
  select requires_professional into v_pro from job_requests where id = p_request_id;
  return public.run_match(p_request_id, 3000, 0, 3, 60, coalesce(v_pro, false));
end; $$;

-- 신뢰 요약에 전문인력 여부 추가.
create or replace function public.my_reliability_summary()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'reliability', w.reliability_score, 'tier', w.tier,
    'identity_verified', w.identity_verified_at is not null,
    'bank_verified', w.bank_verified_at is not null,
    'professional', w.professional_verified_at is not null,
    'is_available', w.is_available,
    'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.occurred_at) order by e.occurred_at desc)
                        from reliability_events e where e.profile_id = auth.uid()
                          and e.occurred_at > now() - interval '180 days'), '[]'::jsonb),
    'penalties', coalesce((select jsonb_agg(jsonb_build_object('kind', p.kind, 'reason', p.reason, 'waived', p.waived, 'at', p.created_at) order by p.created_at desc)
                           from penalties p where p.profile_id = auth.uid()), '[]'::jsonb)
  ) from worker_profiles w where w.profile_id = auth.uid();
$$;

grant execute on function public.register_professional(text,text) to authenticated;
grant execute on function public.create_job_request(text,timestamptz,timestamptz,int,int,uuid,double precision,double precision,text,text,boolean) to authenticated;
