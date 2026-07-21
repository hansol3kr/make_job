-- 자동 백필 E2E (트랜잭션 후 롤백) — 핵심 약속 "취소 시 자동 백필"의 서버 경로 검증.
-- 대상: 0009의 cancel_assignment·report_no_show(+run_match 연쇄 호출부),
--       0020 run_match 최종 정의, 0010 nearby_candidates, 0001 recompute_reliability.
-- 검증: ① 매칭→A 수락 확정 ② A 여유 취소(3h+ 전) → 배정 cancelled_worker·filled_count 감소·
--         요청 open 복귀 후 재매칭(matching)·B에게 새 오퍼(백필)·declined 이벤트·페널티 없음
--       ③ 임박(2h 내) 취소 → late_cancel 페널티 + 신뢰도 감점(-8)
--       ④ 사장 report_no_show → no_show 페널티 + 신뢰도 재계산(-20) + 백필
--       ⑤ 취소/노쇼 근로자 A는 백필 오퍼 대상에서 제외(기오퍼 행으로 자동 제외)
--       ⑥ 비당사자(타 근로자·타 사장)의 cancel_assignment/report_no_show 차단 + 상태머신(중복 호출) 차단
--       ⑦ 형제취소(cancelled) 오퍼 이력 근로자의 백필 재오퍼 — 0028이 cancelled 오퍼를
--         run_match 시작 시 삭제해 재오퍼 자격 복원(핵심 약속 완결)
--       ⑧ 전문요구 요청의 백필이 requires_professional을 승계(0028) — 비전문 제외
-- 좌표는 공해상 고립 지점(124.5,33.5 / 124.8,33.5) — 시드·http 테스트 잔류 데이터와
-- 간섭을 차단해 count assert를 결정적으로 만든다(e2e_run_match_edges.sql 전례).
begin;
set local search_path = public, extensions;
set local session_replication_role = replica;  -- 셋업용 FK/트리거 비활성

-- 참여자 (UUID 프리픽스 fb — 기존 테스트 파일들과 미충돌)
insert into profiles (id, role, display_name) values
  ('fb000000-0000-0000-0000-0000000000e1','employer','사장1'),
  ('fb000000-0000-0000-0000-0000000000e2','employer','타사장'),
  ('fb000000-0000-0000-0000-0000000000d1','worker','근로자A'),
  ('fb000000-0000-0000-0000-0000000000d2','worker','근로자B'),
  ('fb000000-0000-0000-0000-0000000000d3','worker','제3자C'),
  ('fb000000-0000-0000-0000-0000000000d4','worker','전문가P'),
  ('fb000000-0000-0000-0000-0000000000d5','worker','비전문N');
insert into employer_profiles (profile_id, business_name) values
  ('fb000000-0000-0000-0000-0000000000e1','카페1'),
  ('fb000000-0000-0000-0000-0000000000e2','카페2');

-- 지점1(124.5,33.5): A(~93m, 최근접) · B(~371m) · C(비가용 — 매칭 불참, ⑥ 전용)
-- 지점2(124.8,33.5, 지점1에서 ~28km — 반경 3km 상호 간섭 없음): P(전문) · N(비전문)
insert into worker_profiles (profile_id, is_available, identity_verified_at,
                             professional_verified_at, current_geog, reliability_score) values
  ('fb000000-0000-0000-0000-0000000000d1', true,  now(), null,
   st_setsrid(st_makepoint(124.5010,33.5000),4326)::geography, 50),
  ('fb000000-0000-0000-0000-0000000000d2', true,  now(), null,
   st_setsrid(st_makepoint(124.5040,33.5000),4326)::geography, 50),
  ('fb000000-0000-0000-0000-0000000000d3', false, now(), null,
   st_setsrid(st_makepoint(124.5040,33.5000),4326)::geography, 50),
  ('fb000000-0000-0000-0000-0000000000d4', true,  now(), now(),
   st_setsrid(st_makepoint(124.8005,33.5000),4326)::geography, 50),
  ('fb000000-0000-0000-0000-0000000000d5', true,  now(), null,
   st_setsrid(st_makepoint(124.8010,33.5000),4326)::geography, 50);

-- 요청: r1=여유취소(+5h) / r2=임박취소(+1h) / r3=노쇼(+5h) / r4=형제취소 관찰(+5h)
--       r5=전문요구 백필 관찰(+6h, 지점2). auto_backfill은 기본 true.
insert into job_requests (id, employer_id, title, geog, start_at, end_at,
                          pay_amount, headcount, status, requires_professional) values
  ('fb000000-0000-0000-0000-0000000000a1','fb000000-0000-0000-0000-0000000000e1','여유취소',
   st_setsrid(st_makepoint(124.5000,33.5000),4326)::geography,
   now()+interval '5 hours', now()+interval '9 hours', 100000, 1, 'open', false),
  ('fb000000-0000-0000-0000-0000000000a2','fb000000-0000-0000-0000-0000000000e1','임박취소',
   st_setsrid(st_makepoint(124.5000,33.5000),4326)::geography,
   now()+interval '1 hours', now()+interval '3 hours', 100000, 1, 'open', false),
  ('fb000000-0000-0000-0000-0000000000a3','fb000000-0000-0000-0000-0000000000e1','노쇼',
   st_setsrid(st_makepoint(124.5000,33.5000),4326)::geography,
   now()+interval '5 hours', now()+interval '7 hours', 100000, 1, 'open', false),
  ('fb000000-0000-0000-0000-0000000000a4','fb000000-0000-0000-0000-0000000000e1','형제취소관찰',
   st_setsrid(st_makepoint(124.5000,33.5000),4326)::geography,
   now()+interval '5 hours', now()+interval '6 hours', 100000, 1, 'open', false),
  ('fb000000-0000-0000-0000-0000000000a5','fb000000-0000-0000-0000-0000000000e1','전문요구백필',
   st_setsrid(st_makepoint(124.8000,33.5000),4326)::geography,
   now()+interval '6 hours', now()+interval '10 hours', 200000, 1, 'open', true);

-- ────────────────────────────────────────────────────────────────────
-- ① r1: run_match(wave=1) → 최근접·동신뢰 A가 단독 오퍼 → A 수락 → 확정
--    (wave=1로 B를 1차 웨이브에서 의도적으로 배제 — B가 "기오퍼 없음" 상태로
--     남아야 ②의 백필 신규 오퍼 대상이 된다. 사장 앱 기본 wave=3의 축소판.)
-- ────────────────────────────────────────────────────────────────────
do $$ declare v int; begin
  v := run_match('fb000000-0000-0000-0000-0000000000a1', 3000, 0, 1, 600, false);
  if v <> 1 then raise exception 'FAIL ①: wave=1 오퍼 수 기대 1, 실제 %', v; end if;
  if not exists (select 1 from match_offers
                 where request_id = 'fb000000-0000-0000-0000-0000000000a1'
                   and worker_id  = 'fb000000-0000-0000-0000-0000000000d1'
                   and status = 'offered') then
    raise exception 'FAIL ①: 최근접 A가 1위 오퍼를 못 받음(랭킹 회귀)';
  end if;
  if (select status from job_requests where id='fb000000-0000-0000-0000-0000000000a1') <> 'matching' then
    raise exception 'FAIL ①: 오퍼 생성 후 open→matching 전이 안 됨';
  end if;
end $$;

set local request.jwt.claims = '{"sub":"fb000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
do $$ declare v_offer uuid; v_assign uuid; begin
  select id into v_offer from match_offers
   where request_id='fb000000-0000-0000-0000-0000000000a1'
     and worker_id ='fb000000-0000-0000-0000-0000000000d1';
  v_assign := accept_offer(v_offer);
  if v_assign is null then raise exception 'FAIL ①: accept_offer가 배정 id를 반환하지 않음'; end if;
  if (select status from assignments where id = v_assign) <> 'confirmed' then
    raise exception 'FAIL ①: 배정 상태 confirmed 아님';
  end if;
  if (select (status, filled_count) from job_requests
      where id='fb000000-0000-0000-0000-0000000000a1') <> ('confirmed'::request_status, 1) then
    raise exception 'FAIL ①: 수락 후 요청 confirmed/filled=1 아님';
  end if;
  raise notice 'PASS ①: run_match→A 수락→요청 confirmed·filled_count=1';
end $$;

-- ────────────────────────────────────────────────────────────────────
-- ⑥ 비당사자·비소유 차단 (A의 r1 배정이 confirmed인 지금 시점에 검사해야
--    "상태가 아니라 권한 때문에 거부됨"이 분명해진다)
-- ────────────────────────────────────────────────────────────────────
set local request.jwt.claims = '{"sub":"fb000000-0000-0000-0000-0000000000d3","role":"authenticated"}';
do $$ declare v_a1 uuid; ok boolean := false; begin
  select id into v_a1 from assignments
   where request_id='fb000000-0000-0000-0000-0000000000a1'
     and worker_id ='fb000000-0000-0000-0000-0000000000d1';
  begin
    perform cancel_assignment(v_a1);
  exception when others then
    ok := (sqlerrm like '%not_allowed_or_bad_state%');
  end;
  if not ok then raise exception 'FAIL ⑥a: 제3근로자 C의 타인 배정 취소가 차단되지 않음'; end if;
  raise notice 'PASS ⑥a: 타 근로자의 cancel_assignment 차단(not_allowed_or_bad_state)';
end $$;

set local request.jwt.claims = '{"sub":"fb000000-0000-0000-0000-0000000000e2","role":"authenticated"}';
do $$ declare v_a1 uuid; ok boolean := false; begin
  select id into v_a1 from assignments
   where request_id='fb000000-0000-0000-0000-0000000000a1'
     and worker_id ='fb000000-0000-0000-0000-0000000000d1';
  begin
    perform report_no_show(v_a1);
  exception when others then
    ok := (sqlerrm like '%not_allowed_or_bad_state%');
  end;
  if not ok then raise exception 'FAIL ⑥b: 타 사장의 report_no_show가 차단되지 않음'; end if;
  raise notice 'PASS ⑥b: 비소유 사장의 report_no_show 차단';
end $$;

set local request.jwt.claims = '{"sub":"fb000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
do $$ declare v_a1 uuid; ok boolean := false; begin
  select id into v_a1 from assignments
   where request_id='fb000000-0000-0000-0000-0000000000a1'
     and worker_id ='fb000000-0000-0000-0000-0000000000d1';
  begin
    perform report_no_show(v_a1);  -- 근로자 본인이 사장 전용 RPC 호출
  exception when others then
    ok := (sqlerrm like '%not_allowed_or_bad_state%');
  end;
  if not ok then raise exception 'FAIL ⑥c: 근로자의 report_no_show 호출이 차단되지 않음'; end if;
  -- 차단 시도들이 부수효과를 남기지 않았는지
  if (select status from assignments where id = v_a1) <> 'confirmed' then
    raise exception 'FAIL ⑥: 차단된 호출이 배정 상태를 바꿈';
  end if;
  if exists (select 1 from penalties where profile_id='fb000000-0000-0000-0000-0000000000d1') then
    raise exception 'FAIL ⑥: 차단된 호출이 페널티를 남김';
  end if;
  raise notice 'PASS ⑥c: 근로자의 report_no_show 차단 + 부수효과 없음';
end $$;

-- ────────────────────────────────────────────────────────────────────
-- ② A 여유 취소(시작 5h 전 > 2h) → declined(무페널티) + 자동 백필로 B에게 새 오퍼
-- ────────────────────────────────────────────────────────────────────
set local request.jwt.claims = '{"sub":"fb000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
do $$ declare v_a1 uuid; v int; ok boolean := false; begin
  select id into v_a1 from assignments
   where request_id='fb000000-0000-0000-0000-0000000000a1'
     and worker_id ='fb000000-0000-0000-0000-0000000000d1';
  v := cancel_assignment(v_a1);

  -- 배정 전이·요청 복구
  if (select status from assignments where id = v_a1) <> 'cancelled_worker' then
    raise exception 'FAIL ②: 배정이 cancelled_worker로 전이되지 않음';
  end if;
  if (select filled_count from job_requests
      where id='fb000000-0000-0000-0000-0000000000a1') <> 0 then
    raise exception 'FAIL ②: filled_count가 감소하지 않음';
  end if;
  -- auto_backfill=true: status는 open 복귀 후 run_match 성공으로 matching이 최종 상태
  if (select status from job_requests
      where id='fb000000-0000-0000-0000-0000000000a1') <> 'matching' then
    raise exception 'FAIL ②: 백필 후 요청 상태 기대 matching, 실제 %',
      (select status from job_requests where id='fb000000-0000-0000-0000-0000000000a1');
  end if;

  -- 백필: 반경 내 신규 후보는 B뿐(C 비가용, P·N 28km 밖) → 정확히 1건
  if v <> 1 then raise exception 'FAIL ②: 백필 신규 오퍼 기대 1(B), 실제 %', v; end if;
  if not exists (select 1 from match_offers
                 where request_id='fb000000-0000-0000-0000-0000000000a1'
                   and worker_id ='fb000000-0000-0000-0000-0000000000d2'
                   and status='offered') then
    raise exception 'FAIL ②: 백필 오퍼가 B에게 생성되지 않음';
  end if;
  -- ⑤ 취소한 A는 백필 대상에서 제외(기존 accepted 오퍼 행 1건 그대로)
  if (select count(*) from match_offers
      where request_id='fb000000-0000-0000-0000-0000000000a1'
        and worker_id ='fb000000-0000-0000-0000-0000000000d1') <> 1 then
    raise exception 'FAIL ⑤: 취소한 A가 백필에서 재오퍼받음';
  end if;

  -- 여유 취소 = declined 이벤트, 페널티 없음, 신뢰도 무감점(50 유지)
  if (select count(*) from reliability_events
      where assignment_id = v_a1 and profile_id='fb000000-0000-0000-0000-0000000000d1'
        and kind='declined') <> 1 then
    raise exception 'FAIL ③(여유면): declined 이벤트가 정확히 1건이 아님';
  end if;
  if exists (select 1 from penalties where assignment_id = v_a1) then
    raise exception 'FAIL ③(여유면): 여유 취소인데 페널티가 생성됨';
  end if;
  if (select reliability_score from worker_profiles
      where profile_id='fb000000-0000-0000-0000-0000000000d1') <> 50 then
    raise exception 'FAIL ③(여유면): 여유 취소인데 신뢰도가 50에서 변동됨';
  end if;

  -- ⑥d 상태머신: 이미 취소된 배정 재취소 차단
  begin
    perform cancel_assignment(v_a1);
  exception when others then
    ok := (sqlerrm like '%not_allowed_or_bad_state%');
  end;
  if not ok then raise exception 'FAIL ⑥d: 취소된 배정의 재취소가 차단되지 않음'; end if;
  raise notice 'PASS ②⑤⑥d: 여유취소→declined·무페널티·filled 0·B 백필 오퍼·A 제외·재취소 차단';
end $$;

-- ────────────────────────────────────────────────────────────────────
-- ③ r2: A 수락 후 임박 취소(시작 1h 전 < 2h) → late_cancel 페널티 + 신뢰도 -8
-- ────────────────────────────────────────────────────────────────────
do $$ declare v int; begin
  v := run_match('fb000000-0000-0000-0000-0000000000a2', 3000, 0, 1, 600, false);
  if v <> 1 or not exists (select 1 from match_offers
      where request_id='fb000000-0000-0000-0000-0000000000a2'
        and worker_id ='fb000000-0000-0000-0000-0000000000d1') then
    raise exception 'FAIL ③: r2 wave=1 오퍼가 A에게 1건 생성되지 않음(실제 %건)', v;
  end if;
end $$;

set local request.jwt.claims = '{"sub":"fb000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
do $$ declare v_offer uuid; v_assign uuid; v int; begin
  select id into v_offer from match_offers
   where request_id='fb000000-0000-0000-0000-0000000000a2'
     and worker_id ='fb000000-0000-0000-0000-0000000000d1';
  v_assign := accept_offer(v_offer);
  v := cancel_assignment(v_assign);

  if (select count(*) from penalties
      where assignment_id = v_assign and profile_id='fb000000-0000-0000-0000-0000000000d1'
        and kind='late_cancel') <> 1 then
    raise exception 'FAIL ③: 임박 취소인데 late_cancel 페널티가 정확히 1건이 아님';
  end if;
  if (select count(*) from reliability_events
      where assignment_id = v_assign and kind='late_cancel') <> 1 then
    raise exception 'FAIL ③: late_cancel 신뢰 이벤트 누락';
  end if;
  -- recompute: 50 + declined(0) + late_cancel(-8) = 42
  if (select reliability_score from worker_profiles
      where profile_id='fb000000-0000-0000-0000-0000000000d1') <> 42 then
    raise exception 'FAIL ③: late_cancel 후 신뢰도 기대 42, 실제 %',
      (select reliability_score from worker_profiles
       where profile_id='fb000000-0000-0000-0000-0000000000d1');
  end if;
  -- 임박 취소도 백필은 동일 동작: B에게 신규 오퍼
  if v <> 1 or not exists (select 1 from match_offers
      where request_id='fb000000-0000-0000-0000-0000000000a2'
        and worker_id ='fb000000-0000-0000-0000-0000000000d2' and status='offered') then
    raise exception 'FAIL ③: 임박 취소 백필이 B에게 오퍼를 만들지 않음(신규 %건)', v;
  end if;
  raise notice 'PASS ③: 임박취소→late_cancel 페널티·신뢰도 42·백필 정상';
end $$;

-- ────────────────────────────────────────────────────────────────────
-- ④ r3: A 수락 확정 → 사장 report_no_show → no_show 페널티·신뢰도 -20·백필
-- ────────────────────────────────────────────────────────────────────
do $$ declare v int; begin
  v := run_match('fb000000-0000-0000-0000-0000000000a3', 3000, 0, 1, 600, false);
  -- A(신뢰 42): 0.6*(1-93/3000)+0.4*0.42=0.749 > B(신뢰 50): 0.526+0.2=0.726 → 여전히 A 단독
  if v <> 1 or not exists (select 1 from match_offers
      where request_id='fb000000-0000-0000-0000-0000000000a3'
        and worker_id ='fb000000-0000-0000-0000-0000000000d1') then
    raise exception 'FAIL ④: r3 wave=1 오퍼가 A에게 1건 생성되지 않음(실제 %건)', v;
  end if;
end $$;

set local request.jwt.claims = '{"sub":"fb000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
do $$ declare v_offer uuid; begin
  select id into v_offer from match_offers
   where request_id='fb000000-0000-0000-0000-0000000000a3'
     and worker_id ='fb000000-0000-0000-0000-0000000000d1';
  perform accept_offer(v_offer);
end $$;

set local request.jwt.claims = '{"sub":"fb000000-0000-0000-0000-0000000000e1","role":"authenticated"}';
do $$ declare v_assign uuid; v int; ok boolean := false; begin
  select id into v_assign from assignments
   where request_id='fb000000-0000-0000-0000-0000000000a3'
     and worker_id ='fb000000-0000-0000-0000-0000000000d1';
  v := report_no_show(v_assign);

  if (select status from assignments where id = v_assign) <> 'no_show' then
    raise exception 'FAIL ④: 배정이 no_show로 전이되지 않음';
  end if;
  if (select count(*) from penalties
      where assignment_id = v_assign and profile_id='fb000000-0000-0000-0000-0000000000d1'
        and kind='no_show') <> 1 then
    raise exception 'FAIL ④: no_show 페널티가 정확히 1건이 아님';
  end if;
  if (select count(*) from reliability_events
      where assignment_id = v_assign and kind='no_show') <> 1 then
    raise exception 'FAIL ④: no_show 신뢰 이벤트 누락';
  end if;
  -- recompute: 50 + declined(0) + late_cancel(-8) + no_show(-20) = 22
  if (select reliability_score from worker_profiles
      where profile_id='fb000000-0000-0000-0000-0000000000d1') <> 22 then
    raise exception 'FAIL ④: no_show 후 신뢰도 기대 22, 실제 %',
      (select reliability_score from worker_profiles
       where profile_id='fb000000-0000-0000-0000-0000000000d1');
  end if;
  -- 백필: filled 0 복귀 + B에게 신규 오퍼 + 요청 matching
  if (select (status, filled_count) from job_requests
      where id='fb000000-0000-0000-0000-0000000000a3') <> ('matching'::request_status, 0) then
    raise exception 'FAIL ④: 노쇼 백필 후 요청 (matching,0) 아님';
  end if;
  if v <> 1 or not exists (select 1 from match_offers
      where request_id='fb000000-0000-0000-0000-0000000000a3'
        and worker_id ='fb000000-0000-0000-0000-0000000000d2' and status='offered') then
    raise exception 'FAIL ④: 노쇼 백필이 B에게 오퍼를 만들지 않음(신규 %건)', v;
  end if;
  -- ⑤ 노쇼 A 재오퍼 제외
  if (select count(*) from match_offers
      where request_id='fb000000-0000-0000-0000-0000000000a3'
        and worker_id ='fb000000-0000-0000-0000-0000000000d1') <> 1 then
    raise exception 'FAIL ⑤: 노쇼 처리된 A가 백필에서 재오퍼받음';
  end if;

  -- ⑥e 상태머신: no_show 배정에 대한 중복 신고 차단
  begin
    perform report_no_show(v_assign);
  exception when others then
    ok := (sqlerrm like '%not_allowed_or_bad_state%');
  end;
  if not ok then raise exception 'FAIL ⑥e: no_show 배정 재신고가 차단되지 않음'; end if;
  raise notice 'PASS ④⑤⑥e: 노쇼→페널티·신뢰도 22·백필·A 제외·중복 신고 차단';
end $$;

-- ────────────────────────────────────────────────────────────────────
-- ⑦ (정보) r4: A·B 동시 오퍼(wave=2) → A 수락 시 B 오퍼 형제취소(cancelled)
--    → A 취소 시 B가 백필 재오퍼를 받는가? 현 run_match는 status 무관하게
--    기오퍼 행 존재만으로 제외하므로(unique(request_id,worker_id)) 재오퍼 불가가
--    예상 — 어느 쪽이든 실패시키지 않고 관찰 결과만 남긴다(버그 후보는 보고서로).
-- ────────────────────────────────────────────────────────────────────
do $$ declare v int; begin
  v := run_match('fb000000-0000-0000-0000-0000000000a4', 3000, 0, 2, 600, false);
  if v <> 2 then raise exception 'FAIL ⑦(셋업): wave=2 오퍼 기대 2(A·B), 실제 %', v; end if;
end $$;

set local request.jwt.claims = '{"sub":"fb000000-0000-0000-0000-0000000000d1","role":"authenticated"}';
do $$ declare v_offer uuid; v_assign uuid; v int; v_b_status offer_status; begin
  select id into v_offer from match_offers
   where request_id='fb000000-0000-0000-0000-0000000000a4'
     and worker_id ='fb000000-0000-0000-0000-0000000000d1';
  v_assign := accept_offer(v_offer);
  select status into v_b_status from match_offers
   where request_id='fb000000-0000-0000-0000-0000000000a4'
     and worker_id ='fb000000-0000-0000-0000-0000000000d2';
  if v_b_status <> 'cancelled' then
    raise exception 'FAIL ⑦(셋업): 인원 충족 시 형제 오퍼 자동취소 안 됨(B=%)', v_b_status;
  end if;

  v := cancel_assignment(v_assign);  -- 여유 취소 → 백필 시도
  if (select filled_count from job_requests
      where id='fb000000-0000-0000-0000-0000000000a4') <> 0 then
    raise exception 'FAIL ⑦: 취소 후 filled_count 미감소';
  end if;
  if (select count(*) from match_offers
      where request_id='fb000000-0000-0000-0000-0000000000a4'
        and worker_id ='fb000000-0000-0000-0000-0000000000d1') <> 1 then
    raise exception 'FAIL ⑤: 취소한 A가 r4 백필에서 재오퍼받음';
  end if;
  if not exists (select 1 from match_offers
             where request_id='fb000000-0000-0000-0000-0000000000a4'
               and worker_id ='fb000000-0000-0000-0000-0000000000d2'
               and status='offered') then
    raise exception 'FAIL ⑦: 형제취소 근로자 B가 백필에서 재오퍼 안 됨(0028 회귀) — 신규 오퍼 %건, 요청 상태 %',
      v, (select status from job_requests where id='fb000000-0000-0000-0000-0000000000a4');
  end if;
  raise notice 'PASS ⑦: 형제취소 근로자 B 백필 재오퍼(0028) + filled 0·취소자 A 제외';
end $$;

-- ────────────────────────────────────────────────────────────────────
-- ⑧ r5(requires_professional=true, 지점2): P만 1차 오퍼 → P 수락 → P 취소
--    → 0028: 백필 run_match가 requires_professional을 승계 — 비전문 N 제외 assert.
--    (승계 정상이면 후보는 P뿐인데 P는 방금 취소한 accepted 이력으로 제외 → 신규 0건이 정상)
-- ────────────────────────────────────────────────────────────────────
do $$ declare v int; begin
  v := run_match('fb000000-0000-0000-0000-0000000000a5', 3000, 0, 3, 600, true);
  if v <> 1 or not exists (select 1 from match_offers
      where request_id='fb000000-0000-0000-0000-0000000000a5'
        and worker_id ='fb000000-0000-0000-0000-0000000000d4') then
    raise exception 'FAIL ⑧(셋업): 전문요구 1차 매칭이 P 단독 1건이 아님(%건)', v;
  end if;
end $$;

set local request.jwt.claims = '{"sub":"fb000000-0000-0000-0000-0000000000d4","role":"authenticated"}';
do $$ declare v_offer uuid; v_assign uuid; v int; begin
  select id into v_offer from match_offers
   where request_id='fb000000-0000-0000-0000-0000000000a5'
     and worker_id ='fb000000-0000-0000-0000-0000000000d4';
  v_assign := accept_offer(v_offer);
  v := cancel_assignment(v_assign);  -- 시작 6h 전 여유 취소 → 백필
  if exists (select 1 from match_offers
             where request_id='fb000000-0000-0000-0000-0000000000a5'
               and worker_id ='fb000000-0000-0000-0000-0000000000d5'
               and status='offered') then
    raise exception 'FAIL ⑧: 전문요구 요청의 백필이 비전문 N에게 오퍼 — requires_professional 미승계(0028 회귀, 신규 %건)', v;
  end if;
  raise notice 'PASS ⑧: 전문요구 백필이 비전문 N 제외(요구 승계, 0028)';
end $$;

rollback;
