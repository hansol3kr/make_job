-- 본인확인 게이트 E2E (트랜잭션 후 롤백). 대상: 0031_identity_gate.sql.
-- 검증: A1 apply로 검증신원 적재(실명·CI/DI·생년월일) · A2 DI 중복가입 차단 ·
--       A3 연령 게이트(최저연령 미만 거부) · A4 근로자 매칭자격 부여 ·
--       A5 업주 사업자검증 스텁(형식검증·biz_verified) · A6 스텁 경로 연속성.
-- UUID 프리픽스 e4 — 기존 테스트와 미충돌. superuser 실행(apply는 service_role 전용).
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('e4000000-0000-0000-0000-0000000000d1','worker','근로자1'),
  ('e4000000-0000-0000-0000-0000000000d2','worker','근로자2'),
  ('e4000000-0000-0000-0000-0000000000d3','worker','미성년'),
  ('e4000000-0000-0000-0000-0000000000e1','employer','사장');
insert into worker_profiles (profile_id) values
  ('e4000000-0000-0000-0000-0000000000d1'),
  ('e4000000-0000-0000-0000-0000000000d2'),
  ('e4000000-0000-0000-0000-0000000000d3');
insert into employer_profiles (profile_id, business_name) values
  ('e4000000-0000-0000-0000-0000000000e1','카페');

-- ── A1: 검증 신원 적재(성인 근로자1) ─────────────────────────────────
do $$ declare p profiles; w worker_profiles; begin
  perform apply_identity_verification(
    'e4000000-0000-0000-0000-0000000000d1','CI-AAA','DI-AAA','김성인',
    date '1990-05-05','M','pass');
  select * into p from profiles where id='e4000000-0000-0000-0000-0000000000d1';
  select * into w from worker_profiles where profile_id='e4000000-0000-0000-0000-0000000000d1';
  if p.legal_name <> '김성인' or p.di <> 'DI-AAA' or p.ci <> 'CI-AAA'
     or p.birth_date <> date '1990-05-05' or p.gender <> 'M' then
    raise exception 'FAIL A1: 신원 적재 불일치(legal=% di=% ci=% birth=% gender=%)',
      p.legal_name, p.di, p.ci, p.birth_date, p.gender; end if;
  if w.identity_verified_at is null then raise exception 'FAIL A4: 매칭자격 미부여'; end if;
  raise notice 'PASS A1/A4: 검증신원 적재 + 근로자 매칭자격 부여';
end $$;

-- ── A2: DI 중복가입 차단(근로자2가 같은 DI로 시도) ───────────────────
do $$ declare ok boolean := false; begin
  begin
    perform apply_identity_verification(
      'e4000000-0000-0000-0000-0000000000d2','CI-BBB','DI-AAA','다른사람',
      date '1988-01-01','F','pass');
  exception when others then ok := (sqlerrm like '%identity_duplicate_account%'); end;
  if not ok then raise exception 'FAIL A2: 같은 DI 중복가입이 차단되지 않음'; end if;
  if (select di from profiles where id='e4000000-0000-0000-0000-0000000000d2') is not null then
    raise exception 'FAIL A2: 차단됐는데 근로자2에 DI가 적재됨'; end if;
  raise notice 'PASS A2: DI 중복가입 차단(identity_duplicate_account)';
end $$;

-- ── A3: 연령 게이트(최저연령 미만 거부) ──────────────────────────────
-- min_signup_age=15 기준, 현재로부터 10년 전 출생 → 미달.
do $$ declare ok boolean := false; v_birth date; begin
  v_birth := (now() - interval '10 years')::date;
  begin
    perform apply_identity_verification(
      'e4000000-0000-0000-0000-0000000000d3','CI-CCC','DI-CCC','열살이',
      v_birth,'M','pass');
  exception when others then ok := (sqlerrm like '%underage%'); end;
  if not ok then raise exception 'FAIL A3: 최저연령 미만인데 통과됨'; end if;
  if (select identity_verified_at from worker_profiles
      where profile_id='e4000000-0000-0000-0000-0000000000d3') is not null then
    raise exception 'FAIL A3: 미성년 거부인데 매칭자격이 부여됨'; end if;
  raise notice 'PASS A3: 연령 게이트(underage 차단)';
end $$;

-- 경계: 정확히 최저연령(만 15세)이면 통과.
do $$ declare v_birth date; begin
  v_birth := (now() - interval '15 years' - interval '1 day')::date;  -- 만 15세 갓 넘김
  perform apply_identity_verification(
    'e4000000-0000-0000-0000-0000000000d3','CI-CCC','DI-CCC','열다섯',
    v_birth,'M','pass');
  if (select identity_verified_at from worker_profiles
      where profile_id='e4000000-0000-0000-0000-0000000000d3') is null then
    raise exception 'FAIL A3: 만 15세인데 거부됨'; end if;
  raise notice 'PASS A3-2: 최저연령 경계(만 15세) 통과';
end $$;

-- ── A5: 업주 사업자검증 스텁 ─────────────────────────────────────────
set local request.jwt.claims = '{"sub":"e4000000-0000-0000-0000-0000000000e1","role":"authenticated"}';
do $$ declare ok boolean := false; begin
  -- 형식 오류(10자리 아님) 거부
  begin perform submit_business_verification('123');
  exception when others then ok := (sqlerrm like '%invalid_biz_reg_no%'); end;
  if not ok then raise exception 'FAIL A5: 잘못된 사업자번호가 통과됨'; end if;
  -- 정상(하이픈 포함 10자리) → 정규화 저장 + biz_verified
  perform submit_business_verification('123-45-67890');
  if not (select biz_verified from employer_profiles where profile_id='e4000000-0000-0000-0000-0000000000e1') then
    raise exception 'FAIL A5: biz_verified 미설정'; end if;
  if (select biz_reg_no from employer_profiles where profile_id='e4000000-0000-0000-0000-0000000000e1') <> '1234567890' then
    raise exception 'FAIL A5: 사업자번호 정규화 저장 실패'; end if;
  raise notice 'PASS A5: 업주 사업자검증(형식검증 + 정규화 + biz_verified)';
end $$;

-- ── A6: 스텁 submit_identity_verification이 apply 경로로 동작(연속성) ──
insert into profiles (id, role, display_name) values
  ('e4000000-0000-0000-0000-0000000000d4','worker','스텁유저');
insert into worker_profiles (profile_id) values ('e4000000-0000-0000-0000-0000000000d4');
insert into consents (profile_id, type, granted, version) values
  ('e4000000-0000-0000-0000-0000000000d4','tos',true,'v1');
set local request.jwt.claims = '{"sub":"e4000000-0000-0000-0000-0000000000d4","role":"authenticated"}';
do $$ declare p profiles; w worker_profiles; begin
  perform submit_identity_verification('스텁실명','국민','4321');
  select * into p from profiles where id='e4000000-0000-0000-0000-0000000000d4';
  select * into w from worker_profiles where profile_id='e4000000-0000-0000-0000-0000000000d4';
  if p.legal_name <> '스텁실명' then raise exception 'FAIL A6: 스텁 실명 미저장'; end if;
  if p.di <> 'stub-di-e4000000-0000-0000-0000-0000000000d4' then
    raise exception 'FAIL A6: 스텁 DI 미적재(실제=%)', p.di; end if;
  if w.identity_verified_at is null then raise exception 'FAIL A6: 스텁 매칭자격 미부여'; end if;
  if w.payout_acct_last4 <> '4321' or w.payout_bank <> '국민' then
    raise exception 'FAIL A6: 스텁 계좌 마스크 유지 실패'; end if;
  raise notice 'PASS A6: 스텁→apply 연속성(실명·DI·매칭자격·계좌마스크)';
end $$;

rollback;
