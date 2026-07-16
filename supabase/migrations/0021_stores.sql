-- =====================================================================
-- 0021 업장(매장) 다중화 — 한 사장님이 여러 매장을 두고 매장별로 요청
--  · employer_profiles.default_geog(단일)를 stores 테이블로 확장.
--  · 기존 사장님 데이터는 "기본 매장"으로 백필(무손실). default_geog는 fallback 유지.
--  · create_job_request는 store_id를 받아 그 매장 위치로 매칭(0017 최저임금 로직 보존).
-- =====================================================================
set search_path = public, extensions;

create table if not exists stores (
  id          uuid primary key default gen_random_uuid(),
  employer_id uuid not null references employer_profiles(profile_id) on delete cascade,
  name        text not null,
  address     text,
  geog        extensions.geography(Point, 4326) not null,
  is_default  boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists stores_employer_ix on stores (employer_id, created_at);
alter table stores enable row level security;

drop policy if exists stores_owner_read on stores;
create policy stores_owner_read on stores for select using (employer_id = auth.uid());

alter table job_requests add column if not exists store_id uuid references stores(id) on delete set null;

-- 기존 사장님 default_geog → "기본 매장" 백필(매장 없는 사장님만, 재실행 안전).
insert into stores (employer_id, name, address, geog, is_default)
select ep.profile_id, coalesce(ep.business_name, '기본 매장'), ep.default_address, ep.default_geog, true
from employer_profiles ep
where ep.default_geog is not null
  and not exists (select 1 from stores s where s.employer_id = ep.profile_id);

-- ── 매장 CRUD (전부 본인 소유만) ─────────────────────────────────────────────
create or replace function public.my_stores()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'name', name, 'address', address, 'is_default', is_default
         ) order by is_default desc, created_at), '[]'::jsonb)
  from stores where employer_id = auth.uid();
$$;

create or replace function public.add_store(
  p_name text, p_lat double precision, p_lng double precision,
  p_address text default null, p_is_default boolean default false
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid; v_first boolean;
begin
  if coalesce(trim(p_name),'') = '' then raise exception 'empty_name'; end if;
  if p_lat is null or p_lng is null then raise exception 'no_location'; end if;
  -- 첫 매장은 자동 기본. 명시 기본이면 기존 기본 해제.
  select not exists(select 1 from stores where employer_id = auth.uid()) into v_first;
  if p_is_default or v_first then
    update stores set is_default = false where employer_id = auth.uid();
  end if;
  insert into stores (employer_id, name, address, geog, is_default)
  values (auth.uid(), trim(p_name), p_address,
          st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography,
          p_is_default or v_first)
  returning id into v_id;
  return v_id;
end; $$;

create or replace function public.update_store(
  p_id uuid, p_name text default null, p_lat double precision default null,
  p_lng double precision default null, p_address text default null
) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  update stores set
    name    = coalesce(nullif(trim(coalesce(p_name,'')),''), name),
    address = coalesce(p_address, address),
    geog    = case when p_lat is not null and p_lng is not null
                   then st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography else geog end
  where id = p_id and employer_id = auth.uid();
  if not found then raise exception 'store_not_found'; end if;
end; $$;

create or replace function public.set_default_store(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from stores where id = p_id and employer_id = auth.uid()) then
    raise exception 'store_not_found';
  end if;
  update stores set is_default = (id = p_id) where employer_id = auth.uid();
end; $$;

create or replace function public.delete_store(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_was_default boolean;
begin
  delete from stores where id = p_id and employer_id = auth.uid()
    returning is_default into v_was_default;
  if not found then raise exception 'store_not_found'; end if;
  -- 기본 매장을 지웠으면 남은 것 중 하나를 기본으로.
  if v_was_default then
    update stores set is_default = true
     where id = (select id from stores where employer_id = auth.uid()
                 order by created_at limit 1);
  end if;
end; $$;

-- ── create_job_request v3: store_id 지원(0017 최저임금 로직 보존) ────────────
drop function if exists public.create_job_request(text,timestamptz,timestamptz,int,int,uuid,double precision,double precision,text,text,boolean);
create or replace function public.create_job_request(
  p_title       text,
  p_start_at    timestamptz,
  p_end_at      timestamptz,
  p_pay_amount  int,
  p_headcount   int default 1,
  p_category_id uuid default null,
  p_lng         double precision default null,
  p_lat         double precision default null,
  p_address     text default null,
  p_pay_type    text default 'daily',
  p_require_professional boolean default false,
  p_store_id    uuid default null
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_geog extensions.geography; v_addr text; v_id uuid;
  v_min numeric; v_hours numeric;
begin
  -- 위치 우선순위: 명시 좌표 > 지정 매장 > 사장님 기본(default_geog)
  if p_store_id is not null then
    select geog, address into v_geog, v_addr
      from stores where id = p_store_id and employer_id = auth.uid();
    if v_geog is null then raise exception 'store_not_found'; end if;
  else
    select default_geog, default_address into v_geog, v_addr
      from employer_profiles where profile_id = auth.uid();
  end if;
  if v_geog is null and (p_lng is null or p_lat is null) then raise exception 'no_location'; end if;
  if p_lng is not null and p_lat is not null then
    v_geog := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  end if;

  -- 최저임금 검증(0017 유지)
  select (value)::numeric into v_min from platform_settings where key = 'min_wage_hourly';
  if p_pay_type = 'hourly' then
    if p_pay_amount < coalesce(v_min, 0) then raise exception 'below_minimum_wage'; end if;
  else
    v_hours := extract(epoch from (p_end_at - p_start_at)) / 3600.0;
    if v_hours > 0 and (p_pay_amount / v_hours) < coalesce(v_min, 0) then
      raise exception 'below_minimum_wage';
    end if;
  end if;

  insert into job_requests (employer_id, category_id, title, geog, address,
                            start_at, end_at, headcount, pay_type, pay_amount, status,
                            requires_professional, store_id)
  values (auth.uid(), p_category_id, p_title, v_geog, coalesce(p_address, v_addr),
          p_start_at, p_end_at, greatest(1, p_headcount), p_pay_type, greatest(0, p_pay_amount),
          'open', coalesce(p_require_professional, false), p_store_id)
  returning id into v_id;
  return v_id;
end; $$;

-- ── 온보딩: 기본 매장도 생성(신규 사장님이 매장 1개 확보) ─────────────────────
create or replace function public.complete_employer_onboarding(
  p_business_name text, p_lng double precision, p_lat double precision,
  p_address text default null
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_geog extensions.geography;
begin
  v_geog := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  update profiles
     set role = case when exists (select 1 from worker_profiles where profile_id = auth.uid())
                     then 'both'::user_role else 'employer'::user_role end,
         display_name = coalesce(p_business_name, display_name)
   where id = auth.uid();
  insert into employer_profiles (profile_id, business_name, default_geog, default_address)
  values (auth.uid(), p_business_name, v_geog, p_address)
  on conflict (profile_id) do update
     set business_name = excluded.business_name,
         default_geog = excluded.default_geog,
         default_address = excluded.default_address;
  -- 매장이 아직 없으면 기본 매장 생성.
  if not exists (select 1 from stores where employer_id = auth.uid()) then
    insert into stores (employer_id, name, address, geog, is_default)
    values (auth.uid(), coalesce(p_business_name, '기본 매장'), p_address, v_geog, true);
  end if;
end; $$;

grant select on stores to authenticated;  -- 쓰기는 SECURITY DEFINER RPC로만(관례)
grant execute on function public.my_stores() to authenticated;
grant execute on function public.add_store(text,double precision,double precision,text,boolean) to authenticated;
grant execute on function public.update_store(uuid,text,double precision,double precision,text) to authenticated;
grant execute on function public.set_default_store(uuid) to authenticated;
grant execute on function public.delete_store(uuid) to authenticated;
grant execute on function public.create_job_request(text,timestamptz,timestamptz,int,int,uuid,double precision,double precision,text,text,boolean,uuid) to authenticated;
