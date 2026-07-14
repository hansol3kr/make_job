-- =====================================================================
-- 0012 전자 근로계약서 — 확정 시점 조건으로 계약 생성 + 양측 서명
--  · 근로자성 방어의 핵심: 계약 당사자(사용자)는 "요청자"이고 플랫폼은 직업소개(중개)임을
--    terms에 명문화. 소득유형은 일용근로소득(daily_wage) 기본(가짜 3.3% 사업소득 방지).
--  · 생성은 최초 열람 시 lazy(get_or_create) — 검증된 코어루프(accept_offer) 미변경.
--  · terms/서명은 DB에 구조화 저장. PDF 바이너리 발급(pdf_url)은 후속(별도 파이프라인).
-- contracts 테이블·RLS 읽기정책(contracts_party_read)은 0001/0003에 이미 존재.
-- =====================================================================
set search_path = public, extensions;

-- 배정당 계약 1건 보장(동시 생성 레이스 방지). contracts는 비어 있어 안전.
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'contracts_assignment_uk') then
    alter table contracts add constraint contracts_assignment_uk unique (assignment_id);
  end if;
end $$;

-- 계약 조회(없으면 확정 조건으로 생성). 당사자만 호출 가능.
create or replace function public.get_or_create_contract(p_assignment uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_terms jsonb;
  r record;
  v contracts;
begin
  if not public.is_contract_party(p_assignment) then
    raise exception 'not a party to this assignment';
  end if;

  if not exists (select 1 from contracts where assignment_id = p_assignment) then
    select jr.title, jr.start_at, jr.end_at, jr.pay_type, jr.pay_amount, jr.address,
           ep.business_name, wpr.display_name as worker_name
      into r
      from assignments a
      join job_requests jr        on jr.id = a.request_id
      join employer_profiles ep   on ep.profile_id = jr.employer_id
      join profiles wpr           on wpr.id = a.worker_id
     where a.id = p_assignment;

    v_terms := jsonb_build_object(
      'employer_name', coalesce(r.business_name, '요청자'),
      'worker_name',   coalesce(r.worker_name, '근로자'),
      'title',         r.title,
      'start_at',      r.start_at,
      'end_at',        r.end_at,
      'work_minutes',  round(extract(epoch from (r.end_at - r.start_at)) / 60.0),
      'pay_type',      r.pay_type,
      'pay_amount',    r.pay_amount,
      'address',       r.address,
      'income_type',   'daily_wage',
      'employer_is_user', true,
      'broker_note',   '본 계약의 사용자(당사자)는 요청자이며, 플랫폼은 직업소개(중개) 역할만 합니다. 급여 결정·업무 지시·수락 권한은 요청자에게 있습니다.'
    );

    -- 동시 호출 레이스는 unique 제약 + on conflict로 흡수.
    insert into contracts (assignment_id, terms, income_type)
      values (p_assignment, v_terms, 'daily_wage')
      on conflict (assignment_id) do nothing;
  end if;

  select * into v from contracts where assignment_id = p_assignment;
  return jsonb_build_object(
    'id',                 v.id,
    'assignment_id',      v.assignment_id,
    'terms',              v.terms,
    'income_type',        v.income_type,
    'signed_worker_at',   v.signed_worker_at,
    'signed_employer_at', v.signed_employer_at,
    'pdf_url',            v.pdf_url,
    'worker_id',   (select worker_id from assignments where id = p_assignment),
    'employer_id', (select jr.employer_id from assignments a
                      join job_requests jr on jr.id = a.request_id
                     where a.id = p_assignment)
  );
end; $$;

-- 계약 서명(호출자의 역할 측만 서명). 없으면 먼저 생성.
create or replace function public.sign_contract(p_assignment uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_is_worker   boolean;
  v_is_employer boolean;
begin
  select exists (select 1 from assignments a
                  where a.id = p_assignment and a.worker_id = auth.uid())
    into v_is_worker;
  select exists (select 1 from assignments a
                  join job_requests jr on jr.id = a.request_id
                  where a.id = p_assignment and jr.employer_id = auth.uid())
    into v_is_employer;
  if not (v_is_worker or v_is_employer) then
    raise exception 'not a party to this assignment';
  end if;

  perform public.get_or_create_contract(p_assignment);  -- 없으면 생성

  if v_is_worker then
    update contracts set signed_worker_at = coalesce(signed_worker_at, now())
     where assignment_id = p_assignment;
  end if;
  if v_is_employer then
    update contracts set signed_employer_at = coalesce(signed_employer_at, now())
     where assignment_id = p_assignment;
  end if;

  return public.get_or_create_contract(p_assignment);
end; $$;

grant execute on function public.get_or_create_contract(uuid) to authenticated;
grant execute on function public.sign_contract(uuid) to authenticated;
