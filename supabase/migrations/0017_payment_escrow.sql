-- =====================================================================
-- 0017 급여 정산 — 플랫폼 설정 + 최저임금 검증 + 에스크로 상태머신
--
-- 설계 원칙(전자금융거래법 회피): 플랫폼은 자금을 보유하지 않는다.
--   사업주 → [PG 에스크로 선결제] → (근무완료) → 근로자 지급 + 수수료 차감.
-- 아래 RPC는 상태머신(DB) 계층. 실제 자금이동(authorize/capture/settle)은
--   PG(PortOne/토스) API를 호출하는 Edge Function + 웹훅이 구동한다.
-- =====================================================================
set search_path = public, extensions;

-- ── 플랫폼 설정(최저임금·수수료율 — 코드 배포 없이 갱신) ──────────────────────
create table if not exists platform_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);
insert into platform_settings (key, value) values
  ('min_wage_hourly', '10320'::jsonb),   -- 2026 최저시급(고용노동부 고시). 매년 갱신.
  ('commission_rate', '0.04'::jsonb)     -- 수수료율. ⚠️ 직업안정법 유료직업소개 요율상한 확인 필수.
on conflict (key) do nothing;

alter table platform_settings enable row level security;
drop policy if exists platform_settings_read on platform_settings;
create policy platform_settings_read on platform_settings
  for select to anon, authenticated using (true);
grant select on platform_settings to anon, authenticated;

-- ── create_job_request: 최저임금 미달 등록 차단 (0010 기능 유지 + 검증 추가) ───
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
declare
  v_geog extensions.geography; v_addr text; v_id uuid;
  v_min numeric; v_hours numeric;
begin
  select default_geog, default_address into v_geog, v_addr
    from employer_profiles where profile_id = auth.uid();
  if v_geog is null and (p_lng is null or p_lat is null) then raise exception 'no_location'; end if;
  if p_lng is not null and p_lat is not null then
    v_geog := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  end if;

  -- 최저임금 검증(근로자 보호). 시급이면 직접 비교, 일급/총액이면 경과시간으로 환산(보수적).
  select (value)::numeric into v_min from platform_settings where key = 'min_wage_hourly';
  if p_pay_type = 'hourly' then
    if p_pay_amount < coalesce(v_min, 0) then raise exception 'below_minimum_wage'; end if;
  else
    v_hours := extract(epoch from (p_end_at - p_start_at)) / 3600.0;
    if v_hours > 0 and (p_pay_amount / v_hours) < coalesce(v_min, 0) then
      raise exception 'below_minimum_wage';
    end if;
  end if;

  insert into job_requests (employer_id, category_id, title, geog, address,
                            start_at, end_at, headcount, pay_type, pay_amount, status, requires_professional)
  values (auth.uid(), p_category_id, p_title, v_geog, coalesce(p_address, v_addr),
          p_start_at, p_end_at, greatest(1, p_headcount), p_pay_type, greatest(0, p_pay_amount), 'open',
          coalesce(p_requires_professional, false))
  returning id into v_id;
  return v_id;
end; $$;

-- ── 에스크로 상태머신 ─────────────────────────────────────────────────────────
-- 예치: 사업주 결제 → 에스크로. (실제 자금은 PG. 여기선 상태 기록 + 수수료 계산)
create or replace function public.escrow_payment(p_assignment uuid, p_pg_tx text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_emp uuid; v_pay int; v_rate numeric; v_id uuid;
begin
  select r.employer_id, r.pay_amount into v_emp, v_pay
    from assignments a join job_requests r on r.id = a.request_id where a.id = p_assignment;
  if v_emp is null then raise exception 'assignment_not_found'; end if;
  if v_emp <> auth.uid() then raise exception 'not_your_assignment'; end if;
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

-- 지급: 근무 완료(assignment completed) 후 에스크로 → 근로자 지급(released).
create or replace function public.release_payment(p_assignment uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_emp uuid; v_status assign_status;
begin
  select r.employer_id, a.status into v_emp, v_status
    from assignments a join job_requests r on r.id = a.request_id where a.id = p_assignment;
  if v_emp is null then raise exception 'assignment_not_found'; end if;
  if v_emp <> auth.uid() then raise exception 'not_your_assignment'; end if;
  if v_status <> 'completed' then raise exception 'work_not_completed'; end if;
  update payments set status = 'released', released_at = now()
   where assignment_id = p_assignment and status = 'escrowed';
  if not found then raise exception 'no_escrowed_payment'; end if;
end; $$;

-- 환불: 취소/노쇼 시 에스크로 → 환불(refunded).
create or replace function public.refund_payment(p_assignment uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_emp uuid;
begin
  select r.employer_id into v_emp
    from assignments a join job_requests r on r.id = a.request_id where a.id = p_assignment;
  if v_emp is null then raise exception 'assignment_not_found'; end if;
  if v_emp <> auth.uid() then raise exception 'not_your_assignment'; end if;
  update payments set status = 'refunded'
   where assignment_id = p_assignment and status = 'escrowed';
  if not found then raise exception 'no_escrowed_payment'; end if;
end; $$;

-- 조회: 당사자(근로자/업주)만.
create or replace function public.payment_status(p_assignment uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public.is_contract_party(p_assignment) then
    coalesce((select jsonb_build_object('status', p.status, 'amount', p.amount,
                                        'commission', p.commission, 'escrowed_at', p.escrowed_at,
                                        'released_at', p.released_at)
              from payments p where p.assignment_id = p_assignment), '{}'::jsonb)
    else '{}'::jsonb end;
$$;

grant execute on function public.create_job_request(text,timestamptz,timestamptz,int,int,uuid,double precision,double precision,text,text,boolean) to authenticated;
grant execute on function public.escrow_payment(uuid,text) to authenticated;
grant execute on function public.release_payment(uuid) to authenticated;
grant execute on function public.refund_payment(uuid,text) to authenticated;
grant execute on function public.payment_status(uuid) to authenticated;
