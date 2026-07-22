#!/usr/bin/env bash
# 앱 와이어링 E2E — 앱이 실제 호출하는 경로를 실토큰으로 검증.
# 폰 OTP 인증 → 온보딩 RPC → 요청생성/매칭 RPC → RLS 오퍼조회 → 수락 → 스냅샷 → 체크인/아웃
# → (0021~0027) 매장 다중화 → 매칭 연속성 → 재예약 지명오퍼 → 무료 취소 → 완료 요청 보관.
# 사용: bash supabase/tests/http_app_flow.sh   (로컬 Supabase 실행 중이어야 함)
set -euo pipefail
BASE=http://127.0.0.1:54321
ANON='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0'
WPHONE='+821012341111'   # 데모 근로자 (test_otp 123456)
EPHONE='+821012342222'   # 데모 사장님 (test_otp 123456)
OTP=123456
DB=$(docker ps --format '{{.Names}}' | grep supabase_db | head -1)
py(){ python3 -c "import sys,json;print(json.load(sys.stdin)$1)"; }
sql(){ docker exec -i "$DB" psql -U postgres -d postgres -Atc "$1"; }
fail(){ echo "  FAIL: $*"; exit 1; }

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
rpc_code(){ # $1=token $2=fn $3=json → 응답 본문 + 마지막 줄에 http status
  curl -s -w '\n%{http_code}' -X POST "$BASE/rest/v1/rpc/$2" -H "apikey: $ANON" \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" -d "$3"
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
# 0030: 온보딩은 서버측 동의 게이트를 요구 → 앱과 동일하게 필수 동의 5종 먼저 기록.
CONSENTS='{"p_items":[{"type":"tos","granted":true},{"type":"privacy","granted":true},{"type":"privacy_3rd","granted":true},{"type":"location","granted":true},{"type":"age14","granted":true}]}'
rpc "$WTOK" record_consents "$CONSENTS" >/dev/null
rpc "$ETOK" record_consents "$CONSENTS" >/dev/null
echo "  consents recorded (worker/employer)"
rpc "$WTOK" complete_worker_onboarding '{"p_display_name":"데모근로자","p_lng":127.0276,"p_lat":37.4979}' >/dev/null
echo "  worker onboarding done"
# 0009부터 온보딩은 identity_verified를 주지 않는다 → 앱과 동일하게 본인확인 RPC 별도 호출.
# (이게 빠지면 nearby_candidates에 안 잡혀 step 5 오퍼가 0건이 된다)
rpc "$WTOK" submit_identity_verification '{"p_real_name":"데모근로자"}' >/dev/null
echo "  worker identity verified"
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

# ─────────────────────────────────────────────────────────────────────
# 이하 0021~0027 신규 RPC 실토큰 검증 (매장·매칭연속성·재예약·취소·보관)
# ─────────────────────────────────────────────────────────────────────

echo "== 11) [employer] my_stores → 기본 매장 확인 + add_store(2호점) =="
STORES=$(rpc "$ETOK" my_stores '{}')
echo "  stores=$STORES"
echo "$STORES" | python3 -c "
import sys,json
s=json.load(sys.stdin)
d=[x['name'] for x in s if x['is_default']]
assert d==['데모카페'], ('기본 매장 이상', s)
print('  기본 매장 확인: 데모카페')"
SID2=$(rpc "$ETOK" add_store '{"p_name":"2호점 E2E","p_lat":37.5665,"p_lng":126.9780,"p_address":"서울시청 인근"}' | tr -d '"')
[ ${#SID2} -eq 36 ] || fail "add_store 실패: $SID2"
echo "  store2_id=$SID2"
rpc "$ETOK" my_stores '{}' | python3 -c "
import sys,json
s=json.load(sys.stdin)
assert '2호점 E2E' in [x['name'] for x in s], s
assert [x['name'] for x in s if x['is_default']]==['데모카페'], ('기본 매장이 바뀜', s)
print('  2호점 추가 + 기본 매장 유지 확인')"

echo "== 12) [employer] 외딴 좌표(제주) 요청 → 후보 0명 → continue_matching =="
JSTART=$(date -u -d '+3 hours' +%Y-%m-%dT%H:%M:%SZ)
JEND=$(date -u -d '+9 hours' +%Y-%m-%dT%H:%M:%SZ)
JID=$(rpc "$ETOK" create_job_request "{\"p_title\":\"제주 외딴 E2E\",\"p_start_at\":\"$JSTART\",\"p_end_at\":\"$JEND\",\"p_pay_amount\":95000,\"p_lng\":126.5,\"p_lat\":33.5}" | tr -d '"')
[ ${#JID} -eq 36 ] || fail "제주 요청 생성 실패: $JID"
JN=$(rpc "$ETOK" request_matching "{\"p_request_id\":\"$JID\"}")
[ "$JN" = "0" ] || fail "제주 외딴 요청인데 오퍼가 생성됨: $JN"
echo "  request_matching=0 (후보 없음)"
OUT=$(rpc_code "$ETOK" continue_matching "{\"p_request_id\":\"$JID\"}")
CODE=$(echo "$OUT" | tail -1); BODY=$(echo "$OUT" | head -n -1)
[ "$CODE" = "200" ] || fail "continue_matching http $CODE: $BODY"
echo "  continue_matching(200): $BODY"
MA=$(sql "select match_attempts from job_requests where id='$JID'")
[ "${MA:-0}" -ge 1 ] || fail "match_attempts 미증가: '$MA'"
echo "  match_attempts=$MA (증가 확인 — sweep cron이 병행 증가시킬 수 있어 >=1 판정)"

echo "== 13) [employer] 재예약(rebook_worker) → 근로자 RLS로 지명 오퍼 확인 =="
RSTART=$(date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ)
REND=$(date -u -d '+30 hours' +%Y-%m-%dT%H:%M:%SZ)
RBID=$(rpc "$ETOK" rebook_worker "{\"p_assignment_id\":\"$ASG\",\"p_start_at\":\"$RSTART\",\"p_end_at\":\"$REND\"}" | tr -d '"')
[ ${#RBID} -eq 36 ] || fail "rebook_worker 실패: $RBID"
echo "  rebook_request_id=$RBID"
curl -s "$BASE/rest/v1/match_offers?select=status,reason&request_id=eq.$RBID" \
  -H "apikey: $ANON" -H "Authorization: Bearer $WTOK" | python3 -c "
import sys,json
o=json.load(sys.stdin)
assert len(o)==1 and o[0]['status']=='offered', o
assert o[0]['reason'].get('rebook') is True, o
print('  [worker RLS] 지명 오퍼(offered, rebook=true) 확인')"
curl -s "$BASE/rest/v1/job_requests?select=status&id=eq.$RBID" \
  -H "apikey: $ANON" -H "Authorization: Bearer $WTOK" | python3 -c "
import sys,json
r=json.load(sys.stdin)
assert r==[{'status':'matching'}], r
print('  [worker RLS] 재예약 요청(matching) 조회 확인')"

echo "== 14) [employer] cancel_job_request — matching 상태 무료 취소 =="
CRES=$(rpc "$ETOK" cancel_job_request "{\"p_request_id\":\"$RBID\"}")
echo "  $CRES"
echo "$CRES" | python3 -c "
import sys,json
r=json.load(sys.stdin)
assert r['cancelled'] is True and r['confirmed_cancelled']==0 and r['fee_total']==0, r
print('  무료 취소(확정자 0·수수료 0) 확인')"
ST=$(sql "select status from job_requests where id='$RBID'")
[ "$ST" = "cancelled" ] || fail "취소 후 요청 상태 이상: $ST"
OST=$(sql "select status from match_offers where request_id='$RBID'")
[ "$OST" = "cancelled" ] || fail "지명 오퍼 미취소: $OST"
echo "  요청·지명 오퍼 모두 cancelled (psql 확인)"

echo "== 15) [employer] archive_job_request — 완료 요청 보관 =="
# 제품 갭 우회: check_out은 assignment만 completed로 만들고 요청은 in_progress에 남는다
# (요청을 completed로 전이하는 서버 경로 부재 — 알려진 갭). 보관 RPC 검증 위해 psql 보정.
sql "update job_requests set status='completed' where id='$RID'" >/dev/null
rpc "$ETOK" archive_job_request "{\"p_request_id\":\"$RID\"}" >/dev/null
ARC=$(sql "select (archived_at is not null)::text from job_requests where id='$RID'")
[ "$ARC" = "true" ] || fail "archived_at 미설정: $ARC"
echo "  archived_at 설정 확인 (psql)"

echo "== 16) 신규 리소스 정리 (11~15 추가분만 — 코어 플로우 데이터는 다음 실행 step 0에서 정리) =="
docker exec -i "$DB" psql -U postgres -d postgres -q <<SQL
delete from match_offers where request_id in ('$JID','$RBID');
delete from job_requests where id in ('$JID','$RBID');
delete from stores where id = '$SID2';
SQL
echo "  ok"

echo "== 전구간 통과 =="
