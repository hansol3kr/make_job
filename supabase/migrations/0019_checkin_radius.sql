-- =====================================================================
-- 0019 GPS 체크인 반경검증 — 근무지에서 멀리 떨어진 허위 체크인 차단
--  · check_in(0002)의 기존 로직은 그대로 보존하고, 근무지까지 거리 검증만 추가.
--  · 반경은 platform_settings.checkin_radius_m(기본 500m — GPS 오차·큰 사업장 대비)로
--    코드 배포 없이 조정. 초과 시 'too_far_from_site:<거리>' 예외로 앱이 안내.
--  · 좌표/근무지 위치가 없으면 검증을 건너뛰어 기존 동작과 하위호환.
-- =====================================================================
set search_path = public, extensions;

-- 체크인 허용 반경(m). platform_settings는 0017에서 생성됨.
insert into platform_settings (key, value) values ('checkin_radius_m', '500'::jsonb)
  on conflict (key) do nothing;

create or replace function public.check_in(
  p_assignment_id uuid, p_lng double precision, p_lat double precision
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_point  geography;
  v_site   geography;
  v_dist   numeric;
  v_radius numeric;
begin
  -- 근무지 위치(내 배정만). 없으면(비소유/미존재) 검증 스킵 → 기존과 동일.
  select r.geog into v_site
    from assignments a join job_requests r on r.id = a.request_id
   where a.id = p_assignment_id and a.worker_id = auth.uid();

  if p_lng is not null and p_lat is not null and v_site is not null then
    v_point := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
    v_dist  := st_distance(v_point, v_site);
    select coalesce((value)::numeric, 500) into v_radius
      from platform_settings where key = 'checkin_radius_m';
    if v_dist > coalesce(v_radius, 500) then
      raise exception 'too_far_from_site:%', round(v_dist)::int;
    end if;
  end if;

  -- ↓↓ 0002 원본 로직 그대로 ↓↓
  update assignments
     set status = 'checked_in', check_in_at = now(),
         check_in_geog = st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography
   where id = p_assignment_id and worker_id = auth.uid() and status = 'confirmed';
  update job_requests r set status = 'in_progress'
    from assignments a
   where a.id = p_assignment_id and a.request_id = r.id and r.status = 'confirmed';
end; $$;
