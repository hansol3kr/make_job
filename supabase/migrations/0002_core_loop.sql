-- =====================================================================
-- 코어 루프 RPC  [M1]
-- 요청 → run_match(오퍼 생성) → accept_offer(확정) → check_in/out(완료)
-- 모든 변이 함수는 auth.uid()로 호출자 검증. SECURITY DEFINER로 원자성 보장.
-- =====================================================================
set search_path = public, extensions;

-- 근로자 가용/위치 갱신
create or replace function public.set_availability(
  p_available boolean,
  p_lng double precision default null,
  p_lat double precision default null
) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  update worker_profiles
     set is_available = p_available,
         current_geog = case
           when p_lng is not null and p_lat is not null
           then st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography
           else current_geog end,
         last_seen_at = now()
   where profile_id = auth.uid();
end; $$;

-- 매칭 실행: 반경 내 후보를 스코어링해 상위 wave명에게 오퍼 생성
-- score = 근접성 60% + 신뢰도 40% (설명가능 랭킹). 이미 오퍼 간 근로자는 제외.
create or replace function public.run_match(
  p_request_id      uuid,
  p_radius_m        int default 3000,
  p_min_reliability numeric default 0,
  p_wave            int default 3,
  p_ttl_seconds     int default 60
) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_count int;
begin
  with cand as (
    select c.worker_id, c.dist_m, c.reliability_score,
           (0.6 * greatest(0, 1 - c.dist_m / p_radius_m)
            + 0.4 * least(1, c.reliability_score / 100.0)) as score
    from nearby_candidates(p_request_id, p_radius_m, p_min_reliability, 50) c
    where not exists (
      select 1 from match_offers o
      where o.request_id = p_request_id and o.worker_id = c.worker_id)
    order by score desc
    limit p_wave
  ), ins as (
    insert into match_offers (request_id, worker_id, rank, score, reason, status, expires_at)
    select p_request_id, worker_id,
           row_number() over (order by score desc),
           round(score::numeric, 4),
           jsonb_build_object('distance_m', round(dist_m)::int,
                              'reliability', reliability_score),
           'offered',
           now() + make_interval(secs => p_ttl_seconds)
    from cand
    returning 1
  )
  select count(*) into v_count from ins;

  if v_count > 0 then
    update job_requests set status = 'matching'
     where id = p_request_id and status = 'open';
  end if;
  return v_count;
end; $$;

-- 오퍼 수락 → 배정 확정. 인원 충족 시 요청 확정 + 형제 오퍼 자동 취소.
create or replace function public.accept_offer(p_offer_id uuid)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_worker    uuid;
  v_request   uuid;
  v_status    offer_status;
  v_expires   timestamptz;
  v_headcount int;
  v_filled    int;
  v_assignment uuid;
begin
  select worker_id, request_id, status, expires_at
    into v_worker, v_request, v_status, v_expires
    from match_offers where id = p_offer_id for update;

  if v_worker is null then raise exception 'offer_not_found'; end if;
  if v_worker <> auth.uid() then raise exception 'not_your_offer'; end if;
  if v_status <> 'offered' then raise exception 'offer_not_open'; end if;
  if v_expires < now() then
    update match_offers set status = 'expired' where id = p_offer_id;
    raise exception 'offer_expired';
  end if;

  -- 요청 잠금 + 잔여 인원 확인
  select headcount, filled_count into v_headcount, v_filled
    from job_requests where id = v_request for update;
  if v_filled >= v_headcount then
    update match_offers set status = 'cancelled' where id = p_offer_id;
    raise exception 'already_filled';
  end if;

  insert into assignments (request_id, worker_id, status)
    values (v_request, v_worker, 'confirmed')
    returning id into v_assignment;

  update match_offers set status = 'accepted', responded_at = now()
   where id = p_offer_id;

  update job_requests set filled_count = filled_count + 1 where id = v_request;
  select filled_count, headcount into v_filled, v_headcount
    from job_requests where id = v_request;

  if v_filled >= v_headcount then
    update job_requests set status = 'confirmed' where id = v_request;
    -- 형제 오퍼 자동 취소 (더 이상 필요 없음)
    update match_offers set status = 'cancelled'
     where request_id = v_request and status = 'offered';
  end if;

  return v_assignment;
end; $$;

-- 오퍼 거절 — 신뢰도에 불이익 없음(거절 불이익 없음 차별점). 백필은 재-run_match로.
create or replace function public.decline_offer(p_offer_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  update match_offers set status = 'declined', responded_at = now()
   where id = p_offer_id and worker_id = auth.uid() and status = 'offered';
end; $$;

-- GPS 체크인
create or replace function public.check_in(
  p_assignment_id uuid, p_lng double precision, p_lat double precision
) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  update assignments
     set status = 'checked_in', check_in_at = now(),
         check_in_geog = st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography
   where id = p_assignment_id and worker_id = auth.uid() and status = 'confirmed';
  update job_requests r set status = 'in_progress'
    from assignments a
   where a.id = p_assignment_id and a.request_id = r.id and r.status = 'confirmed';
end; $$;

-- 체크아웃(완료) → 신뢰도 이벤트 적립 + 재계산
create or replace function public.check_out(p_assignment_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_worker uuid;
begin
  update assignments
     set status = 'completed', check_out_at = now()
   where id = p_assignment_id and worker_id = auth.uid() and status = 'checked_in'
  returning worker_id into v_worker;

  if v_worker is not null then
    insert into reliability_events (profile_id, assignment_id, kind)
      values (v_worker, p_assignment_id, 'completed');
    perform recompute_reliability(v_worker);
  end if;
end; $$;
