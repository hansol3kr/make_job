import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:jigeum/core/env.dart';
import 'package:jigeum/features/auth/phone_login_page.dart';

/// 테스트용 인메모리 저장소 — Supabase.initialize가 SharedPreferences 플러그인을
/// 건드리지 않게 해 헤드리스 테스트에서 플러그인 에러를 피한다.
class _MemStore extends GotrueAsyncStorage {
  final _m = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => _m[key];
  @override
  Future<void> setItem({required String key, required String value}) async =>
      _m[key] = value;
  @override
  Future<void> removeItem({required String key}) async => _m.remove(key);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabasePublishableKey,
      authOptions: FlutterAuthClientOptions(
        localStorage: const EmptyLocalStorage(),
        pkceAsyncStorage: _MemStore(),
      ),
    );
  });

  testWidgets('로그인 화면: 활성 간편 로그인만 노출 + 인증번호 받기가 보인다', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: PhoneLoginPage(role: 'worker')),
    ));
    await tester.pump();

    // 폰 로그인은 항상 1순위.
    expect(find.text('인증번호 받기'), findsOneWidget);

    // 기본 ENABLED_OAUTH=google → 구글만 노출, 서버 미설정 provider는 숨김(죽은 버튼 금지).
    expect(find.text('Google로 시작하기'), findsOneWidget);
    expect(find.text('카카오로 시작하기'), findsNothing);
    expect(find.text('네이버로 시작하기'), findsNothing);
    expect(find.text('토스로 시작하기'), findsNothing);
    expect(find.text('Apple로 시작하기'), findsNothing);

    // '준비 중' 죽은 버튼/뱃지는 더 이상 없다.
    expect(find.text('준비 중'), findsNothing);
  });
}
