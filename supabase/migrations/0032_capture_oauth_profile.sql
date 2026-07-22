-- =====================================================================
-- 0032 소셜 로그인 프로필 캡처 — 카카오/구글 닉네임으로 display_name 자동 채움
--  Step C(간편가입)의 검수 불필요 부분: 카카오 기본 scope(profile_nickname, 이미 요청 중)
--  가 주는 닉네임을 표시명으로 자동 반영해 OAuth 유저의 온보딩 이름 재입력을 없앤다.
--  · 기존에 사용자가 정한 이름은 덮지 않는다(display_name이 비어 있을 때만 반영).
--  · 이는 편의용 표시명일 뿐 — 실명(legal_name)·본인확인(identity)은 0030/0031 경로.
--  이름·전화·CI 등 추가 동의항목은 카카오싱크 비즈앱 전환 + 검수가 선행(문서 체크리스트).
-- =====================================================================
set search_path = public;

create or replace function public.capture_oauth_profile(p_display_name text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update profiles
     set display_name = btrim(p_display_name)
   where id = auth.uid()
     and (display_name is null or btrim(display_name) = '')
     and p_display_name is not null
     and btrim(p_display_name) <> '';
end; $$;

grant execute on function public.capture_oauth_profile(text) to authenticated;

notify pgrst, 'reload schema';
