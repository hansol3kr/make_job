-- =============================================================================
-- 0006_client_logs — 클라이언트(앱) 원격 로그 채널
--
-- 목적: 실기기(TestFlight)에서 발생한 에러/이벤트를 서버로 실시간 수집 →
--       개발자가 SQL로 즉시 조회하며 디버깅. Flutter 전역 에러 핸들러가 여기에 적재.
--
-- 보안: 익명(anon)도 insert 허용(로그인 전 에러도 잡아야 함). 단 클라이언트는
--       SELECT/UPDATE/DELETE 정책이 없어 조회 불가 → 개발자만 service_role/SQL로 읽음.
--       (개발/테스트용 채널. 프로덕션 전환 시 Edge Function 경유+레이트리밋으로 강화.)
-- =============================================================================

create table if not exists public.client_logs (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  level        text        not null default 'info',   -- debug/info/warn/error/fatal
  message      text        not null,
  context      jsonb,                                  -- 임의 구조화 데이터
  error        text,                                   -- 에러 문자열
  stack        text,                                   -- 스택트레이스
  route        text,                                   -- 현재 화면 경로
  user_id      uuid        default auth.uid(),         -- 로그인 시 서버가 자동 기입
  session_id   text,                                   -- 앱 실행 세션 id
  platform     text,                                   -- ios/android
  app_version  text,
  build_number text,
  device       text
);

create index if not exists client_logs_created_idx on public.client_logs (created_at desc);
create index if not exists client_logs_level_idx   on public.client_logs (level);

alter table public.client_logs enable row level security;

-- insert만 허용(익명 포함). 조회 정책 없음 → 클라이언트는 못 읽음.
drop policy if exists client_logs_insert on public.client_logs;
create policy client_logs_insert on public.client_logs
  for insert to anon, authenticated
  with check (true);

grant insert on public.client_logs to anon, authenticated;
