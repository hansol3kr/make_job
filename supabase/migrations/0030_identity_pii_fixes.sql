-- =====================================================================
-- 0030 신원/PII 결함 수정 (본인확인 실연동 전 사전 정지 작업)
--  테스트 확장에서 드러난 3건:
--  B1) 실명 폐기: submit_identity_verification의 coalesce(display_name, p_real_name)가
--      display_name 선점으로 no-op → 실명이 어디에도 저장 안 됨. 표시명(자가입력 별칭)과
--      분리된 profiles.legal_name에 저장한다. (Step A 실 본인확인 시 기관 반환값으로 채움)
--  B2) 계좌 평문 저장: verifications.ref에 "은행/전체계좌번호"가 평문으로 들어가 UI 문구
--      ('원문 미저장')·스키마 주석과 모순. → 원문은 전송·저장하지 않고 뒤 4자리 마스크만
--      worker_profiles에 보관. 실 정산 계좌(원문)는 P4에서 PG 볼트 토큰화로 처리.
--  B3) 동의 미강제: 온보딩 RPC가 동의를 확인하지 않아 RPC 직접 호출로 동의 없이 개인정보
--      (이름·위치) 처리 가능 → 개인정보보호법상 결함. 두 온보딩 RPC에 서버측 동의 게이트.
--
--  submit_identity_verification 인자 타입은 (text,text,text) 그대로라(파라미터명만 변경)
--  create or replace로 grant 보존. 두 온보딩 RPC 본문은 각각 최신 정의(0009/0021) 보존 +
--  동의 게이트만 선행 추가.
-- =====================================================================
set search_path = public, extensions;

-- ── B1: 검증된 법적 성명(표시명과 분리) ──────────────────────────────
alter table profiles add column if not exists legal_name text;
comment on column profiles.legal_name is
  '본인확인으로 확보한 법적 성명. display_name(자가입력 별칭)과 분리. 계약/정산/신뢰의 신원 근거.';

-- ── B2: 정산 계좌는 마스크만 보관(원문 미저장) ───────────────────────
alter table worker_profiles add column if not exists payout_bank text;
alter table worker_profiles add column if not exists payout_acct_last4 text;
comment on column worker_profiles.payout_acct_last4 is
  '정산 계좌 뒤 4자리(표시용). 원문 계좌번호는 서버에 저장하지 않음 — 실 정산은 P4 PG 볼트 토큰.';

-- 본인확인 제출(스텁) — 실명은 legal_name, 계좌는 마스크만. ref엔 원문 미보관.
-- create or replace는 파라미터명 변경(p_account_ref→p_acct_last4) 불가 → 먼저 drop.
-- 시그니처(text,text,text) 동일하므로 재생성 후 아래에서 grant 복원.
drop function if exists public.submit_identity_verification(text, text, text);
create or replace function public.submit_identity_verification(
  p_real_name  text,
  p_bank       text default null,
  p_acct_last4 text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  -- 원문 식별정보(실명·계좌)를 ref에 담지 않는다 — 외부 CI/DI 토큰 자리(스텁은 null).
  insert into verifications (profile_id, type, status, provider, ref, verified_at)
    values (auth.uid(), 'identity', 'verified', 'stub', null, now());
  update worker_profiles
     set identity_verified_at = coalesce(identity_verified_at, now()),
         payout_bank       = coalesce(p_bank, payout_bank),
         payout_acct_last4 = coalesce(p_acct_last4, payout_acct_last4),
         bank_verified_at  = case when p_acct_last4 is not null
                                  then coalesce(bank_verified_at, now()) else bank_verified_at end,
         tier = case when tier = 'standard' then 'verified' else tier end
   where profile_id = auth.uid();
  -- 실명은 표시명을 덮지 않고 별도 컬럼에 저장(무조건 대입 — 재확인 시 갱신).
  update profiles set legal_name = coalesce(p_real_name, legal_name) where id = auth.uid();
end; $$;

-- ── B3: 온보딩 서버측 동의 게이트 ────────────────────────────────────
-- 근로자 온보딩 — 0009 본문 보존 + 동의 게이트 선행.
create or replace function public.complete_worker_onboarding(
  p_display_name text,
  p_lng double precision,
  p_lat double precision
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_geog extensions.geography;
begin
  if not coalesce((public.my_consent_status()->>'required_met')::boolean, false) then
    raise exception 'consent_required';
  end if;
  v_geog := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  update profiles
     set role = case when exists (select 1 from employer_profiles where profile_id = auth.uid())
                     then 'both'::user_role else 'worker'::user_role end,
         display_name = coalesce(p_display_name, display_name)
   where id = auth.uid();
  insert into worker_profiles (profile_id, home_geog, current_geog, is_available)
  values (auth.uid(), v_geog, v_geog, false)
  on conflict (profile_id) do update
     set home_geog = excluded.home_geog,
         current_geog = coalesce(worker_profiles.current_geog, excluded.current_geog);
end; $$;

-- 업주 온보딩 — 0021 본문 보존(기본 매장 생성 포함) + 동의 게이트 선행.
create or replace function public.complete_employer_onboarding(
  p_business_name text, p_lng double precision, p_lat double precision,
  p_address text default null
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_geog extensions.geography;
begin
  if not coalesce((public.my_consent_status()->>'required_met')::boolean, false) then
    raise exception 'consent_required';
  end if;
  v_geog := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  update profiles
     set role = case when exists (select 1 from worker_profiles where profile_id = auth.uid())
                     then 'both'::user_role else 'employer'::user_role end,
         display_name = coalesce(p_business_name, display_name)
   where id = auth.uid();
  insert into employer_profiles (profile_id, business_name, default_geog, default_address)
  values (auth.uid(), p_business_name, v_geog, p_address)
  on conflict (profile_id) do update
     set business_name = excluded.business_name,
         default_geog = excluded.default_geog,
         default_address = excluded.default_address;
  if not exists (select 1 from stores where employer_id = auth.uid()) then
    insert into stores (employer_id, name, address, geog, is_default)
    values (auth.uid(), coalesce(p_business_name, '기본 매장'), p_address, v_geog, true);
  end if;
end; $$;

-- create or replace가 grant를 보존하지만 관례(0004·0005·0009)대로 명시.
grant execute on function public.submit_identity_verification(text,text,text) to authenticated;
grant execute on function public.complete_worker_onboarding(text,double precision,double precision) to authenticated;
grant execute on function public.complete_employer_onboarding(text,double precision,double precision,text) to authenticated;

notify pgrst, 'reload schema';
