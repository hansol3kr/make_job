-- =====================================================================
-- 0009 신뢰/안전 RPC [P3] — 더블블라인드 평점 · 노쇼/취소·자동백필 · 본인확인
-- 모든 변이 SECURITY DEFINER + auth.uid() 귀속.
-- =====================================================================
set search_path = public, extensions;

-- 온보딩 자동 본인인증 제거 → 실제 본인확인 플로우가 게이트가 되도록.
-- (기존 0005는 identity_verified_at=now()로 자동승인했음)
create or replace function public.complete_worker_onboarding(
  p_display_name text,
  p_lng double precision,
  p_lat double precision
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_geog extensions.geography;
begin
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

-- 본인확인 제출(MVP 스텁: 즉시 승인. 실 본인확인기관 연동 전까지. 원문 식별정보 미저장, ref만).
create or replace function public.submit_identity_verification(
  p_real_name    text,
  p_bank         text default null,
  p_account_ref  text default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into verifications (profile_id, type, status, provider, ref, verified_at)
    values (auth.uid(), 'identity', 'verified', 'stub', p_account_ref, now());
  update worker_profiles
     set identity_verified_at = coalesce(identity_verified_at, now()),
         bank_verified_at = case when p_account_ref is not null
                                 then coalesce(bank_verified_at, now()) else bank_verified_at end,
         tier = case when tier = 'standard' then 'verified' else tier end
   where profile_id = auth.uid();
  update profiles set display_name = coalesce(display_name, p_real_name) where id = auth.uid();
end; $$;

-- 근로자 상태(홈 배너/신뢰 요약)
create or replace function public.my_reliability_summary()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'reliability', w.reliability_score,
    'tier', w.tier,
    'identity_verified', w.identity_verified_at is not null,
    'bank_verified', w.bank_verified_at is not null,
    'is_available', w.is_available,
    'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.occurred_at)
                                         order by e.occurred_at desc)
                        from reliability_events e
                        where e.profile_id = auth.uid()
                          and e.occurred_at > now() - interval '180 days'), '[]'::jsonb),
    'penalties', coalesce((select jsonb_agg(jsonb_build_object('kind', p.kind, 'reason', p.reason,
                                                              'waived', p.waived, 'at', p.created_at)
                                            order by p.created_at desc)
                           from penalties p where p.profile_id = auth.uid()), '[]'::jsonb)
  ) from worker_profiles w where w.profile_id = auth.uid();
$$;

-- 더블블라인드 평점 제출: 상대 방향이 이미 있으면 양측 공개.
create or replace function public.submit_rating(
  p_assignment_id uuid,
  p_stars         int,
  p_sub_scores    jsonb default null,
  p_comment       text  default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_worker uuid; v_employer uuid;
  v_dir rating_dir; v_other rating_dir; v_ratee uuid;
begin
  if p_stars < 1 or p_stars > 5 then raise exception 'stars_out_of_range'; end if;
  select a.worker_id, r.employer_id into v_worker, v_employer
    from assignments a join job_requests r on r.id = a.request_id
   where a.id = p_assignment_id;
  if v_worker is null then raise exception 'assignment_not_found'; end if;

  if v_uid = v_worker then
    v_dir := 'worker_to_employer'; v_other := 'employer_to_worker'; v_ratee := v_employer;
  elsif v_uid = v_employer then
    v_dir := 'employer_to_worker'; v_other := 'worker_to_employer'; v_ratee := v_worker;
  else raise exception 'not_a_party'; end if;

  insert into ratings (assignment_id, rater_id, ratee_id, direction, stars, sub_scores, comment)
    values (p_assignment_id, v_uid, v_ratee, v_dir, p_stars, p_sub_scores, p_comment)
    on conflict (assignment_id, direction) do nothing;

  if exists (select 1 from ratings where assignment_id = p_assignment_id and direction = v_other) then
    update ratings set revealed_at = now()
     where assignment_id = p_assignment_id and revealed_at is null;
  end if;
end; $$;

-- 배정의 평점 현황(내 것 + 공개된 상대 것). 더블블라인드 존중.
create or replace function public.ratings_for_assignment(p_assignment_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_worker uuid; v_employer uuid; v jsonb;
begin
  select a.worker_id, r.employer_id into v_worker, v_employer
    from assignments a join job_requests r on r.id = a.request_id where a.id = p_assignment_id;
  if v_uid <> v_worker and v_uid <> v_employer then raise exception 'not_a_party'; end if;
  select jsonb_build_object(
    'mine', (select jsonb_build_object('stars', stars, 'comment', comment, 'sub_scores', sub_scores)
             from ratings where assignment_id = p_assignment_id and rater_id = v_uid),
    'theirs', (select jsonb_build_object('stars', stars, 'comment', comment, 'sub_scores', sub_scores)
               from ratings where assignment_id = p_assignment_id and rater_id <> v_uid
                 and revealed_at is not null),
    'revealed', exists (select 1 from ratings where assignment_id = p_assignment_id
                          and rater_id <> v_uid and revealed_at is not null)
  ) into v;
  return v;
end; $$;

-- 노쇼 신고(업주): 배정 no_show + 신뢰이벤트/페널티 + 자동 백필(재매칭).
create or replace function public.report_no_show(p_assignment_id uuid)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare v_worker uuid; v_request uuid; v_auto boolean;
begin
  select a.worker_id, a.request_id into v_worker, v_request
    from assignments a join job_requests r on r.id = a.request_id
   where a.id = p_assignment_id and r.employer_id = auth.uid()
     and a.status in ('confirmed', 'checked_in');
  if v_worker is null then raise exception 'not_allowed_or_bad_state'; end if;

  update assignments set status = 'no_show' where id = p_assignment_id;
  insert into reliability_events (profile_id, assignment_id, kind)
    values (v_worker, p_assignment_id, 'no_show');
  insert into penalties (profile_id, assignment_id, kind, reason)
    values (v_worker, p_assignment_id, 'no_show', '노쇼(근무 미이행)');
  perform recompute_reliability(v_worker);

  update job_requests
     set filled_count = greatest(0, filled_count - 1),
         status = case when auto_backfill then 'open' else status end
   where id = v_request;
  select auto_backfill into v_auto from job_requests where id = v_request;
  if v_auto then return public.run_match(v_request); end if;
  return 0;
end; $$;

-- 근로자 취소: 임박(2h 내) 취소는 late_cancel(페널티), 그 외 declined(경미). 자동 백필.
create or replace function public.cancel_assignment(p_assignment_id uuid)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare v_request uuid; v_start timestamptz; v_kind reliability_kind; v_auto boolean;
begin
  select a.request_id, r.start_at into v_request, v_start
    from assignments a join job_requests r on r.id = a.request_id
   where a.id = p_assignment_id and a.worker_id = auth.uid() and a.status = 'confirmed';
  if v_request is null then raise exception 'not_allowed_or_bad_state'; end if;

  update assignments set status = 'cancelled_worker' where id = p_assignment_id;
  v_kind := case when v_start - now() < interval '2 hours' then 'late_cancel' else 'declined' end;
  insert into reliability_events (profile_id, assignment_id, kind)
    values (auth.uid(), p_assignment_id, v_kind);
  if v_kind = 'late_cancel' then
    insert into penalties (profile_id, assignment_id, kind, reason)
      values (auth.uid(), p_assignment_id, 'late_cancel', '근무 임박 취소');
  end if;
  perform recompute_reliability(auth.uid());

  update job_requests
     set filled_count = greatest(0, filled_count - 1),
         status = case when auto_backfill then 'open' else status end
   where id = v_request;
  select auto_backfill into v_auto from job_requests where id = v_request;
  if v_auto then return public.run_match(v_request); end if;
  return 0;
end; $$;

-- 실행 권한
grant execute on function public.submit_identity_verification(text,text,text) to authenticated;
grant execute on function public.my_reliability_summary() to authenticated;
grant execute on function public.submit_rating(uuid,int,jsonb,text) to authenticated;
grant execute on function public.ratings_for_assignment(uuid) to authenticated;
grant execute on function public.report_no_show(uuid) to authenticated;
grant execute on function public.cancel_assignment(uuid) to authenticated;
