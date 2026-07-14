-- =====================================================================
-- 0016 분쟁(dispute) 플로우 — 배정 당사자가 문제를 신고하고 증거를 남긴다.
--  · 로드맵 Should("시간박스 분쟁 플로우 — 48~72h 증거 SLA + 무응답 자동규칙").
--  · 신고/증거 제출은 당사자(authenticated RPC). 해소(status/resolution 결정)는 운영자
--    (service_role) — disputes 는 RLS-only(0001·§7)라 앱 직접 접근 불가, RPC로만.
--  · is_contract_party(0003) 재사용(근로자·업주 양측). SLA 기본 72h.
-- =====================================================================
set search_path = public, extensions;

-- 배정당 '열린' 분쟁은 1건만(동시/중복 신고 방지). 해소 후 재신고는 허용(partial).
create unique index if not exists disputes_one_open_per_assignment
  on disputes (assignment_id) where status = 'open';

-- 조회: 당사자의 해당 배정 분쟁(가장 최근 1건, 없으면 null).
create or replace function public.dispute_for_assignment(p_assignment_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v disputes;
begin
  if not public.is_contract_party(p_assignment_id) then
    raise exception 'not_a_party';
  end if;
  select * into v from disputes
   where assignment_id = p_assignment_id
   order by created_at desc limit 1;
  if not found then return null; end if;
  return jsonb_build_object(
    'id',           v.id,
    'assignment_id',v.assignment_id,
    'opened_by',    v.opened_by,
    'status',       v.status,
    'evidence',     coalesce(v.evidence, '[]'::jsonb),
    'resolution',   v.resolution,
    'sla_deadline', v.sla_deadline,
    'created_at',   v.created_at,
    'i_opened',     v.opened_by = auth.uid()
  );
end; $$;

-- 분쟁 열기: 당사자만. 카테고리+사유를 첫 증거로 기록. SLA now()+72h.
create or replace function public.open_dispute(
  p_assignment_id uuid, p_category text, p_reason text
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_contract_party(p_assignment_id) then
    raise exception 'not_a_party';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'empty_reason';
  end if;

  insert into disputes (assignment_id, opened_by, status, evidence, sla_deadline)
    values (
      p_assignment_id, auth.uid(), 'open',
      jsonb_build_array(jsonb_build_object(
        'by',       auth.uid(),
        'category', coalesce(nullif(trim(p_category), ''), 'other'),
        'text',     left(trim(p_reason), 1000),
        'at',       now())),
      now() + interval '72 hours');

  return public.dispute_for_assignment(p_assignment_id);
exception when unique_violation then
  raise exception 'already_open';   -- 이미 열린 분쟁 존재(partial unique)
end; $$;

-- 증거 추가: 당사자만, 열린 분쟁에만. evidence 배열에 append.
create or replace function public.add_dispute_evidence(p_dispute_id uuid, p_text text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v disputes;
begin
  if coalesce(trim(p_text), '') = '' then
    raise exception 'empty_text';
  end if;
  select * into v from disputes where id = p_dispute_id;
  if not found or not public.is_contract_party(v.assignment_id) then
    raise exception 'not_a_party';   -- 존재여부 유출 방지(동일 에러)
  end if;
  if v.status <> 'open' then
    raise exception 'not_open';
  end if;

  -- WHERE 에 status='open' 을 둬 검사~UPDATE 사이 동시 종결(TOCTOU)을 원자적으로 방어.
  update disputes
     set evidence = coalesce(evidence, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
           'by',   auth.uid(),
           'text', left(trim(p_text), 1000),
           'at',   now()))
   where id = p_dispute_id and status = 'open';
  if not found then
    raise exception 'not_open';   -- 읽은 뒤 다른 트랜잭션이 종결시킨 경우
  end if;

  return public.dispute_for_assignment(v.assignment_id);
end; $$;

grant execute on function public.dispute_for_assignment(uuid) to authenticated;
grant execute on function public.open_dispute(uuid, text, text) to authenticated;
grant execute on function public.add_dispute_evidence(uuid, text) to authenticated;

-- 새 RPC를 REST(PostgREST)에 노출.
notify pgrst, 'reload schema';
