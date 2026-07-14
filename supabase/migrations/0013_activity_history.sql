-- =====================================================================
-- 0013 근로자 활동/수익 내역
-- 근로자가 자신의 지난 근무·수익·평점을 한 화면에서 본다.
-- profiles/employer는 본인전용 RLS → 업주명은 SECURITY DEFINER로 제한 노출.
-- =====================================================================
set search_path = public, extensions;

create or replace function public.my_activity_history()
returns jsonb
language sql stable security definer set search_path = public as $$
  with mine as (
    select a.id, a.status, a.check_in_at, a.check_out_at, a.confirmed_at,
           r.title, r.pay_amount, r.pay_type, r.start_at, r.end_at, r.employer_id
    from assignments a
    join job_requests r on r.id = a.request_id
    where a.worker_id = auth.uid()
  )
  select jsonb_build_object(
    'summary', jsonb_build_object(
      'completed_count', (select count(*) from mine where status = 'completed'),
      'total_earned',    (select coalesce(sum(pay_amount), 0) from mine where status = 'completed'),
      'no_show_count',   (select count(*) from mine where status = 'no_show'),
      'cancelled_count', (select count(*) from mine where status in ('cancelled_worker', 'cancelled_employer')),
      'upcoming_count',  (select count(*) from mine where status in ('confirmed', 'checked_in'))
    ),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'assignment_id', m.id,
        'title',         m.title,
        'pay_amount',    m.pay_amount,
        'pay_type',      m.pay_type,
        'status',        m.status,
        'start_at',      m.start_at,
        'end_at',        m.end_at,
        'worked_at',     coalesce(m.check_out_at, m.start_at),
        'employer_name', (select p.display_name from profiles p where p.id = m.employer_id),
        'my_rating',     (select rt.stars from ratings rt
                           where rt.assignment_id = m.id and rt.rater_id = auth.uid()),
        'received_rating', (select rt.stars from ratings rt
                             where rt.assignment_id = m.id and rt.rater_id <> auth.uid()
                               and rt.revealed_at is not null)
      ) order by coalesce(m.check_out_at, m.start_at) desc)
      from mine m
    ), '[]'::jsonb)
  );
$$;

grant execute on function public.my_activity_history() to authenticated;
