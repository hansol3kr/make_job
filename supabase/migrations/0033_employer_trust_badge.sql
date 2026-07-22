-- =====================================================================
-- 0033 업주 신뢰 뱃지 — 근로자가 받은 제안의 사업장이 '사업자 인증' 됐는지 조회
--  0031이 업주 사업자검증(submit_business_verification, biz_verified)을 만들었으나
--  근로자에게 노출되는 경로가 없었다. 낯선 사람 대면노동 신뢰의 절반(업주측)을
--  근로자가 확정 전에 확인하도록 제안 카드에 '인증 사업장' 뱃지를 띄운다.
--  하드게이트가 아니라 '표시'(설계 문서의 권장 기본값 — 공급측 퍼널 안 막음).
--  RLS 안전: SECURITY DEFINER지만 호출자(근로자)가 실제 제안받은 요청만 반환.
-- =====================================================================
set search_path = public, extensions;

create or replace function public.employer_trust_for_requests(p_request_ids uuid[])
returns table(request_id uuid, employer_verified boolean, business_name text)
language sql stable security definer set search_path = public, extensions as $$
  select r.id, coalesce(ep.biz_verified, false), ep.business_name
  from job_requests r
  join employer_profiles ep on ep.profile_id = r.employer_id
  where r.id = any(p_request_ids)
    -- 호출 근로자가 실제로 제안(또는 배정)받은 요청만 — 임의 조회로 정보 노출 방지.
    and (
      exists (select 1 from match_offers o
              where o.request_id = r.id and o.worker_id = auth.uid())
      or exists (select 1 from assignments a
              where a.request_id = r.id and a.worker_id = auth.uid())
    );
$$;

grant execute on function public.employer_trust_for_requests(uuid[]) to authenticated;

notify pgrst, 'reload schema';
