-- =====================================================================
-- 0018 실시간 위치 공유 — 안전 번들 완성(채팅 0011·SOS 0011에 이어)
--  · 근무 중(checked_in) 근로자가 위치를 주기적으로 공유 → 상대 당사자가 확인.
--  · 근무지까지 거리를 서버에서 계산해 저장(지도 없이도 "근무지에서 ~Xm" 표시).
--  · 배정당 공유자 1행(upsert). RLS는 is_contract_party(0003) 재사용.
-- =====================================================================
set search_path = public, extensions;

create table if not exists live_locations (
  assignment_id  uuid not null references assignments(id) on delete cascade,
  sharer_id      uuid not null references profiles(id),
  geog           extensions.geography(Point, 4326) not null,
  dist_to_site_m int,
  updated_at     timestamptz not null default now(),
  primary key (assignment_id, sharer_id)
);
alter table live_locations enable row level security;

-- 읽기: 배정 당사자만. 쓰기는 update_live_location RPC로만.
drop policy if exists live_loc_party_read on live_locations;
create policy live_loc_party_read on live_locations for select
  using (public.is_contract_party(assignment_id));

-- 위치 갱신(upsert) + 근무지까지 거리 계산. 당사자 검증.
create or replace function public.update_live_location(
  p_assignment uuid, p_lat double precision, p_lng double precision)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_point geography; v_site geography; v_dist int;
begin
  if not public.is_contract_party(p_assignment) then
    raise exception 'not a party to this assignment';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'no_coords';
  end if;
  v_point := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  select r.geog into v_site
    from assignments a join job_requests r on r.id = a.request_id
   where a.id = p_assignment;
  v_dist := case when v_site is not null
                 then round(st_distance(v_point, v_site))::int else null end;

  insert into live_locations (assignment_id, sharer_id, geog, dist_to_site_m, updated_at)
    values (p_assignment, auth.uid(), v_point, v_dist, now())
  on conflict (assignment_id, sharer_id) do update
    set geog = excluded.geog,
        dist_to_site_m = excluded.dist_to_site_m,
        updated_at = now();
end; $$;

-- 공유 종료(체크아웃 등): 내 공유행 삭제.
create or replace function public.stop_live_location(p_assignment uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from live_locations
   where assignment_id = p_assignment and sharer_id = auth.uid();
end; $$;

grant select, insert, update, delete on live_locations to authenticated;
grant execute on function public.update_live_location(uuid, double precision, double precision) to authenticated;
grant execute on function public.stop_live_location(uuid) to authenticated;

alter publication supabase_realtime add table live_locations;
