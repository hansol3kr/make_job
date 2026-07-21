-- =====================================================================
-- 0029 요청 수정 시 재오퍼 풀 복원
--  0023의 오퍼 정리가 status='offered'만 삭제 → declined(거절)·expired(무응답)·
--  cancelled(형제취소) 이력 행이 run_match 중복배제(행 존재 기준)에 걸려,
--  급여를 올려 재모집해도 그 후보들이 영구 제외되던 공백(e2e_request_edit에서 발견).
--  수정 = 조건 변경 = 새 제안이므로 미확정 오퍼 이력을 전부 삭제해 풀을 복원한다.
--  단 accepted(수락 후 본인 취소 이력)는 유지 — 0028 백필 제외 정책과 일관
--  (본인이 이 요청을 수락했다 취소한 근로자는 조건이 바뀌어도 재오퍼하지 않는다).
--  본문은 0023 100% 보존, 마지막 delete의 status 조건만 확장.
-- =====================================================================
set search_path = public, extensions;

create or replace function public.edit_job_request(
  p_request_id uuid,
  p_title      text default null,
  p_start_at   timestamptz default null,
  p_end_at     timestamptz default null,
  p_pay_amount int default null,
  p_headcount  int default null,
  p_pay_type   text default null,
  p_require_professional boolean default null
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_req job_requests;
  v_min numeric; v_start timestamptz; v_end timestamptz;
  v_pay int; v_ptype text; v_hours numeric;
begin
  select * into v_req from job_requests
   where id = p_request_id and employer_id = auth.uid();
  if v_req.id is null then raise exception 'not_your_request'; end if;
  if v_req.status not in ('open','matching') then raise exception 'not_editable'; end if;
  -- 이미 확정된 근로자가 하나라도 있으면 수정 불가(옛 조건에 묶인 stale 확정 방지).
  -- 확정자가 있는 요청은 취소(보상) 흐름으로 처리해야 한다.
  if v_req.filled_count > 0 then raise exception 'has_confirmed_workers'; end if;

  v_start := coalesce(p_start_at, v_req.start_at);
  v_end   := coalesce(p_end_at, v_req.end_at);
  v_pay   := coalesce(p_pay_amount, v_req.pay_amount);
  v_ptype := coalesce(p_pay_type, v_req.pay_type);
  if v_end <= v_start then raise exception 'bad_time_range'; end if;

  -- 최저임금 재검증(create/edit 동일 규칙)
  select (value)::numeric into v_min from platform_settings where key = 'min_wage_hourly';
  if v_ptype = 'hourly' then
    if v_pay < coalesce(v_min, 0) then raise exception 'below_minimum_wage'; end if;
  else
    v_hours := extract(epoch from (v_end - v_start)) / 3600.0;
    if v_hours > 0 and (v_pay / v_hours) < coalesce(v_min, 0) then
      raise exception 'below_minimum_wage';
    end if;
  end if;

  update job_requests set
    title      = coalesce(p_title, title),
    start_at   = v_start,
    end_at     = v_end,
    pay_amount = greatest(0, v_pay),
    pay_type   = v_ptype,
    headcount  = greatest(1, coalesce(p_headcount, headcount)),  -- null이면 기존값 유지
    requires_professional = coalesce(p_require_professional, requires_professional),
    status     = 'open'   -- 재매칭 위해 open 복귀
  where id = p_request_id;

  -- 미확정 오퍼 이력 삭제 → 새 조건으로 전 후보에게 다시 오퍼 가능.
  -- accepted(수락 후 본인 취소 이력)만 남겨 재오퍼 제외를 유지한다.
  delete from match_offers
    where request_id = p_request_id
      and status in ('offered','declined','expired','cancelled');
end; $$;

notify pgrst, 'reload schema';
