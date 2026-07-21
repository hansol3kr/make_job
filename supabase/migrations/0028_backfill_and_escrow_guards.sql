-- =====================================================================
-- 0028 백필 완결 + 에스크로 상태 가드
--  테스트 확장(e2e_backfill·e2e_payment_escrow)에서 발견된 결함 3건 수정.
--
--  ① 형제취소 근로자 영구 백필 제외 (핵심 약속 "자동 백필" 훼손):
--     accept_offer가 headcount 충족 시 형제 오퍼를 'cancelled'로 만드는데,
--     run_match(0020)의 기오퍼 제외가 status 무관 행 존재 기준이고
--     unique(request_id,worker_id) 제약이 재삽입도 막아 — 확정자 취소 시
--     자동 백필이 0건. → run_match 시작 시 cancelled 오퍼를 삭제해 재오퍼
--     자격 복원(0024 '다시 찾기'의 delete 전례). declined(본인 거절)·
--     expired(무응답)·accepted(본인 취소/노쇼 이력)는 그대로 제외 유지 —
--     살아있는 요청에서 'cancelled'는 시스템 형제취소뿐이라 안전.
--  ② 백필 시 전문요구 미승계: cancel_assignment·report_no_show(0009)가
--     run_match 기본 인자 호출 → requires_professional=true 요청의 백필이
--     비전문 근로자에게 오퍼. → request_matching(0010)과 동일하게 승계.
--  ③ 에스크로 상태 가드: refund_payment(0017)가 배정 상태 무검사 →
--     근무 completed 후 release 전에 업주 환불 가능(임금 미지급 경로).
--     → 환불은 취소/노쇼 상태에서만. escrow_payment도 취소/노쇼 배정엔
--     예치 차단. (0022 cancel_job_request의 직접 update 환불 경로는 무영향)
--
--  grant/revoke: create or replace는 기존 ACL 보존 — 0024의 run_match
--  PUBLIC revoke 상태 그대로 유지되므로 재선언 불필요.
-- =====================================================================
set search_path = public, extensions;

-- ① run_match — 0020 본문 100% 보존 + 첫 줄에 cancelled 오퍼 삭제만 추가.
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
  -- 형제취소(cancelled) 오퍼 삭제 → 백필/웨이브에서 재오퍼 가능.
  -- declined/expired/accepted는 남겨 기존 제외 정책 유지.
  delete from match_offers
   where request_id = p_request_id and status = 'cancelled';

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

-- ② report_no_show — 0009 본문 보존 + 백필 호출에 requires_professional 승계.
create or replace function public.report_no_show(p_assignment_id uuid)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare v_worker uuid; v_request uuid; v_auto boolean; v_pro boolean;
begin
  select a.worker_id, a.request_id into v_worker, v_request
    from assignments a join job_requests r on r.id = a.request_id
   where a.id = p_assignment_id and r.employer_id = auth.uid()
     and a.status in ('confirmed', 'checked_in');
  if v_worker is null then raise exception 'not_allowed_or_bad_state'; end if;

  update assignments set status = 'no_show' where id = p_assignment_id;
  insert into reliability_events (profile_id, assignment_id, kind)
    values (v_worker, p_assignment_id, 'no_show');
  insert into penalties (profile_id, assignment_id, kind, reason)
    values (v_worker, p_assignment_id, 'no_show', '노쇼(근무 미이행)');
  perform recompute_reliability(v_worker);

  update job_requests
     set filled_count = greatest(0, filled_count - 1),
         status = case when auto_backfill then 'open' else status end
   where id = v_request;
  select auto_backfill, requires_professional into v_auto, v_pro
    from job_requests where id = v_request;
  if v_auto then
    return public.run_match(v_request, 3000, 0, 3, 60, coalesce(v_pro, false));
  end if;
  return 0;
end; $$;

-- ② cancel_assignment — 0009 본문 보존 + 백필 호출에 requires_professional 승계.
create or replace function public.cancel_assignment(p_assignment_id uuid)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare v_request uuid; v_start timestamptz; v_kind reliability_kind; v_auto boolean; v_pro boolean;
begin
  select a.request_id, r.start_at into v_request, v_start
    from assignments a join job_requests r on r.id = a.request_id
   where a.id = p_assignment_id and a.worker_id = auth.uid() and a.status = 'confirmed';
  if v_request is null then raise exception 'not_allowed_or_bad_state'; end if;

  update assignments set status = 'cancelled_worker' where id = p_assignment_id;
  v_kind := case when v_start - now() < interval '2 hours' then 'late_cancel' else 'declined' end;
  insert into reliability_events (profile_id, assignment_id, kind)
    values (auth.uid(), p_assignment_id, v_kind);
  if v_kind = 'late_cancel' then
    insert into penalties (profile_id, assignment_id, kind, reason)
      values (auth.uid(), p_assignment_id, 'late_cancel', '근무 임박 취소');
  end if;
  perform recompute_reliability(auth.uid());

  update job_requests
     set filled_count = greatest(0, filled_count - 1),
         status = case when auto_backfill then 'open' else status end
   where id = v_request;
  select auto_backfill, requires_professional into v_auto, v_pro
    from job_requests where id = v_request;
  if v_auto then
    return public.run_match(v_request, 3000, 0, 3, 60, coalesce(v_pro, false));
  end if;
  return 0;
end; $$;

-- ③ escrow_payment — 취소/노쇼 배정 예치 차단(not_escrowable_state).
create or replace function public.escrow_payment(p_assignment uuid, p_pg_tx text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_emp uuid; v_pay int; v_rate numeric; v_id uuid; v_status assign_status;
begin
  select r.employer_id, r.pay_amount, a.status into v_emp, v_pay, v_status
    from assignments a join job_requests r on r.id = a.request_id where a.id = p_assignment;
  if v_emp is null then raise exception 'assignment_not_found'; end if;
  if v_emp <> auth.uid() then raise exception 'not_your_assignment'; end if;
  if v_status in ('cancelled_worker','cancelled_employer','no_show') then
    raise exception 'not_escrowable_state';
  end if;
  if exists (select 1 from payments where assignment_id = p_assignment) then
    raise exception 'payment_exists';
  end if;
  select (value)::numeric into v_rate from platform_settings where key = 'commission_rate';
  insert into payments (assignment_id, pg_provider, pg_tx_id, amount, commission,
                        status, authorized_at, escrowed_at)
  values (p_assignment, 'escrow', p_pg_tx, v_pay, round(v_pay * coalesce(v_rate, 0))::int,
          'escrowed', now(), now())
  returning id into v_id;
  return v_id;
end; $$;

-- ③ refund_payment — 취소/노쇼 상태에서만 환불(not_refundable_state).
--    completed 후 release 전 환불(임금 미지급 경로) 차단.
--    확정/근무중 환불은 취소 플로우(cancel_job_request의 직접 update) 경유가 정도.
create or replace function public.refund_payment(p_assignment uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_emp uuid; v_status assign_status;
begin
  select r.employer_id, a.status into v_emp, v_status
    from assignments a join job_requests r on r.id = a.request_id where a.id = p_assignment;
  if v_emp is null then raise exception 'assignment_not_found'; end if;
  if v_emp <> auth.uid() then raise exception 'not_your_assignment'; end if;
  if v_status not in ('cancelled_worker','cancelled_employer','no_show') then
    raise exception 'not_refundable_state';
  end if;
  update payments set status = 'refunded'
   where assignment_id = p_assignment and status = 'escrowed';
  if not found then raise exception 'no_escrowed_payment'; end if;
end; $$;

notify pgrst, 'reload schema';
