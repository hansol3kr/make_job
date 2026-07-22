-- =====================================================================
-- 0031 본인확인 게이트 — 중복가입 차단(CI/DI) + 연령 게이트 + 실 기관 연동 자리
--  Step A. 실 본인확인기관(PASS/NICE/토스/PortOne)은 provider에 무관하게 공통으로
--  CI(연계정보)·DI(중복가입확인정보)·실명·생년월일·성별을 반환한다. 이 반환값을 적재하는
--  provider-무관 계약 apply_identity_verification을 만든다:
--   · DI 유일성 → 한 사람당 한 계정(중복/차단계정 재가입 방지)
--   · 생년월일 → 취업 최저연령(근로기준법 15세; 조정 가능) 게이트
--   · 실명 → profiles.legal_name(0030), CI/DI/생년월일/성별 저장(주민번호 원문 미보관)
--  실 서비스: Edge Function(service_role)이 기관 응답을 받아 apply_...를 호출.
--  개발 스텁: submit_identity_verification이 시뮬레이션 CI/DI로 같은 경로를 태운다
--  (test_otp·ENABLED_OAUTH와 동일한 '스텁→실연동 교체' 패턴). 실명·계좌 마스크는 0030 유지.
--  업주측: 사업자등록 진위확인(국세청 API)은 별도 → 지금은 submit_business_verification 스텁.
-- =====================================================================
set search_path = public, extensions;

-- ── 신원 식별정보(본인확인기관 반환값). 주민번호 원문은 저장하지 않는다 ──
alter table profiles add column if not exists ci         text;   -- 연계정보(기관 간 동일인)
alter table profiles add column if not exists di         text;   -- 중복가입확인정보(서비스 내 유일)
alter table profiles add column if not exists birth_date date;
alter table profiles add column if not exists gender     text;   -- 'M'/'F'/null
comment on column profiles.di is '중복가입확인정보 — 서비스 내 1인 1계정 판별용. 원문 주민번호 대체.';

-- DI 기반 1인 1계정: 같은 사람(DI)이 다른 계정을 못 만든다.
create unique index if not exists profiles_di_uk on profiles (di) where di is not null;

-- 취업 최저연령(근로기준법 15세; 13~14세는 취직인허증 별도 절차). 운영 중 조정 가능.
insert into platform_settings (key, value) values ('min_signup_age', '15'::jsonb)
on conflict (key) do nothing;

-- ── 검증 신원 적재(실 EF가 service_role로 호출; 스텁도 이 경로 재사용) ──
-- 예외: identity_duplicate_account(DI 중복) / underage(연령미달) / no_profile.
create or replace function public.apply_identity_verification(
  p_profile uuid,
  p_ci      text,
  p_di      text,
  p_name    text,
  p_birth   date  default null,
  p_gender  text  default null,
  p_provider text default 'stub'
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_min numeric;
begin
  if p_profile is null then raise exception 'no_profile'; end if;

  -- 중복가입 차단: 같은 DI가 다른 계정에 이미 있으면 거부.
  if p_di is not null and exists (
       select 1 from profiles where di = p_di and id <> p_profile) then
    raise exception 'identity_duplicate_account';
  end if;

  -- 연령 게이트: 생년월일이 확인되면 최저연령 미만 거부.
  if p_birth is not null then
    select coalesce((value)::numeric, 15) into v_min from platform_settings where key = 'min_signup_age';
    if extract(year from age(p_birth)) < v_min then
      raise exception 'underage';
    end if;
  end if;

  update profiles
     set legal_name = coalesce(p_name, legal_name),
         ci         = coalesce(p_ci, ci),
         di         = coalesce(p_di, di),
         birth_date = coalesce(p_birth, birth_date),
         gender     = coalesce(p_gender, gender)
   where id = p_profile;

  insert into verifications (profile_id, type, status, provider, ref, verified_at)
    values (p_profile, 'identity', 'verified', p_provider, null, now());

  -- 근로자면 매칭 자격 부여(업주 프로필엔 worker_profiles 행이 없어 no-op).
  update worker_profiles
     set identity_verified_at = coalesce(identity_verified_at, now()),
         tier = case when tier = 'standard' then 'verified' else tier end
   where profile_id = p_profile;
end; $$;

-- ── 개발 스텁: 시뮬레이션 CI/DI로 apply 경로 재사용 + 계좌 마스크(0030) 유지 ──
-- 스텁 DI는 uid 파생 → 같은 유저 재확인은 자기 DI라 통과, 서로 다른 유저는 충돌 없음.
-- 실 서비스에선 이 함수 대신 EF→apply_identity_verification(실 CI/DI/생년월일)로 교체.
create or replace function public.submit_identity_verification(
  p_real_name  text,
  p_bank       text default null,
  p_acct_last4 text default null
) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.apply_identity_verification(
    auth.uid(),
    'stub-ci-' || auth.uid()::text,
    'stub-di-' || auth.uid()::text,
    p_real_name, null, null, 'stub');
  update worker_profiles
     set payout_bank       = coalesce(p_bank, payout_bank),
         payout_acct_last4 = coalesce(p_acct_last4, payout_acct_last4),
         bank_verified_at  = case when p_acct_last4 is not null
                                  then coalesce(bank_verified_at, now()) else bank_verified_at end
   where profile_id = auth.uid();
end; $$;

-- ── 업주 사업자등록 검증(스텁) — 실 국세청 진위확인 API 연동 전까지 즉시 승인 ──
-- 근로자만 본인확인 게이트가 있던 비대칭('업주 검증 전무') 해소의 첫걸음.
create or replace function public.submit_business_verification(p_biz_reg_no text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_biz_reg_no is null or length(regexp_replace(p_biz_reg_no, '\D', '', 'g')) <> 10 then
    raise exception 'invalid_biz_reg_no';
  end if;
  update employer_profiles
     set biz_reg_no  = regexp_replace(p_biz_reg_no, '\D', '', 'g'),
         biz_verified = true
   where profile_id = auth.uid();
  if not found then raise exception 'not_an_employer'; end if;
  insert into verifications (profile_id, type, status, provider, ref, verified_at)
    values (auth.uid(), 'business', 'verified', 'stub', null, now());
end; $$;

-- apply_...는 EF(service_role) 전용 — authenticated 직접 호출 금지(CI/DI 위조 방지).
revoke execute on function public.apply_identity_verification(uuid,text,text,text,date,text,text) from public;
grant  execute on function public.apply_identity_verification(uuid,text,text,text,date,text,text) to service_role;
-- 스텁·업주검증은 로그인 사용자.
grant execute on function public.submit_identity_verification(text,text,text) to authenticated;
grant execute on function public.submit_business_verification(text) to authenticated;

notify pgrst, 'reload schema';
