import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'core/supabase_client.dart';
import 'core/logger.dart';

Future<void> main() async {
  // runZonedGuarded로 감싸 처리 안 된 비동기 에러까지 원격 로그로 수집.
  // (바인딩 초기화·runApp이 반드시 같은 zone 안에 있어야 함)
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await initSupabase();
    AppLog.init();
    AppLog.i('app_start');
    runApp(const ProviderScope(child: JigeumApp()));
  }, (error, stack) {
    AppLog.e('zone_uncaught', error: error, stack: stack);
  });
}

class JigeumApp extends StatelessWidget {
  const JigeumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: '지금인력',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: appRouter,
    );
  }
}
