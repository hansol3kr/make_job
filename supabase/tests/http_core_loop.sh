#!/usr/bin/env bash
# HTTP 레벨 코어 루프 E2E — 앱이 실제 사용할 경로(Auth → PostgREST RPC → RLS)를 실토큰으로 검증.
# 로컬 Supabase가 떠 있어야 함. 사용: bash supabase/tests/http_core_loop.sh
set -euo pipefail
BASE=http://127.0.0.1:54321
ANON='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0'
SERVICE='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU'
DB=$(docker ps --format '{{.Names}}' | grep supabase_db | head -1)
py(){ python3 -c "import sys,json;print(json.load(sys.stdin)$1)"; }

echo "== 0) 이전 테스트 데이터 정리 =="
docker exec -i "$DB" psql -U postgres -d postgres -q <<'SQL' >/dev/null 2>&1 || true
delete from assignments  where request_id='99999999-9999-9999-9999-999999999999';
delete from match_offers where request_id='99999999-9999-9999-9999-999999999999';
delete from job_requests where id='99999999-9999-9999-9999-999999999999';
delete from auth.users where email in ('emp_e2e@test.dev','wrk_e2e@test.dev');
SQL

echo "== 1) 사용자 생성(admin) =="
EMP=$(curl -s -X POST "$BASE/auth/v1/admin/users" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" \
  -d '{"email":"emp_e2e@test.dev","password":"pw123456","email_confirm":true}')
WRK=$(curl -s -X POST "$BASE/auth/v1/admin/users" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" \
  -d '{"email":"wrk_e2e@test.dev","password":"pw123456","email_confirm":true}')
EMPID=$(echo "$EMP" | py '["id"]'); WRKID=$(echo "$WRK" | py '["id"]')
echo "  employer=$EMPID worker=$WRKID"

echo "== 2) 로그인 → 토큰 =="
ETOK=$(curl -s -X POST "$BASE/auth/v1/token?grant_type=password" -H "apikey: $ANON" -H "Content-Type: application/json" -d '{"email":"emp_e2e@test.dev","password":"pw123456"}' | py '["access_token"]')
WTOK=$(curl -s -X POST "$BASE/auth/v1/token?grant_type=password" -H "apikey: $ANON" -H "Content-Type: application/json" -d '{"email":"wrk_e2e@test.dev","password":"pw123456"}' | py '["access_token"]')
echo "  tokens acquired"

echo "== 3) 프로필/요청 부트스트랩(SQL) =="
docker exec -i "$DB" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q <<SQL
update profiles set role='employer', display_name='E2E카페' where id='$EMPID';
update profiles set role='worker',   display_name='E2E근로자' where id='$WRKID';
insert into employer_profiles(profile_id,business_name,default_geog)
  values ('$EMPID','E2E카페', st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography)
  on conflict (profile_id) do nothing;
insert into worker_profiles(profile_id,is_available,identity_verified_at,current_geog,reliability_score)
  values ('$WRKID',true,now(), st_setsrid(st_makepoint(127.0290,37.4990),4326)::geography,80)
  on conflict (profile_id) do nothing;
insert into job_requests(id,employer_id,title,geog,start_at,end_at,pay_amount,headcount,status)
  values ('99999999-9999-9999-9999-999999999999','$EMPID','E2E 홀 대타',
          st_setsrid(st_makepoint(127.0276,37.4979),4326)::geography,
          now()+interval '2 hours', now()+interval '8 hours', 95000, 1, 'open');
SQL
echo "  ok"

echo "== 4) [worker token] set_availability RPC =="
curl -s -X POST "$BASE/rest/v1/rpc/set_availability" -H "apikey: $ANON" -H "Authorization: Bearer $WTOK" -H "Content-Type: application/json" \
  -d '{"p_available":true,"p_lng":127.0290,"p_lat":37.4990}' -w "  http=%{http_code}\n"

echo "== 5) [service] run_match RPC =="
curl -s -X POST "$BASE/rest/v1/rpc/run_match" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" \
  -d '{"p_request_id":"99999999-9999-9999-9999-999999999999","p_radius_m":3000,"p_wave":3,"p_ttl_seconds":60}' -w "  offers_created=%{stdout} http=%{http_code}\n" -o /tmp/rm.out; echo "  -> $(cat /tmp/rm.out)"

echo "== 6) [worker token] 내 오퍼 조회 (RLS) =="
OFFERS=$(curl -s "$BASE/rest/v1/match_offers?select=id,status,rank&order=rank" -H "apikey: $ANON" -H "Authorization: Bearer $WTOK")
echo "  $OFFERS"
OFFERID=$(echo "$OFFERS" | py '[0]["id"]')

echo "== 7) [worker token] accept_offer RPC =="
ASG=$(curl -s -X POST "$BASE/rest/v1/rpc/accept_offer" -H "apikey: $ANON" -H "Authorization: Bearer $WTOK" -H "Content-Type: application/json" -d "{\"p_offer_id\":\"$OFFERID\"}")
echo "  assignment_id=$ASG"

echo "== 8) 최종 상태 검증 =="
docker exec -i "$DB" psql -U postgres -d postgres -q <<SQL
select 'request' k, status::text v from job_requests where id='99999999-9999-9999-9999-999999999999'
union all select 'offer', status::text from match_offers where request_id='99999999-9999-9999-9999-999999999999'
union all select 'assignment', status::text from assignments where request_id='99999999-9999-9999-9999-999999999999';
SQL

echo "== 9) 정리 =="
docker exec -i "$DB" psql -U postgres -d postgres -q >/dev/null 2>&1 <<SQL || true
delete from job_requests where id='99999999-9999-9999-9999-999999999999';
delete from auth.users where email in ('emp_e2e@test.dev','wrk_e2e@test.dev');
SQL
echo "  done"
