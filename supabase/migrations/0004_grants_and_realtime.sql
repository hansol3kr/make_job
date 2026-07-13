-- =====================================================================
-- 테이블 권한 + 실시간 퍼블리케이션  [M1]
-- RLS가 행 접근을 통제하지만, PostgREST 롤(authenticated/anon)에는
-- 테이블 레벨 GRANT가 별도로 필요하다(로컬은 자동 노출 안 함).
-- =====================================================================

-- authenticated: 전 테이블 접근(단, 행은 RLS 정책이 게이팅 → 정책 없으면 거부)
grant select, insert, update, delete on all tables in schema public to authenticated;
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;

-- anon: 카테고리 공개 읽기만
grant select on public.categories to anon;

-- 실시간: 근로자 오퍼 수신, 요청/배정 상태 변화 스트리밍
alter publication supabase_realtime add table match_offers;
alter publication supabase_realtime add table job_requests;
alter publication supabase_realtime add table assignments;
