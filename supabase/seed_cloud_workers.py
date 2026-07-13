#!/usr/bin/env python3
"""전국 샘플 근로자 시드 (클라우드). Admin API로 auth 유저 생성 → worker_profiles 세팅.
- 인증(identity_verified)·가용(is_available) 상태로 넣어 매칭 후보가 되게 함.
- 재실행 안전: 같은 이메일이면 Admin API가 기존 유저 반환/409 → skip.
사용: python3 supabase/seed_cloud_workers.py
"""
import json, sys, os, random, urllib.request, urllib.error

REF = "umwueaahepuynhbkrnme"
BASE = f"https://{REF}.supabase.co"
SECRETS = os.path.join(os.path.dirname(__file__), "..", "secrets", "appstore")

def read_secret_line(fname, prefix):
    with open(os.path.join(SECRETS, fname)) as f:
        for ln in f:
            ln = ln.strip()
            if ln.startswith(prefix):
                return ln
    return None

SERVICE_KEY = read_secret_line("claud_key", "sb_secret_")
SBP = read_secret_line("claud_key", "sbp_")
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

# 주요 도시 배치 (라벨, lng, lat) — 전국 분산
SPOTS = [
    ("서울 강남", 127.0473, 37.5172), ("서울 마포", 126.9019, 37.5663),
    ("서울 송파", 127.1059, 37.5145), ("부산 해운대", 129.1639, 35.1631),
    ("부산 부산진", 129.0530, 35.1628), ("대구 수성", 128.6500, 35.8400),
    ("인천 남동", 126.7314, 37.4472), ("광주 서구", 126.8895, 35.1519),
    ("대전 유성", 127.3565, 36.3624), ("울산 남구", 129.3300, 35.5439),
    ("경기 성남분당", 127.1188, 37.3827), ("경기 수원영통", 127.0465, 37.2595),
    ("경기 고양일산", 126.7750, 37.6584), ("강원 춘천", 127.7300, 37.8813),
    ("충북 청주", 127.4280, 36.6430), ("전북 전주", 127.1480, 35.8200),
    ("경남 창원", 128.6811, 35.2280), ("제주 제주시", 126.5312, 33.4996),
]
SURNAMES = "김이박최정강조윤장임한오서신권황안"
GIVEN = ["민준","서연","도윤","하은","시우","지우","예준","수아","지호","서준",
         "하준","지안","은우","유진","건우","다은","현우","채원","우진","소율"]

def api(method, path, body=None, key=None):
    # secret 키는 "브라우저 UA면 거부" → Admin API엔 일반(비브라우저) UA 사용.
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
        headers={"apikey": key, "Authorization": f"Bearer {key}",
                 "Content-Type": "application/json", "User-Agent": "jigeum-seed/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {"_err": e.read().decode()[:200]}

def sql(query):
    body = json.dumps({"query": query}).encode()
    req = urllib.request.Request(f"https://api.supabase.com/v1/projects/{REF}/database/query",
        data=body, method="POST",
        headers={"Authorization": f"Bearer {SBP}", "Content-Type": "application/json", "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())

random.seed(42)
created = []
n = 0
for spot, lng, lat in SPOTS:
    for k in range(3):  # 도시당 3명
        n += 1
        email = f"seed_worker_{n:03d}@jigeum.test"
        name = random.choice(SURNAMES) + random.choice(GIVEN)
        st, res = api("POST", "/auth/v1/admin/users",
                      {"email": email, "email_confirm": True,
                       "user_metadata": {"seed": True, "name": name}}, key=SERVICE_KEY)
        uid = res.get("id")
        if not uid:
            # 이미 있으면 조회로 id 확보
            st2, lst = api("GET", f"/auth/v1/admin/users?page=1", key=SERVICE_KEY)
            uid = next((u["id"] for u in lst.get("users", []) if u.get("email") == email), None)
        if not uid:
            print(f"  ⚠️ {email} 생성/조회 실패: {res.get('_err','')[:80]}")
            continue
        jl = random.uniform(-0.012, 0.012); jt = random.uniform(-0.012, 0.012)
        rel = random.choice([48, 55, 62, 70, 78, 85, 92])
        created.append((uid, name, lng + jl, lat + jt, rel))

print(f"유저 생성/확보: {len(created)}명")

# worker_profiles + profiles 일괄 세팅
if created:
    values = ",".join(
        f"('{uid}'::uuid, '{name}', {lng}, {lat}, {rel})" for uid, name, lng, lat, rel in created)
    q = f"""
    with seed(uid, name, lng, lat, rel) as (values {values})
    , upd_prof as (
      update profiles p set role='worker', display_name=s.name
      from seed s where p.id = s.uid returning 1
    )
    insert into worker_profiles (profile_id, home_geog, current_geog, is_available,
                                 identity_verified_at, bank_verified_at, reliability_score, tier)
    select s.uid,
           st_setsrid(st_makepoint(s.lng, s.lat),4326)::geography,
           st_setsrid(st_makepoint(s.lng, s.lat),4326)::geography,
           true, now(), now(), s.rel,
           case when s.rel>=80 then 'top_pro' when s.rel>=60 then 'verified' else 'standard' end
    from seed s
    on conflict (profile_id) do update
       set current_geog=excluded.current_geog, is_available=true,
           identity_verified_at=coalesce(worker_profiles.identity_verified_at, excluded.identity_verified_at),
           reliability_score=excluded.reliability_score, tier=excluded.tier;
    """
    sql(q)
    r = sql("select count(*) c from worker_profiles where is_available and identity_verified_at is not null")
    print("가용·인증 근로자 총:", r)
