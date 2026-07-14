-- 페널티 이의신청 E2E (트랜잭션 후 롤백). 실제 auth.uid() 컨텍스트로 appeal_penalty 검증.
-- 시나리오: workerA에게 페널티 3건(신청가능/면제됨/공백사유용) + workerB 페널티 1건(남의 것).
--   ① 정상 이의신청 → appeal_status='requested' + appeal_reason 기록
--   ② my_reliability_summary 가 id·appeal_status 를 노출
--   ③ 가드 4종: 중복신청 / 면제건 / 남의 페널티 / 공백 사유 → 전부 예외
-- ON_ERROR_STOP: assertion DO 블록이 raise 하면 psql 이 비정상 종료(=테스트 실패).
\set ON_ERROR_STOP on
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;  -- 셋업용 FK/트리거 비활성

insert into profiles (id, role, display_name) values
  ('22222222-2222-2222-2222-222222222222','worker','workerA'),
  ('55555555-5555-5555-5555-555555555555','worker','workerB');

insert into worker_profiles (profile_id, is_available, reliability_score) values
  ('22222222-2222-2222-2222-222222222222', false, 60);

insert into penalties (id, profile_id, assignment_id, kind, reason, waived) values
  ('a0000000-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222', null,'no_show','노쇼(근무 미이행)', false),  -- 신청 가능
  ('a0000000-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222', null,'late_cancel','근무 임박 취소', true),  -- 이미 면제
  ('a0000000-0000-0000-0000-000000000004','22222222-2222-2222-2222-222222222222', null,'no_show','노쇼', false),               -- 공백사유 테스트용
  ('a0000000-0000-0000-0000-000000000003','55555555-5555-5555-5555-555555555555', null,'no_show','노쇼', false);               -- 남의 것

-- 이후는 workerA 로 로그인한 상태.
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';

-- ① 정상 이의신청
select '① appeal_penalty 반환' as step, appeal_penalty('a0000000-0000-0000-0000-000000000001','아파서 못 갔어요, 진단서 있습니다') as value;

do $$ begin
  if (select appeal_status from penalties where id='a0000000-0000-0000-0000-000000000001') <> 'requested' then
    raise exception 'FAIL: appeal_status 가 requested 가 아님';
  end if;
  if (select appeal_reason from penalties where id='a0000000-0000-0000-0000-000000000001') is null then
    raise exception 'FAIL: appeal_reason 미기록';
  end if;
  if (select appealed_at from penalties where id='a0000000-0000-0000-0000-000000000001') is null then
    raise exception 'FAIL: appealed_at 미기록';
  end if;
  raise notice 'PASS ①: 정상 이의신청 반영';
end $$;

-- ② 요약에 id·appeal_status 노출
select '② 요약 penalties' as step, my_reliability_summary()->'penalties' as value;

do $$
declare pen jsonb;
begin
  select my_reliability_summary()->'penalties' into pen;
  if pen is null or jsonb_array_length(pen) < 3 then
    raise exception 'FAIL: 요약 penalties 개수 이상 (%)' , pen;
  end if;
  if not (pen @> '[{"appeal_status":"requested"}]'::jsonb) then
    raise exception 'FAIL: 요약에 appeal_status=requested 없음';
  end if;
  if not exists (select 1 from jsonb_array_elements(pen) e where e->>'id' is not null) then
    raise exception 'FAIL: 요약 penalties 에 id 없음';
  end if;
  raise notice 'PASS ②: 요약이 id·appeal_status 노출';
end $$;

-- ③ 가드: 중복 신청(같은 건 재신청)
do $$ declare ok boolean := false; begin
  begin perform appeal_penalty('a0000000-0000-0000-0000-000000000001','또 신청'); exception when others then ok := true; end;
  if not ok then raise exception 'FAIL: 중복 이의신청이 허용됨'; end if;
  raise notice 'PASS ③-a: 중복 신청 거부';
end $$;

-- ③ 가드: 이미 면제된 페널티
do $$ declare ok boolean := false; begin
  begin perform appeal_penalty('a0000000-0000-0000-0000-000000000002','면제건 신청'); exception when others then ok := true; end;
  if not ok then raise exception 'FAIL: 면제된 페널티에 이의신청 허용됨'; end if;
  raise notice 'PASS ③-b: 면제건 거부';
end $$;

-- ③ 가드: 남의 페널티
do $$ declare ok boolean := false; begin
  begin perform appeal_penalty('a0000000-0000-0000-0000-000000000003','남의 것'); exception when others then ok := true; end;
  if not ok then raise exception 'FAIL: 남의 페널티에 이의신청 허용됨'; end if;
  raise notice 'PASS ③-c: 타인 페널티 거부';
end $$;

-- ③ 가드: 공백 사유
do $$ declare ok boolean := false; begin
  begin perform appeal_penalty('a0000000-0000-0000-0000-000000000004','   '); exception when others then ok := true; end;
  if not ok then raise exception 'FAIL: 공백 사유가 허용됨'; end if;
  -- 공백 사유는 실패해야 하므로 상태가 그대로 none 인지 확인
  if (select appeal_status from penalties where id='a0000000-0000-0000-0000-000000000004') <> 'none' then
    raise exception 'FAIL: 공백 사유인데 상태가 바뀜';
  end if;
  raise notice 'PASS ③-d: 공백 사유 거부';
end $$;

select '✅ 모든 검증 통과' as result;
rollback;
