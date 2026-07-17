-- =====================================================================
-- 0027 요청 보관(soft-delete) — 종료된 요청을 홈 "최근 요청" 목록에서 숨김.
--  · completed/cancelled/expired 만 보관 가능(진행 중은 취소 흐름으로).
--  · hard delete 금지: assignments가 on delete cascade라 정산·페널티·분쟁
--    기록까지 연쇄 삭제됨. archived_at 마킹만 하고 기록은 전부 보존.
--  · 목록 제외는 클라이언트 select 필터(archived_at is null) — RLS/GRANT는
--    0004 테이블 전역 GRANT로 새 컬럼 자동 포함.
-- =====================================================================
set search_path = public, extensions;

alter table job_requests add column if not exists archived_at timestamptz;

create or replace function public.archive_job_request(p_request_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_status request_status;
begin
  select status into v_status from job_requests
   where id = p_request_id and employer_id = auth.uid();
  if v_status is null then raise exception 'not_your_request'; end if;
  if v_status not in ('completed','cancelled','expired') then
    raise exception 'not_closed';
  end if;
  -- 상태 재확인: select~update 사이 '다시 찾기' 등으로 재활성화되는 레이스 방지.
  update job_requests set archived_at = coalesce(archived_at, now())
   where id = p_request_id
     and status in ('completed','cancelled','expired');
end; $$;

grant execute on function public.archive_job_request(uuid) to authenticated;

notify pgrst, 'reload schema';
