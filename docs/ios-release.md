# iOS 출시 런북 — Mac 없이 (Codemagic)

> **핵심:** Xcode는 macOS 전용이라 파이프라인 어딘가엔 macOS가 필요하다. 하지만 **Mac을 소유할 필요는 없다.** 코드는 Linux에서 작성하고, 빌드·서명·업로드는 Codemagic 클라우드 macOS가 대신한다. 실제 파이프라인은 리포지토리 루트 [`codemagic.yaml`](../codemagic.yaml).

## 0. 현재 상태 (준비 완료된 것)

- [x] Flutter iOS 타깃 생성 — `app/ios/`, Bundle ID **`kr.jigeum.jigeum`** (Android와 동일)
- [x] iOS 배포 타깃 **13.0** (supabase_flutter 요구 충족)
- [x] 위치 권한 문구 `NSLocationWhenInUseUsageDescription` (Info.plist) — 매칭/거리계산용
- [x] `codemagic.yaml` — 자동 코드사이닝 + TestFlight 업로드 워크플로우
- [ ] **활성화(아래 절차)** — 실제 스토어 제출은 코어 루프(M1b) 동작 검증 후

## 1. 왜 이 방식인가 (선택지 비교)

| 방법 | 비용 | 우리 선택 이유 |
|---|---|---|
| **Codemagic** ⭐ | 개인 무료 500분/월 macOS M2, 초과 $0.095/분 | Flutter 네이티브, 자동 서명, TestFlight 직접 업로드, Mac 0원 |
| GitHub Actions (macOS 러너) | 프라이빗 레포 macOS 분 ×10 소진 | fastlane 직접 구성 필요 → 손 더 감 |
| 원격 Mac 임대 (MacinCloud) | 시간당 ~$1 | iOS 전용 디버깅/시뮬레이터 필요할 때 **보조**로만 |
| 중고 Mac mini | 일시금(중고) | 진지하게 오래 갈 거면 장기적으로 가장 편함 |

> **Xcode Cloud는 제외** — 초기 워크플로우 설정을 Xcode(macOS)에서 해야 해 "완전 Mac-free"가 아님.

## 2. 활성화 절차 (전부 웹, Mac 불필요)

### ① App Store Connect API 키 발급
1. [App Store Connect](https://appstoreconnect.apple.com) → **Users and Access** → **Integrations** → **App Store Connect API**
2. **팀 키(Team Key)** 생성, 역할 **App Manager**(또는 Admin)
3. 발급되는 값 3개 확보: **Issuer ID**, **Key ID**, **`.p8` 개인키 파일**(한 번만 다운로드 가능 — 잘 보관)

### ② Codemagic에 API 키 등록
1. [codemagic.io](https://codemagic.io) 가입 → GitHub 리포 연결
2. **Teams(또는 Personal) → Integrations → App Store Connect** → 위 3개 값 업로드
3. 이때 지은 **키 이름**을 `codemagic.yaml`의 `app_store_connect: <ASC_API_KEY_NAME>` 에 그대로 기입

### ③ 앱 레코드 생성
1. App Store Connect → **Apps → +** → 새 앱
2. Bundle ID: **`kr.jigeum.jigeum`** 선택(없으면 Certificates, Identifiers & Profiles에서 먼저 등록)
3. 생성 후 앱의 **숫자 Apple ID**(예: `6501234567`)를 `codemagic.yaml`의 `APP_STORE_APPLE_ID` 에 기입

### ④ 첫 빌드
- GitHub에 push하거나 Codemagic UI에서 `ios-testflight` 워크플로우 **Start build**
- 성공 시 IPA가 자동으로 **TestFlight**에 올라감 → 내 iPhone의 TestFlight 앱에서 설치·테스트
- 첫 빌드는 앱 레코드가 없으면 `get-latest-testflight-build-number`가 0을 반환 → 빌드번호 1로 시작(정상)

## 3. Mac 없이 갈 때의 한계 (정직하게)

- **iOS 시뮬레이터를 로컬에서 못 돌린다** (Simulator는 macOS 전용). iOS 화면 확인은 **실기기 + TestFlight**로. 필요 시 MacinCloud 시간제 세션.
- iOS 전용 버그(서명/entitlement/권한) 디버깅 루프가 느리다: push → 클라우드 빌드(10~20분) → 확인.
- 무료 500분은 빌드 1회 10~20분이라 삽질하면 금방 소진. **빈 앱을 반복 빌드하지 말 것** → 코어 루프 완성 후 활성화.

## 4. 다음에 iOS에 추가로 필요한 것 (M2+)

- **푸시(APNs)** — 앱이 백그라운드/종료 상태일 때 실시간 오퍼 알림. Supabase Realtime(웹소켓)은 앱이 열려 있을 때만 유효하므로, 오퍼 도착 알림엔 APNs 필수.
  - APNs 인증키(.p8) 발급 → FCM 또는 Edge Function에서 발송 → Info.plist `UIBackgroundModes: remote-notification` 추가
- **개인정보 처리방침 URL**, App Privacy(수집 데이터: 위치/연락처 등) 설문 — 심사 필수
- 카메라/사진 권한 문구(`NSCameraUsageDescription` 등) — 신원인증/프로필 사진 도입 시
