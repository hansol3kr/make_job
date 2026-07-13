-- =====================================================================
-- 지금인력 (Jigeum) — core schema  [M0]
-- 실시간 인력 아웃소싱 플랫폼: 요청 → 매칭 → 확정 → 근무 → 정산 → 평점
-- Postgres + PostGIS (Supabase). 자세한 설계: /docs/data-model.md
-- =====================================================================
set search_path = public, extensions;

create extension if not exists postgis with schema extensions;

-- ===================== ENUMS =====================
create type user_role        as enum ('worker','employer','both','admin');
create type verify_type      as enum ('phone','identity','bank','business','background');
create type verify_status    as enum ('pending','verified','failed','expired');
create type request_status   as enum ('draft','open','matching','confirmed','in_progress','completed','cancelled','expired');
create type offer_status     as enum ('offered','accepted','declined','expired','cancelled');
create type assign_status    as enum ('confirmed','checked_in','completed','no_show','cancelled_worker','cancelled_employer');
create type pay_status       as enum ('authorized','escrowed','released','refunded','partial_refund','failed');
create type rating_dir       as enum ('worker_to_employer','employer_to_worker');
create type reliability_kind as enum ('completed','on_time','late','late_cancel','no_show','declined');

-- ===================== CORE =====================
create table profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  role           user_role not null default 'worker',
  display_name   text,
  phone          text,
  phone_verified boolean not null default false,
  status         text not null default 'active',   -- active/suspended/banned
  created_at     timestamptz not null default now()
);

create table worker_profiles (
  profile_id           uuid primary key references profiles(id) on delete cascade,
  bio                  text,
  skills               text[] not null default '{}',
  home_geog            extensions.geography(Point,4326),
  current_geog         extensions.geography(Point,4326),
  is_available         boolean not null default false,
  last_seen_at         timestamptz,
  reliability_score    numeric(4,1) not null default 50.0,   -- 0~100
  tier                 text not null default 'standard',     -- standard/verified/top_pro
  identity_verified_at timestamptz,
  bank_verified_at     timestamptz
);
create index worker_current_geog_gix on worker_profiles using gist (current_geog);
create index worker_avail_rel_ix     on worker_profiles (is_available, reliability_score);

create table employer_profiles (
  profile_id      uuid primary key references profiles(id) on delete cascade,
  business_name   text,
  biz_reg_no      text,
  biz_verified    boolean not null default false,
  default_geog    extensions.geography(Point,4326),
  default_address text
);

create table verifications (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references profiles(id) on delete cascade,
  type        verify_type not null,
  status      verify_status not null default 'pending',
  provider    text,
  ref         text,                       -- 외부 참조 토큰(원문 식별정보 미보관)
  verified_at timestamptz,
  created_at  timestamptz not null default now()
);
create index verifications_profile_ix on verifications (profile_id, type);

create table categories (
  id        uuid primary key default gen_random_uuid(),
  parent_id uuid references categories(id),
  slug      text unique not null,
  name      text not null,
  is_active boolean not null default true,
  sort      int not null default 0
);

create table job_requests (
  id            uuid primary key default gen_random_uuid(),
  employer_id   uuid not null references employer_profiles(profile_id),
  category_id   uuid references categories(id),
  title         text not null,
  description   text,
  geog          extensions.geography(Point,4326) not null,
  address       text,
  start_at      timestamptz not null,
  end_at        timestamptz not null,
  headcount     int not null default 1 check (headcount > 0),
  filled_count  int not null default 0,
  pay_type      text not null default 'daily',      -- daily(일급)/hourly(시급)
  pay_amount    int  not null check (pay_amount >= 0),
  status        request_status not null default 'open',
  auto_backfill boolean not null default true,
  created_at    timestamptz not null default now()
);
create index job_requests_geog_gix on job_requests using gist (geog);
create index job_requests_status_ix on job_requests (status, start_at);
create index job_requests_employer_ix on job_requests (employer_id);

create table match_offers (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references job_requests(id) on delete cascade,
  worker_id    uuid not null references worker_profiles(profile_id),
  rank         int,
  score        numeric,
  status       offer_status not null default 'offered',
  reason       jsonb,                     -- 설명가능 랭킹 {distance, eta, reliability, ...}
  offered_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  responded_at timestamptz,
  unique (request_id, worker_id)
);
create index match_offers_worker_ix on match_offers (worker_id, status);
create index match_offers_request_ix on match_offers (request_id, status);

create table assignments (
  id            uuid primary key default gen_random_uuid(),
  request_id    uuid not null references job_requests(id),
  worker_id     uuid not null references worker_profiles(profile_id),
  status        assign_status not null default 'confirmed',
  check_in_at   timestamptz,
  check_in_geog extensions.geography(Point,4326),
  check_out_at  timestamptz,
  confirmed_at  timestamptz not null default now(),
  unique (request_id, worker_id)
);
create index assignments_worker_ix on assignments (worker_id, status);
create index assignments_request_ix on assignments (request_id);

create table contracts (
  id                 uuid primary key default gen_random_uuid(),
  assignment_id      uuid not null references assignments(id) on delete cascade,
  pdf_url            text,
  terms              jsonb,
  income_type        text not null default 'daily_wage',   -- 일용근로소득 기본
  signed_worker_at   timestamptz,
  signed_employer_at timestamptz,
  created_at         timestamptz not null default now()
);

create table payments (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references assignments(id),
  pg_provider   text,                      -- portone/toss
  pg_tx_id      text,
  amount        int not null,
  commission    int not null default 0,    -- 유료직업소개 요율 상한 준수
  status        pay_status not null default 'authorized',
  authorized_at timestamptz,
  escrowed_at   timestamptz,
  released_at   timestamptz
);
create index payments_assignment_ix on payments (assignment_id);

create table ratings (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references assignments(id) on delete cascade,
  rater_id      uuid not null references profiles(id),
  ratee_id      uuid not null references profiles(id),
  direction     rating_dir not null,
  stars         int not null check (stars between 1 and 5),
  sub_scores    jsonb,                     -- {punctuality, quality, communication}
  comment       text,
  submitted_at  timestamptz not null default now(),
  revealed_at   timestamptz,               -- 양측 제출 or 14일 후 (더블블라인드)
  locked        boolean not null default false,
  unique (assignment_id, direction)
);
create index ratings_ratee_ix on ratings (ratee_id);

create table reliability_events (
  id            uuid primary key default gen_random_uuid(),
  profile_id    uuid not null references profiles(id),
  assignment_id uuid references assignments(id),
  kind          reliability_kind not null,
  weight        numeric not null default 1.0,
  occurred_at   timestamptz not null default now()
);
create index reliability_events_profile_ix on reliability_events (profile_id, occurred_at);

create table penalties (
  id            uuid primary key default gen_random_uuid(),
  profile_id    uuid not null references profiles(id),
  assignment_id uuid references assignments(id),
  kind          text,                      -- late_cancel/no_show ...
  amount        int not null default 0,
  reason        text,
  waived        boolean not null default false,
  appeal_status text not null default 'none',
  created_at    timestamptz not null default now()
);

create table disputes (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references assignments(id),
  opened_by     uuid not null references profiles(id),
  status        text not null default 'open',
  evidence      jsonb,
  resolution    text,
  sla_deadline  timestamptz,
  created_at    timestamptz not null default now()
);

create table consents (
  id         uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  type       text not null,                -- location/privacy/marketing
  granted    boolean not null,
  granted_at timestamptz not null default now()
);

create table push_tokens (
  id         uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  platform   text,                          -- android/ios
  token      text not null,
  updated_at timestamptz not null default now(),
  unique (token)
);

-- ===================== FUNCTIONS =====================
-- auth.users 생성 시 profiles 자동 생성
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, phone, phone_verified)
  values (new.id, new.phone, new.phone_confirmed_at is not null)
  on conflict (id) do nothing;
  return new;
end; $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 반경 내 가용·인증·신뢰도 만족 근로자 상위 N (매칭 핵심)
create or replace function public.nearby_candidates(
  p_request_id      uuid,
  p_radius_m        integer default 5000,
  p_min_reliability numeric default 0,
  p_limit           integer default 10
) returns table (worker_id uuid, dist_m double precision, reliability_score numeric, tier text)
language sql stable security definer set search_path = public, extensions as $$
  select w.profile_id,
         st_distance(w.current_geog, r.geog) as dist_m,
         w.reliability_score,
         w.tier
  from worker_profiles w
  cross join lateral (
    select geog, start_at, end_at from job_requests where id = p_request_id
  ) r
  where w.is_available
    and w.identity_verified_at is not null
    and w.reliability_score >= p_min_reliability
    and w.current_geog is not null
    and st_dwithin(w.current_geog, r.geog, p_radius_m)
    and not exists (
      select 1 from assignments a
      join job_requests jr on jr.id = a.request_id
      where a.worker_id = w.profile_id
        and a.status in ('confirmed','checked_in')
        and tstzrange(jr.start_at, jr.end_at) && tstzrange(r.start_at, r.end_at)
    )
  order by w.current_geog <-> r.geog
  limit p_limit;
$$;

-- 최근 180일 이벤트로 신뢰도 재계산
create or replace function public.recompute_reliability(p_profile uuid)
returns numeric language sql security definer set search_path = public as $$
  update worker_profiles w
     set reliability_score = greatest(0, least(100, 50 + coalesce((
        select sum(case e.kind
                     when 'completed'   then  3 * e.weight
                     when 'on_time'     then  2 * e.weight
                     when 'late'        then -2 * e.weight
                     when 'late_cancel' then -8 * e.weight
                     when 'no_show'     then -20 * e.weight
                     else 0 end)
        from reliability_events e
        where e.profile_id = p_profile
          and e.occurred_at > now() - interval '180 days'), 0)))
   where w.profile_id = p_profile
  returning w.reliability_score;
$$;

-- ===================== RLS =====================
alter table profiles           enable row level security;
alter table worker_profiles    enable row level security;
alter table employer_profiles  enable row level security;
alter table verifications      enable row level security;
alter table categories         enable row level security;
alter table job_requests       enable row level security;
alter table match_offers       enable row level security;
alter table assignments        enable row level security;
alter table contracts          enable row level security;
alter table payments           enable row level security;
alter table ratings            enable row level security;
alter table reliability_events enable row level security;
alter table penalties          enable row level security;
alter table disputes           enable row level security;
alter table consents           enable row level security;
alter table push_tokens        enable row level security;

-- categories: 모두 읽기 가능
create policy categories_read on categories for select using (is_active);

-- profiles: 본인만
create policy profiles_self_sel on profiles for select using (id = auth.uid());
create policy profiles_self_upd on profiles for update using (id = auth.uid());

-- worker/employer profiles: 본인 CRUD
create policy worker_self_all on worker_profiles for all
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy employer_self_all on employer_profiles for all
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

-- verifications / consents / push_tokens: 본인
create policy verif_self_all on verifications for all
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy consents_self_all on consents for all
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy push_self_all on push_tokens for all
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

-- job_requests: 업주 소유 CRUD + 오퍼/배정 당사자 근로자 읽기
create policy jr_employer_all on job_requests for all
  using (employer_id = auth.uid()) with check (employer_id = auth.uid());
create policy jr_worker_read on job_requests for select using (
  exists (select 1 from match_offers o where o.request_id = job_requests.id and o.worker_id = auth.uid())
  or exists (select 1 from assignments a where a.request_id = job_requests.id and a.worker_id = auth.uid())
);

-- match_offers: 대상 근로자 읽기+상태변경, 업주 읽기
create policy mo_worker_read on match_offers for select using (worker_id = auth.uid());
create policy mo_worker_upd  on match_offers for update using (worker_id = auth.uid());
create policy mo_employer_read on match_offers for select using (
  exists (select 1 from job_requests r where r.id = match_offers.request_id and r.employer_id = auth.uid())
);

-- assignments: 당사자(근로자/업주) 읽기, 근로자 체크인/아웃 업데이트
create policy assign_party_read on assignments for select using (
  worker_id = auth.uid()
  or exists (select 1 from job_requests r where r.id = assignments.request_id and r.employer_id = auth.uid())
);
create policy assign_worker_upd on assignments for update using (worker_id = auth.uid());

-- ratings: 본인 작성, 공개된 것 또는 본인 것 읽기 (더블블라인드)
create policy ratings_insert on ratings for insert with check (rater_id = auth.uid());
create policy ratings_read on ratings for select using (revealed_at is not null or rater_id = auth.uid());

-- contracts: 배정 당사자 읽기
create policy contracts_party_read on contracts for select using (
  exists (select 1 from assignments a
          join job_requests r on r.id = a.request_id
          where a.id = contracts.assignment_id
            and (a.worker_id = auth.uid() or r.employer_id = auth.uid()))
);

-- payments / reliability_events / penalties / disputes:
--   민감·정산 데이터는 기본적으로 service_role(Edge Functions)만 접근 (정책 없음 = 일반 사용자 차단)
--   당사자 노출은 후속 단계에서 전용 뷰/함수로 제한 공개.
