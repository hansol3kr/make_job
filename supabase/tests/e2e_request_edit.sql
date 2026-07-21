-- 요청 수정 E2E (트랜잭션 후 롤백). 대상: 0023_request_edit.sql의 edit_job_request.
-- 검증: ① matching 중 수정(급여·인원) + 옛 offered 오퍼 삭제(0023은 cancelled가 아니라
--       delete — 남기면 run_match 중복배제에 걸려 재오퍼 불가) + open 복귀
--       ② 수정 후 재매칭 시 같은 근로자가 다시 오퍼받음 ③ 최저임금 차단
--       ④ end<=start → bad_time_range ⑤ filled_count>0 → has_confirmed_workers
--       ⑥ 확정후 불가(not_editable) ⑦ 타인 차단(not_your_request)
-- 좌표는 공해상 고립 지점 — http_*.sh가 커밋한 강남 잔류 근로자와 격리해
-- 재매칭(웨이브 3) assert를 결정적으로 만든다.
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;

insert into profiles (id, role, display_name) values
  ('c9000000-0000-0000-0000-0000000000e1','employer','사장'),
  ('c9000000-0000-0000-0000-0000000000e2','employer','타사장'),
  ('c9000000-0000-0000-0000-0000000000d1','worker','근로자');
insert into employer_profiles (profile_id, business_name) values
  ('c9000000-0000-0000-0000-0000000000e1','카페'),('c9000000-0000-0000-0000-0000000000e2','타카페');
-- d1: 재매칭(②) 검증용 실제 후보 — 가용·본인인증·요청 인근(~120m).
insert into worker_profiles (profile_id, is_available, identity_verified_at, current_geog, reliability_score) values
  ('c9000000-0000-0000-0000-0000000000d1', true, now(),
   st_setsrid(st_makepoint(125.3010,34.3005),4326)::geography, 80);

-- 요청1: matching + 오퍼(수정 대상), 8시간 근무
insert into job_requests (id, employer_id, title, geog, start_at, end_at, pay_amount, headcount, status) values
  ('c9000000-0000-0000-0000-0000000000a1','c9000000-0000-0000-0000-0000000000e1','요청1',
   st_setsrid(st_makepoint(125.3000,34.3000),4326)::geography,
   now()+interval '3 hours', now()+interval '11 hours', 100000, 1, 'matching');
insert into match_offers (id, request_id, worker_id, rank, score, status, expires_at) values
  ('c9000000-0000-0000-0000-0000000000f1','c9000000-0000-0000-0000-0000000000a1',
   'c9000000-0000-0000-0000-0000000000d1', 1, 0.9, 'offered', now()+interval '60 seconds');

set local request.jwt.claims = '{"sub":"c9000000-0000-0000-0000-0000000000e1","role":"authenticated"}';

-- ① 급여 12만·인원 3으로 수정 → 값 반영 + open 복귀 + 옛 offered 오퍼 delete
do $$ declare r job_requests; begin
  perform edit_job_request('c9000000-0000-0000-0000-0000000000a1', null, null, null, 120000, 3);
  select * into r from job_requests where id='c9000000-0000-0000-0000-0000000000a1';
  if r.pay_amount <> 120000 or r.headcount <> 3 then
    raise exception 'FAIL ①: 수정 미반영 pay=% headcount=%', r.pay_amount, r.headcount;
  end if;
  if r.status <> 'open' then
    raise exception 'FAIL ①: 재매칭용 open 복귀 안 됨(status=%)', r.status;
  end if;
  if exists (select 1 from match_offers where id='c9000000-0000-0000-0000-0000000000f1') then
    raise exception 'FAIL ①: 오퍼 미삭제 — 0023은 offered 오퍼를 delete해야 함';
  end if;
  raise notice 'PASS ①: 급여·인원 반영 + open 복귀 + 옛 offered 오퍼 삭제';
end $$;

-- ② 수정 후 재매칭 → 같은 근로자 d1이 다시 오퍼받는다
--    (①에서 delete했기 때문에 run_match 중복배제에 안 걸린다 — cancelled로 남기면 실패)
do $$ declare v int; begin
  v := request_matching('c9000000-0000-0000-0000-0000000000a1');
  if not exists (select 1 from match_offers
                 where request_id = 'c9000000-0000-0000-0000-0000000000a1'
                   and worker_id  = 'c9000000-0000-0000-0000-0000000000d1'
                   and status     = 'offered') then
    raise exception 'FAIL ②: 재매칭에서 d1 재오퍼 안 됨(신규 %건)', v;
  end if;
  raise notice 'PASS ②: 수정 후 재매칭 시 같은 근로자 재오퍼(신규 %건)', v;
end $$;

-- ③ 최저임금 미달 수정 차단(8시간에 5만원 = 시급 6250 < 10320)
do $$ declare ok boolean := false; begin
  begin
    perform edit_job_request('c9000000-0000-0000-0000-0000000000a1', null, null, null, 50000);
  exception when others then ok := (sqlerrm like '%below_minimum_wage%'); end;
  if not ok then raise exception 'FAIL ③: 최저임금 미달인데 below_minimum_wage 미발생'; end if;
  raise notice 'PASS ③: 최저임금 미달 차단(below_minimum_wage)';
end $$;

-- ④ end<=start 수정 차단
do $$ declare ok boolean := false; begin
  begin
    perform edit_job_request('c9000000-0000-0000-0000-0000000000a1', null,
                             now()+interval '4 hours', now()+interval '4 hours');
  exception when others then ok := (sqlerrm like '%bad_time_range%'); end;
  if not ok then raise exception 'FAIL ④: end<=start인데 bad_time_range 미발생'; end if;
  raise notice 'PASS ④: end<=start 차단(bad_time_range)';
end $$;

-- ⑤ 확정 인원 존재(filled_count>0) 시 수정 차단 — 취소(보상) 흐름으로 가야 함
update job_requests set filled_count = 1 where id='c9000000-0000-0000-0000-0000000000a1';
do $$ declare ok boolean := false; begin
  begin
    perform edit_job_request('c9000000-0000-0000-0000-0000000000a1', '변경시도');
  exception when others then ok := (sqlerrm like '%has_confirmed_workers%'); end;
  if not ok then raise exception 'FAIL ⑤: filled_count>0인데 has_confirmed_workers 미발생'; end if;
  raise notice 'PASS ⑤: 확정 인원 존재 시 차단(has_confirmed_workers)';
end $$;
update job_requests set filled_count = 0 where id='c9000000-0000-0000-0000-0000000000a1';

-- ⑥ 확정 상태(status=confirmed) 수정 불가
update job_requests set status='confirmed' where id='c9000000-0000-0000-0000-0000000000a1';
do $$ declare ok boolean := false; begin
  begin
    perform edit_job_request('c9000000-0000-0000-0000-0000000000a1', '변경시도');
  exception when others then ok := (sqlerrm like '%not_editable%'); end;
  if not ok then raise exception 'FAIL ⑥: confirmed 요청인데 not_editable 미발생'; end if;
  raise notice 'PASS ⑥: 확정 요청 수정 차단(not_editable)';
end $$;

-- ⑦ 타인 요청 수정 차단
update job_requests set status='matching' where id='c9000000-0000-0000-0000-0000000000a1';
set local request.jwt.claims = '{"sub":"c9000000-0000-0000-0000-0000000000e2","role":"authenticated"}';
do $$ declare ok boolean := false; begin
  begin
    perform edit_job_request('c9000000-0000-0000-0000-0000000000a1', '탈취');
  exception when others then ok := (sqlerrm like '%not_your_request%'); end;
  if not ok then raise exception 'FAIL ⑦: 타인 요청인데 not_your_request 미발생'; end if;
  raise notice 'PASS ⑦: 타인 요청 수정 차단(not_your_request)';
end $$;

rollback;
