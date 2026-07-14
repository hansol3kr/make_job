import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:jigeum/core/env.dart';
import 'package:jigeum/features/common/chat_page.dart';

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

  testWidgets('채팅 화면: 앱바 제목과 입력창이 렌더된다', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(
        home: ChatPage(assignmentId: 'c1000000-0000-0000-0000-0000000000b1'),
      ),
    ));
    await tester.pump();

    expect(find.text('채팅'), findsOneWidget); // AppBar
    expect(find.widgetWithText(TextField, ''), findsWidgets); // 입력창 존재
    expect(find.byIcon(Icons.send_rounded), findsOneWidget); // 전송 버튼
  });
}
