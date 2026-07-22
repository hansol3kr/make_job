-- 소셜 로그인 표시명 캡처 E2E (트랜잭션 후 롤백). 대상: 0032_capture_oauth_profile.sql.
-- 검증: 빈 표시명 → 닉네임 반영 · 기존 표시명 → 미변경(안 덮음) · 빈 입력 → no-op.
-- UUID 프리픽스 e5 — 기존 테스트와 미충돌.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('e5000000-0000-0000-0000-0000000000d1','worker', null),      -- 신규 OAuth(표시명 없음)
  ('e5000000-0000-0000-0000-0000000000d2','worker', '내가정한이름');  -- 기존 표시명

-- ① 빈 표시명 유저 → 카카오 닉네임 반영
set local request.jwt.claims = '{"sub":"e5000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
do $$ begin
  perform capture_oauth_profile('카카오닉네임');
  if (select display_name from profiles where id='e5000000-0000-0000-0000-0000000000d1') <> '카카오닉네임' then
    raise exception 'FAIL ①: 빈 표시명에 닉네임 미반영';
  end if;
  raise notice 'PASS ①: 빈 표시명 → 소셜 닉네임 자동 반영';
end $$;

-- ② 이미 이름을 정한 유저 → 안 덮음
set local request.jwt.claims = '{"sub":"e5000000-0000-0000-0000-0000000000d2","role":"authenticated"}';
do $$ begin
  perform capture_oauth_profile('카카오닉네임');
  if (select display_name from profiles where id='e5000000-0000-0000-0000-0000000000d2') <> '내가정한이름' then
    raise exception 'FAIL ②: 기존 표시명이 덮임';
  end if;
  raise notice 'PASS ②: 기존 표시명 보존(덮지 않음)';
end $$;

-- ③ 빈/공백 입력 → no-op(빈 표시명 유지)
set local request.jwt.claims = '{"sub":"e5000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
update profiles set display_name = null where id='e5000000-0000-0000-0000-0000000000d1';
do $$ begin
  perform capture_oauth_profile('   ');
  if (select display_name from profiles where id='e5000000-0000-0000-0000-0000000000d1') is not null then
    raise exception 'FAIL ③: 공백 입력이 표시명으로 저장됨';
  end if;
  raise notice 'PASS ③: 공백 입력 no-op';
end $$;

rollback;
