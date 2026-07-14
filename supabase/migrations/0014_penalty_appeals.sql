-- =====================================================================
-- 0013 페널티 이의신청(appeal) — 근로자가 부당한 페널티에 이의를 제기.
--  · 로드맵 Must("대칭 노쇼/취소 페널티 … 자동 면제 + 이의신청")의 이의신청 절반.
--  · 제출은 본인 페널티만(authenticated RPC). 승인/기각(waived 결정)은 운영자
--    (service_role)가 별도로 처리 — penalties는 RLS-only(0007절 정책)라 앱 직접 접근 불가.
--  · penalties.appeal_status(0001, default 'none')를 실제로 사용하기 시작.
-- =====================================================================
set search_path = public, extensions;

-- 이의 사유·시각 보관 컬럼(기존 reason은 시스템 사유이므로 덮어쓰지 않는다).
alter table penalties add column if not exists appeal_reason text;
alter table penalties add column if not exists appealed_at   timestamptz;

-- 이의신청: 본인 · 미면제 · 미신청 · 비공백 사유만. 동시 중복신청은 조건부 UPDATE로 방어.
create or replace function public.appeal_penalty(p_penalty_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v penalties; n int;
begin
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'empty_reason';
  end if;

  select * into v from penalties where id = p_penalty_id;
  -- 존재하지 않거나 남의 페널티 → 존재 여부를 흘리지 않도록 동일 에러.
  if not found or v.profile_id <> auth.uid() then
    raise exception 'not_your_penalty';
  end if;
  if v.waived then
    raise exception 'already_waived';        -- 이미 면제된 건 이의 불필요
  end if;
  if v.appeal_status <> 'none' then
    raise exception 'already_appealed';
  end if;

  update penalties
     set appeal_status = 'requested',
         appeal_reason = left(trim(p_reason), 500),
         appealed_at   = now()
   where id = p_penalty_id
     and profile_id = auth.uid()
     and appeal_status = 'none';             -- 동시 신청 race: 둘 중 하나만 성공
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'already_appealed';       -- race에서 진 쪽
  end if;

  return jsonb_build_object('id', p_penalty_id, 'appeal_status', 'requested');
end; $$;

-- 신뢰 요약에 페널티 id·이의상태 노출(앱이 이의신청 대상을 식별·상태표시 하도록).
-- 기존 필드는 그대로 유지(하위호환) — id·appeal_status·appeal_reason만 추가.
create or replace function public.my_reliability_summary()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'reliability', w.reliability_score, 'tier', w.tier,
    'identity_verified', w.identity_verified_at is not null,
    'bank_verified', w.bank_verified_at is not null,
    'professional', w.professional_verified_at is not null,
    'is_available', w.is_available,
    'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.occurred_at) order by e.occurred_at desc)
                        from reliability_events e where e.profile_id = auth.uid()
                          and e.occurred_at > now() - interval '180 days'), '[]'::jsonb),
    'penalties', coalesce((select jsonb_agg(jsonb_build_object(
                             'id', p.id, 'kind', p.kind, 'reason', p.reason,
                             'waived', p.waived, 'appeal_status', p.appeal_status,
                             'appeal_reason', p.appeal_reason, 'at', p.created_at)
                           order by p.created_at desc)
                           from penalties p where p.profile_id = auth.uid()), '[]'::jsonb)
  ) from worker_profiles w where w.profile_id = auth.uid();
$$;

grant execute on function public.appeal_penalty(uuid, text) to authenticated;

-- 새 RPC/시그니처를 REST(PostgREST)에 노출.
notify pgrst, 'reload schema';
