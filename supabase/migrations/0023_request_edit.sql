-- =====================================================================
-- 0023 요청 수정 — 매칭 중(open/matching) 급여·시간·인원 등 수정
--  · 확정 후에는 수정 불가(not_editable). 최저임금 재검증.
--  · 수정 시 옛 조건으로 나간 오퍼를 취소하고 요청을 open으로 되돌린다
--    → 앱이 request_matching으로 새 조건 재매칭(오퍼-조건 불일치 방지).
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

  -- 옛 조건으로 나간 미확정 오퍼 삭제(cancelled로 남기면 run_match 중복배제로 그 후보가
  -- 재오퍼에서 통째로 빠진다 → 삭제해 새 조건으로 다시 오퍼되게 한다).
  delete from match_offers
    where request_id = p_request_id and status = 'offered';
end; $$;

grant execute on function public.edit_job_request(uuid,text,timestamptz,timestamptz,int,int,text,boolean) to authenticated;
