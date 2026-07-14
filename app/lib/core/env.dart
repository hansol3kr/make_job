/// 환경 설정. 실제 배포 값은 `--dart-define`으로 주입.
/// 기본값은 로컬 Supabase(공개 publishable 키 · 로컬 전용).
class Env {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'http://127.0.0.1:54321',
  );
  static const supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
  );

  /// 서버(Supabase)에 실제 설정이 끝나 로그인 가능한 소셜 provider 목록.
  /// 미설정 provider를 켜면 탭 시 외부 브라우저 에러로 빠지므로, 서버 설정 완료분만 넣는다.
  /// 빌드별로 `--dart-define=ENABLED_OAUTH=google,kakao,apple` 로 확장.
  static const String _enabledOAuthRaw = String.fromEnvironment(
    'ENABLED_OAUTH',
    defaultValue: 'google',
  );

  /// 소문자 provider 이름 집합(예: {'google'}). 버튼 활성/안내 분기에 사용.
  static Set<String> get enabledOAuth => _enabledOAuthRaw
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toSet();
}
