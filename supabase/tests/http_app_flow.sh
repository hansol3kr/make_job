#!/usr/bin/env bash
# 앱 와이어링 E2E — 앱이 실제 호출하는 경로를 실토큰으로 검증.
# 폰 OTP 인증 → 온보딩 RPC → 요청생성/매칭 RPC → RLS 오퍼조회 → 수락 → 스냅샷 → 체크인/아웃.
# 사용: bash supabase/tests/http_app_flow.sh   (로컬 Supabase 실행 중이어야 함)
set -euo pipefail
BASE=http://127.0.0.1:54321
ANON='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0'
WPHONE='+821012341111'   # 데모 근로자 (test_otp 123456)
EPHONE='+821012342222'   # 데모 사장님 (test_otp 123456)
OTP=123456
DB=$(docker ps --format '{{.Names}}' | grep supabase_db | head -1)
py(){ python3 -c "import sys,json;print(json.load(sys.stdin)$1)"; }

otp_login(){ # $1=phone → access_token
  curl -s -X POST "$BASE/auth/v1/otp" -H "apikey: $ANON" -H "Content-Type: application/json" \
    -d "{\"phone\":\"$1\",\"create_user\":true}" >/dev/null
  curl -s -X POST "$BASE/auth/v1/verify" -H "apikey: $ANON" -H "Content-Type: application/json" \
    -d "{\"phone\":\"$1\",\"token\":\"$OTP\",\"type\":\"sms\"}" | py '["access_token"]'
}
rpc(){ # $1=token $2=fn $3=json
  curl -s -X POST "$BASE/rest/v1/rpc/$2" -H "apikey: $ANON" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -d "$3"
}

echo "== 0) 이전 데모 데이터 정리 =="
docker exec -i "$DB" psql -U postgres -d postgres -q >/dev/null 2>&1 <<'SQL' || true
do $$
declare wid uuid; eid uuid;
begin
  select id into wid from auth.users where phone='821012341111';
  select id into eid from auth.users where phone='821012342222';
  if wid is not null then delete from reliability_events where profile_id=wid; delete from assignments where worker_id=wid; end if;
  if eid is not null then delete from job_requests where employer_id=eid; end if;
  delete from auth.users where phone in ('821012341111','821012342222');
end $$;
SQL
echo "  ok"

echo "== 1) 폰 OTP 로그인 (근로자/사장님) =="
WTOK=$(otp_login "$WPHONE"); ETOK=$(otp_login "$EPHONE")
echo "  worker/employer 토큰 획득: ${WTOK:0:12}… / ${ETOK:0:12}…"

echo "== 2) 온보딩 RPC (강남역 좌표) =="
rpc "$WTOK" complete_worker_onboarding '{"p_display_name":"데모근로자","p_lng":127.0276,"p_lat":37.4979}' >/dev/null
echo "  worker onboarding done"
rpc "$ETOK" complete_employer_onboarding '{"p_business_name":"데모카페","p_lng":127.0276,"p_lat":37.4979,"p_address":"서울 강남구 강남역"}' >/dev/null
echo "  employer onboarding done"

echo "== 3) [worker] 가용 ON =="
rpc "$WTOK" set_availability '{"p_available":true,"p_lng":127.0276,"p_lat":37.4979}' >/dev/null; echo "  available"

echo "== 4) [employer] 요청 생성 (위치=매장 기본) =="
START=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u -d '+8 hours' +%Y-%m-%dT%H:%M:%SZ)
RID=$(rpc "$ETOK" create_job_request "{\"p_title\":\"카페 홀 대타\",\"p_start_at\":\"$START\",\"p_end_at\":\"$END\",\"p_pay_amount\":95000,\"p_headcount\":1}" | tr -d '"')
echo "  request_id=$RID"

echo "== 5) [employer] 매칭 시작 =="
N=$(rpc "$ETOK" request_matching "{\"p_request_id\":\"$RID\"}")
echo "  offers_created=$N"

echo "== 6) [worker] 내 오퍼 조회(RLS) =="
OFFERS=$(curl -s "$BASE/rest/v1/match_offers?select=id,status,rank&order=rank" -H "apikey: $ANON" -H "Authorization: Bearer $WTOK")
echo "  $OFFERS"
OFFERID=$(echo "$OFFERS" | py '[0]["id"]')

echo "== 7) [worker] 오퍼 수락 =="
ASG=$(rpc "$WTOK" accept_offer "{\"p_offer_id\":\"$OFFERID\"}" | tr -d '"')
echo "  assignment_id=$ASG"

echo "== 8) [employer] 매칭 스냅샷 (확정 근로자 노출) =="
rpc "$ETOK" matching_snapshot "{\"p_request_id\":\"$RID\"}" | py ''

echo "== 9) [worker] 체크인 → 체크아웃 =="
rpc "$WTOK" check_in "{\"p_assignment_id\":\"$ASG\",\"p_lng\":127.0276,\"p_lat\":37.4979}" >/dev/null; echo "  checked_in"
rpc "$WTOK" check_out "{\"p_assignment_id\":\"$ASG\"}" >/dev/null; echo "  checked_out"

echo "== 10) 최종 상태 검증 =="
docker exec -i "$DB" psql -U postgres -d postgres -q <<SQL
select 'request' k, status::text v from job_requests where id='$RID'
union all select 'assignment', status::text from assignments where request_id='$RID'
union all select 'reliability', reliability_score::text from worker_profiles
  where profile_id=(select id from auth.users where phone='821012341111');
SQL
echo "  done"
