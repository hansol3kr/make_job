-- 신원/PII 결함 수정 E2E (트랜잭션 후 롤백). 대상: 0030_identity_pii_fixes.sql.
-- 검증: B1 실명이 legal_name에 저장(display_name과 분리) · B2 계좌 원문 미저장(ref null,
--       뒤 4자리 마스크만) · B3 온보딩 서버측 동의 게이트(미동의 차단, 동의 후 통과).
-- UUID 프리픽스 e3 — 기존 테스트와 미충돌.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('e3000000-0000-0000-0000-0000000000d1','worker','근로자자가별칭');   -- display_name=자가입력

set local request.jwt.claims = '{"sub":"e3000000-0000-0000-0000-0000000000d1","role":"authenticated"}';

-- ── B3: 동의 없이 온보딩 → consent_required 차단 ──────────────────────
do $$ declare ok boolean := false; begin
  begin
    perform complete_worker_onboarding('근로자자가별칭', 127.0276, 37.4979);
  exception when others then ok := (sqlerrm like '%consent_required%'); end;
  if not ok then raise exception 'FAIL B3: 동의 없이 온보딩이 통과됨(consent_required 미발생)'; end if;
  raise notice 'PASS B3-1: 동의 없는 온보딩 차단(consent_required)';
end $$;

-- 필수 동의 5종 기록 후 온보딩 통과
do $$ begin
  perform record_consents('[{"type":"tos","granted":true},{"type":"privacy","granted":true},
    {"type":"privacy_3rd","granted":true},{"type":"location","granted":true},
    {"type":"age14","granted":true}]'::jsonb);
  perform complete_worker_onboarding('근로자자가별칭', 127.0276, 37.4979);
  if not exists (select 1 from worker_profiles where profile_id='e3000000-0000-0000-0000-0000000000d1') then
    raise exception 'FAIL B3: 동의 후에도 온보딩 미완료';
  end if;
  raise notice 'PASS B3-2: 동의 후 온보딩 통과';
end $$;

-- ── B1/B2: 본인확인 제출 — 실명은 legal_name, 계좌는 마스크만 ─────────
do $$
declare v_prof profiles; v_wp worker_profiles; v_ver verifications;
begin
  perform submit_identity_verification('홍길동', '국민', '5678');
  select * into v_prof from profiles where id='e3000000-0000-0000-0000-0000000000d1';
  select * into v_wp   from worker_profiles where profile_id='e3000000-0000-0000-0000-0000000000d1';
  select * into v_ver  from verifications
    where profile_id='e3000000-0000-0000-0000-0000000000d1' and type='identity'
    order by created_at desc limit 1;

  -- B1: 실명은 legal_name에, display_name(자가입력)은 불변
  if v_prof.legal_name is distinct from '홍길동' then
    raise exception 'FAIL B1: legal_name 미저장(실제=%)', v_prof.legal_name; end if;
  if v_prof.display_name <> '근로자자가별칭' then
    raise exception 'FAIL B1: display_name이 실명으로 덮임(실제=%)', v_prof.display_name; end if;

  -- B2: 계좌 원문 미저장 — ref는 null, 뒤 4자리 마스크만, 전체 계좌번호 흔적 없음
  if v_ver.ref is not null then
    raise exception 'FAIL B2: verifications.ref에 값이 저장됨(원문 유출 위험, 실제=%)', v_ver.ref; end if;
  if v_wp.payout_acct_last4 is distinct from '5678' then
    raise exception 'FAIL B2: 계좌 뒤 4자리 미저장(실제=%)', v_wp.payout_acct_last4; end if;
  if v_wp.payout_bank is distinct from '국민' then
    raise exception 'FAIL B2: 은행명 미저장(실제=%)', v_wp.payout_bank; end if;

  -- 본인확인 자체는 정상 반영(매칭 자격 게이트)
  if v_wp.identity_verified_at is null then
    raise exception 'FAIL: identity_verified_at 미설정'; end if;
  raise notice 'PASS B1: 실명 legal_name 저장 + display_name 보존';
  raise notice 'PASS B2: 계좌 원문 미저장(ref null) + 뒤4자리 마스크만';
end $$;

-- ── B2 경계: 계좌 미입력 시 마스크 null 유지(오작동 없음) ─────────────
insert into profiles (id, role, display_name) values
  ('e3000000-0000-0000-0000-0000000000d2','worker','계좌없음');
insert into consents (profile_id, type, granted, version) values
  ('e3000000-0000-0000-0000-0000000000d2','tos',true,'v1'),
  ('e3000000-0000-0000-0000-0000000000d2','privacy',true,'v1'),
  ('e3000000-0000-0000-0000-0000000000d2','privacy_3rd',true,'v1'),
  ('e3000000-0000-0000-0000-0000000000d2','location',true,'v1'),
  ('e3000000-0000-0000-0000-0000000000d2','age14',true,'v1');
set local request.jwt.claims = '{"sub":"e3000000-0000-0000-0000-0000000000d2","role":"authenticated"}';
do $$ declare v_wp worker_profiles; begin
  perform complete_worker_onboarding('계좌없음', 127.0276, 37.4979);
  perform submit_identity_verification('김본인', null, null);
  select * into v_wp from worker_profiles where profile_id='e3000000-0000-0000-0000-0000000000d2';
  if v_wp.payout_acct_last4 is not null or v_wp.payout_bank is not null then
    raise exception 'FAIL B2: 계좌 미입력인데 마스크/은행이 세팅됨'; end if;
  if v_wp.identity_verified_at is null then
    raise exception 'FAIL: 계좌 없이도 본인확인은 되어야 함'; end if;
  if (select legal_name from profiles where id='e3000000-0000-0000-0000-0000000000d2') <> '김본인' then
    raise exception 'FAIL B1: 계좌 없는 경로에서 legal_name 미저장'; end if;
  raise notice 'PASS B2-2: 계좌 미입력 시 마스크 null 유지 + 본인확인 정상';
end $$;

rollback;
