-- =============================================================================
-- 0007_regions — 전국 지역 레퍼런스(시/도 → 시/군/구)
--
-- 용도: 실 GPS가 거부/불가할 때 사용자가 수동으로 활동지역을 고르는 소스,
--       그리고 지역 필터/표시용. 각 시군구의 대략 중심좌표를 보관(반경 매칭 fallback).
--       실제 정확한 위치는 GPS. 좌표는 근사 중심값.
--
-- 데이터: 별도 시드(0007_regions_seed.sql)로 삽입(멀티에이전트 생성 → 검증).
-- =============================================================================

create table if not exists public.regions (
  id       bigint generated always as identity primary key,
  sido     text not null,                 -- 시/도 (예: 서울특별시)
  sigungu  text not null,                 -- 시/군/구 (예: 강남구, 성남시 분당구). 세종은 시 자체
  lat      double precision not null,      -- 근사 중심 위도(WGS84)
  lng      double precision not null,      -- 근사 중심 경도(WGS84)
  unique (sido, sigungu)
);

create index if not exists regions_sido_idx on public.regions (sido);

-- 읽기 전용 레퍼런스: 누구나 조회, 쓰기 없음.
alter table public.regions enable row level security;
drop policy if exists regions_read on public.regions;
create policy regions_read on public.regions
  for select to anon, authenticated
  using (true);

grant select on public.regions to anon, authenticated;
