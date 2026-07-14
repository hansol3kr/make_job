-- =====================================================================
-- 0011 안전/신뢰 번들 (1차) — 인앱 채팅 + 원터치 SOS
--  · 인앱 채팅: 확정 배정 당사자(근로자↔업주) 간 소통 + 분쟁 증거 보존.
--    번호 노출 없이 소통(안심번호의 1차 대체). 쓰기는 RPC(SECURITY DEFINER)로만.
--  · 원터치 SOS: 근무 중 긴급 상황을 GPS와 함께 기록, 상대 당사자에 실시간 노출.
-- RLS 교차검사는 기존 헬퍼 is_contract_party(0003) 재사용(재귀 회피).
-- =====================================================================
set search_path = public, extensions;

-- ============ 인앱 채팅 (messages) ============
create table if not exists messages (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references assignments(id) on delete cascade,
  sender_id     uuid not null references profiles(id),
  body          text not null,
  created_at    timestamptz not null default now()
);
create index if not exists messages_assignment_ix on messages (assignment_id, created_at);
alter table messages enable row level security;

-- 읽기: 배정 당사자만. 쓰기 정책은 없음 → 직접 insert 차단, send_message RPC로만.
drop policy if exists messages_party_read on messages;
create policy messages_party_read on messages for select
  using (public.is_contract_party(assignment_id));

-- 메시지 전송: 본인 sender 강제 + 당사자 검증 + 길이 제한.
create or replace function public.send_message(p_assignment uuid, p_body text)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid;
begin
  if coalesce(trim(p_body), '') = '' then
    raise exception 'empty message';
  end if;
  if not public.is_contract_party(p_assignment) then
    raise exception 'not a party to this assignment';
  end if;
  insert into messages (assignment_id, sender_id, body)
    values (p_assignment, auth.uid(), left(p_body, 1000))
    returning id into v_id;
  return v_id;
end; $$;

-- ============ 원터치 SOS (sos_alerts) ============
create table if not exists sos_alerts (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid references assignments(id) on delete set null,
  reporter_id   uuid not null references profiles(id),
  geog          extensions.geography(Point, 4326),
  note          text,
  status        text not null default 'open',   -- open | resolved
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz
);
create index if not exists sos_reporter_ix on sos_alerts (reporter_id, created_at);
create index if not exists sos_assignment_ix on sos_alerts (assignment_id, status);
alter table sos_alerts enable row level security;

-- 읽기: 신고자 본인 + 같은 배정 상대 당사자(대응 위해). 쓰기는 trigger_sos RPC로만.
drop policy if exists sos_party_read on sos_alerts;
create policy sos_party_read on sos_alerts for select
  using (
    reporter_id = auth.uid()
    or (assignment_id is not null and public.is_contract_party(assignment_id))
  );

-- SOS 발동: 배정이 있으면 당사자 검증, GPS는 있으면 좌표 기록.
create or replace function public.trigger_sos(
  p_assignment uuid default null,
  p_lat double precision default null,
  p_lng double precision default null,
  p_note text default null
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id uuid;
  v_geog geography;
begin
  if p_assignment is not null and not public.is_contract_party(p_assignment) then
    raise exception 'not a party to this assignment';
  end if;
  if p_lat is not null and p_lng is not null then
    v_geog := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  end if;
  insert into sos_alerts (assignment_id, reporter_id, geog, note)
    values (p_assignment, auth.uid(), v_geog, nullif(trim(coalesce(p_note, '')), ''))
    returning id into v_id;
  return v_id;
end; $$;

-- SOS 해제(신고자 또는 상대 당사자).
create or replace function public.resolve_sos(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  update sos_alerts
     set status = 'resolved', resolved_at = now()
   where id = p_id
     and (reporter_id = auth.uid()
          or (assignment_id is not null and public.is_contract_party(assignment_id)));
end; $$;

-- ============ 권한 + 실시간 ============
grant select, insert on messages   to authenticated;
grant select, insert, update on sos_alerts to authenticated;
grant execute on function public.send_message(uuid, text) to authenticated;
grant execute on function public.trigger_sos(uuid, double precision, double precision, text) to authenticated;
grant execute on function public.resolve_sos(uuid) to authenticated;

alter publication supabase_realtime add table messages;
alter publication supabase_realtime add table sos_alerts;
