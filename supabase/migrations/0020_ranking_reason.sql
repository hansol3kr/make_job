-- =====================================================================
-- 0020 설명가능 랭킹 — match_offers.reason에 점수 분해 추가
--  · run_match(0010)의 매칭 로직(후보·score·정렬·wave·TTL)은 100% 보존.
--  · reason에 총점 + 근접/신뢰 기여도(%)를 추가해 "왜 이 순위"를 앱이 설명.
--    기존 distance_m·reliability는 유지(하위호환).
-- =====================================================================
set search_path = public, extensions;

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
           0.6 * greatest(0, 1 - c.dist_m / p_radius_m)      as prox_comp,
           (0.6 * greatest(0, 1 - c.dist_m / p_radius_m)
            + 0.4 * least(1, c.reliability_score / 100.0))   as score
    from nearby_candidates(p_request_id, p_radius_m, p_min_reliability, 50, p_require_professional) c
    where not exists (select 1 from match_offers o
                      where o.request_id = p_request_id and o.worker_id = c.worker_id)
    order by score desc limit p_wave
  ), scored as (
    -- prox_pct를 먼저 산출하고 rel_pct는 100-prox_pct로 유도 → 합=100 구조적 보장
    -- (독립 반올림에 의존하지 않아 반올림 모드/리팩터에 안전).
    select *, coalesce(round((prox_comp / nullif(score, 0)) * 100)::int, 0) as prox_pct
    from cand
  ), ins as (
    insert into match_offers (request_id, worker_id, rank, score, reason, status, expires_at)
    select p_request_id, worker_id, row_number() over (order by score desc),
           round(score::numeric, 4),
           jsonb_build_object(
             'distance_m',  round(dist_m)::int,
             'reliability', reliability_score,
             'score',       round(score::numeric, 4),
             'prox_pct',    prox_pct,
             'rel_pct',     case when score = 0 then 0 else 100 - prox_pct end
           ),
           'offered', now() + make_interval(secs => p_ttl_seconds)
    from scored returning 1
  )
  select count(*) into v_count from ins;
  if v_count > 0 then
    update job_requests set status = 'matching' where id = p_request_id and status = 'open';
  end if;
  return v_count;
end; $$;
