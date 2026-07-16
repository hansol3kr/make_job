-- =====================================================================
-- 0022 요청 취소 — 매칭 중 자유 취소 + 확정 후 근로자 보상 수수료(티어)
--  · open/matching: 미확정 오퍼 전부 취소 + 요청 cancelled. 무료.
--  · 확정 근로자 존재: 배정 cancelled_employer + 시간대별 보상 수수료를
--    업주 penalty(kind='employer_cancel')로 기록 + 에스크로 환불(있으면).
--  · 수수료 티어는 platform_settings.cancel_fee_tiers(조정 가능).
--    실 자금이동(근로자 지급)은 PG/에스크로 도입 시 이 기록으로 정산.
-- =====================================================================
set search_path = public, extensions;

insert into platform_settings (key, value) values
  ('cancel_fee_tiers', '{"far_h":24,"near_h":2,"far_pct":0,"mid_pct":30,"near_pct":50}'::jsonb)
on conflict (key) do nothing;

create or replace function public.cancel_job_request(p_request_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_req    job_requests;
  v_tiers  jsonb;
  v_hours  numeric;
  v_pct    int;
  v_fee    int;
  v_total  int := 0;
  v_cnt    int := 0;
  a        record;
begin
  -- for update: 동시 취소(더블탭/재시도) 직렬화 → 페널티 중복·수수료 2배 방지.
  select * into v_req from job_requests
   where id = p_request_id and employer_id = auth.uid()
   for update;
  if v_req.id is null then raise exception 'not_your_request'; end if;
  if v_req.status in ('cancelled','completed') then raise exception 'already_closed'; end if;

  v_tiers := coalesce(
    (select value from platform_settings where key = 'cancel_fee_tiers'),
    '{"far_h":24,"near_h":2,"far_pct":0,"mid_pct":30,"near_pct":50}'::jsonb);
  v_hours := extract(epoch from (v_req.start_at - now())) / 3600.0;
  v_pct := case
    when v_hours >= (v_tiers->>'far_h')::numeric  then (v_tiers->>'far_pct')::int
    when v_hours >= (v_tiers->>'near_h')::numeric then (v_tiers->>'mid_pct')::int
    else (v_tiers->>'near_pct')::int end;

  -- 확정/근무중 배정: 취소 + 보상 수수료 기록
  for a in select id, worker_id from assignments
            where request_id = p_request_id and status in ('confirmed','checked_in')
  loop
    update assignments set status = 'cancelled_employer' where id = a.id;
    -- numeric 캐스트 후 곱셈 → int4 오버플로우 방지.
    v_fee := round(v_req.pay_amount::numeric * v_pct / 100.0)::int;
    v_total := v_total + v_fee;
    v_cnt := v_cnt + 1;
    if v_fee > 0 then
      insert into penalties (profile_id, assignment_id, kind, amount, reason)
      values (auth.uid(), a.id, 'employer_cancel', v_fee,
              format('확정 후 취소 보상 %s%% (근무 %sh 전)', v_pct, greatest(round(v_hours), 0)));
    end if;
    -- 에스크로 예치분 환불(있을 때만; 실 PG는 후속)
    update payments set status = 'refunded'
      where assignment_id = a.id and status = 'escrowed';
  end loop;

  -- 미확정+수락 오퍼 취소(취소된 배정의 accepted 오퍼가 dangling 안 되게)
  update match_offers set status = 'cancelled'
    where request_id = p_request_id and status in ('offered', 'accepted');
  -- 요청 취소
  update job_requests set status = 'cancelled' where id = p_request_id;

  return jsonb_build_object(
    'cancelled', true,
    'confirmed_cancelled', v_cnt,
    'fee_pct', case when v_cnt > 0 then v_pct else 0 end,
    'fee_total', v_total
  );
end; $$;

grant execute on function public.cancel_job_request(uuid) to authenticated;
