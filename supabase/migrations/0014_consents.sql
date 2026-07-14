-- =====================================================================
-- 0014 법적 동의(약관/개인정보/위치) — 버전관리 + 원자적 기록 + 필수충족 확인
-- consents 테이블(0001)은 append-only 감사로그. 약관 개정 시 재동의(버전).
-- 필수: tos, privacy, privacy_3rd, location, age14 (위치정보법/개인정보법/전상법 근거).
-- =====================================================================
set search_path = public;

alter table consents add column if not exists version text not null default 'v1';
create index if not exists consents_profile_type_ix on consents (profile_id, type, granted_at desc);

-- 여러 동의를 원자적으로 기록. p_items = [{"type":"tos","granted":true,"version":"v1"}, ...]
create or replace function public.record_consents(p_items jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare it jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    insert into consents (profile_id, type, granted, version)
    values (auth.uid(), it->>'type', coalesce((it->>'granted')::boolean, false),
            coalesce(it->>'version', 'v1'));
  end loop;
end; $$;

-- 최신 동의 상태(타입별 최신 1건) + 필수 동의 충족 여부.
create or replace function public.my_consent_status()
returns jsonb
language sql stable security definer set search_path = public as $$
  with latest as (
    select distinct on (type) type, granted, version
    from consents where profile_id = auth.uid()
    order by type, granted_at desc
  )
  select jsonb_build_object(
    'consents', coalesce(
      (select jsonb_object_agg(type, jsonb_build_object('granted', granted, 'version', version))
       from latest), '{}'::jsonb),
    'required_met', (
      select bool_and(coalesce((select l.granted from latest l where l.type = req), false))
      from unnest(array['tos','privacy','privacy_3rd','location','age14']) req
    )
  );
$$;

grant execute on function public.record_consents(jsonb) to authenticated;
grant execute on function public.my_consent_status() to authenticated;
