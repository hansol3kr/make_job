-- =====================================================================
-- RLS 무한 재귀 수정  [M1 버그픽스]
-- 원인: job_requests 정책이 match_offers/assignments를 서브쿼리하고,
--       그 테이블 정책이 다시 job_requests를 서브쿼리 → 상호 재귀(42P17).
-- 해결: 교차 검사를 SECURITY DEFINER 헬퍼로 옮겨 RLS 재평가를 우회.
-- =====================================================================
set search_path = public, extensions;

create or replace function public.is_employer_of_request(p_request uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from job_requests r
    where r.id = p_request and r.employer_id = auth.uid());
$$;

create or replace function public.worker_linked_to_request(p_request uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from match_offers o
                 where o.request_id = p_request and o.worker_id = auth.uid())
      or exists (select 1 from assignments a
                 where a.request_id = p_request and a.worker_id = auth.uid());
$$;

create or replace function public.is_contract_party(p_assignment uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from assignments a
    join job_requests r on r.id = a.request_id
    where a.id = p_assignment
      and (a.worker_id = auth.uid() or r.employer_id = auth.uid()));
$$;

-- 재귀 정책 교체
drop policy if exists jr_worker_read     on job_requests;
drop policy if exists mo_employer_read   on match_offers;
drop policy if exists assign_party_read  on assignments;
drop policy if exists contracts_party_read on contracts;

create policy jr_worker_read on job_requests for select
  using (public.worker_linked_to_request(id));

create policy mo_employer_read on match_offers for select
  using (public.is_employer_of_request(request_id));

create policy assign_party_read on assignments for select
  using (worker_id = auth.uid() or public.is_employer_of_request(request_id));

create policy contracts_party_read on contracts for select
  using (public.is_contract_party(assignment_id));
