-- =====================================================================
-- 0025 재예약 — "이 분 다시 부르기" (온플랫폼 재사용 = 리텐션·이탈방어 핵심)
--  · 완료된 배정의 근로자에게 같은 조건(급여·시간대 조정 가능)으로 지명 오퍼.
--  · 지명 오퍼는 TTL 10분(일반 60초보다 여유 — 지명은 즉답 강제가 아님).
--  · 무응답/거절 시 continue_matching(0024)이 자동으로 일반 매칭 전환.
-- =====================================================================
set search_path = public, extensions;

create or replace function public.rebook_worker(
  p_assignment_id uuid,
  p_start_at timestamptz,
  p_end_at   timestamptz,
  p_pay_amount int default null
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  r job_requests; v_worker uuid; v_pay int; v_min numeric; v_hours numeric; v_id uuid;
begin
  select a.worker_id into v_worker
    from assignments a join job_requests jr on jr.id = a.request_id
   where a.id = p_assignment_id and a.status = 'completed'
     and jr.employer_id = auth.uid();
  if v_worker is null then raise exception 'not_rebookable'; end if;
  select jr.* into r
    from assignments a join job_requests jr on jr.id = a.request_id
   where a.id = p_assignment_id;
  if p_start_at <= now() or p_end_at <= p_start_at then
    raise exception 'bad_time_range';
  end if;

  -- 더블부킹 방지: 근로자가 겹치는 시간에 이미 확정/근무 중이면 차단.
  if exists (
    select 1 from assignments a join job_requests jr on jr.id = a.request_id
     where a.worker_id = v_worker and a.status in ('confirmed','checked_in')
       and tstzrange(jr.start_at, jr.end_at) && tstzrange(p_start_at, p_end_at)
  ) then raise exception 'worker_schedule_conflict'; end if;

  -- 스팸/중복 지명 방지: 같은 근로자에게 살아있는 지명 오퍼가 이미 있으면 차단.
  if exists (
    select 1 from match_offers o join job_requests jr on jr.id = o.request_id
     where o.worker_id = v_worker and o.status = 'offered'
       and (o.reason->>'rebook') = 'true' and jr.employer_id = auth.uid()
  ) then raise exception 'rebook_pending'; end if;

  v_pay := coalesce(p_pay_amount, r.pay_amount);
  -- 최저임금 검증(create/edit와 동일 규칙)
  select (value)::numeric into v_min from platform_settings where key = 'min_wage_hourly';
  if r.pay_type = 'hourly' then
    if v_pay < coalesce(v_min, 0) then raise exception 'below_minimum_wage'; end if;
  else
    v_hours := extract(epoch from (p_end_at - p_start_at)) / 3600.0;
    if v_hours > 0 and (v_pay / v_hours) < coalesce(v_min, 0) then
      raise exception 'below_minimum_wage';
    end if;
  end if;

  insert into job_requests (employer_id, category_id, title, geog, address,
                            start_at, end_at, headcount, pay_type, pay_amount,
                            status, requires_professional, store_id)
  values (auth.uid(), r.category_id, r.title, r.geog, r.address,
          p_start_at, p_end_at, 1, r.pay_type, greatest(0, v_pay),
          'matching', r.requires_professional, r.store_id)
  returning id into v_id;

  -- 지명 오퍼(다이렉트): 반경·랭킹 무관, TTL 10분
  insert into match_offers (request_id, worker_id, rank, score, reason, status, expires_at)
  values (v_id, v_worker, 1, 1.0,
          jsonb_build_object('rebook', true),
          'offered', now() + interval '10 minutes');

  return v_id;
end; $$;

grant execute on function public.rebook_worker(uuid, timestamptz, timestamptz, int) to authenticated;

-- 신규 RPC를 REST(/rpc/)에 노출.
notify pgrst, 'reload schema';
