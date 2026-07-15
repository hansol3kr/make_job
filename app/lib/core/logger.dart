import 'dart:async';
import 'package:flutter/foundation.dart';
import 'platform_info.dart';
import 'supabase_client.dart';

/// 원격 로그 채널. 앱에서 발생한 에러/이벤트를 클라우드 `client_logs`에 적재해
/// 개발자가 실시간으로 디버깅할 수 있게 한다. 로깅 실패는 조용히 삼켜 앱에 영향 없음.
///
/// 사용: `AppLog.i('메시지', context: {...})`, `AppLog.e('에러', error: e, stack: s)`.
/// 부팅 시 [init]으로 전역 에러 핸들러를 설치한다(main의 runZonedGuarded 안에서 호출).
class AppLog {
  AppLog._();
  static final AppLog _i = AppLog._();

  static const _appVersion =
      String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');
  static const _buildNumber =
      String.fromEnvironment('APP_BUILD', defaultValue: 'dev');

  bool _inited = false;
  String _sessionId = 'pre-init';
  String _device = 'unknown';
  String? _route;
  final List<Map<String, dynamic>> _buffer = [];

  /// 부팅 시 1회. 전역 에러 핸들러 설치 + 주기적 flush 시작.
  static void init() => _i._init();

  /// 현재 화면 경로 갱신(라우터에서 호출).
  static void setRoute(String? route) => _i._route = route;

  void _init() {
    if (_inited) return;
    _inited = true;
    final now = DateTime.now();
    _sessionId = '${now.microsecondsSinceEpoch}-${now.hashCode & 0xffff}';
    try {
      _device = platformDevice();
    } catch (_) {}

    // 주기적 flush (periodic 타이머는 이벤트루프가 유지하므로 참조 보관 불필요)
    Timer.periodic(const Duration(seconds: 3), (_) => _flush());

    // Flutter 프레임워크 에러
    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      prev?.call(details);
      _add('error', 'flutter_error',
          error: details.exceptionAsString(), stack: details.stack?.toString());
    };

    // 처리 안 된 비동기 에러(플랫폼 디스패처)
    PlatformDispatcher.instance.onError = (error, stack) {
      _add('fatal', 'platform_error',
          error: error.toString(), stack: stack.toString());
      return false; // 기본 핸들러로도 전달(콘솔 출력 유지)
    };
  }

  void _add(String level, String message,
      {Object? context, String? error, String? stack}) {
    if (kDebugMode) {
      debugPrint('[$level] $message ${error ?? ''}');
    }
    _buffer.add({
      'level': level,
      'message': message,
      'context': ?context,
      'error': ?error,
      'stack': ?stack,
      'route': ?_route,
      'session_id': _sessionId,
      'platform': _safeOs(),
      'app_version': _appVersion,
      'build_number': _buildNumber,
      'device': _device,
    });
    // 에러/치명은 즉시 전송, 그 외는 버퍼가 차면 전송
    if (level == 'error' || level == 'fatal' || _buffer.length >= 10) {
      _flush();
    }
  }

  String _safeOs() {
    try {
      return platformOs();
    } catch (_) {
      return 'unknown';
    }
  }

  Future<void> _flush() async {
    if (_buffer.isEmpty) return;
    final batch = List<Map<String, dynamic>>.from(_buffer);
    _buffer.clear();
    try {
      await supabase.from('client_logs').insert(batch);
    } catch (_) {
      // 로깅 실패는 삼킨다(재시도 안 함 — 무한루프/앱영향 방지).
    }
  }

  // ── 공개 API ──────────────────────────────────────────────────────────────
  static void d(String m, {Object? context}) =>
      _i._add('debug', m, context: context);
  static void i(String m, {Object? context}) =>
      _i._add('info', m, context: context);
  static void w(String m, {Object? context, Object? error}) =>
      _i._add('warn', m, context: context, error: error?.toString());
  static void e(String m, {Object? context, Object? error, Object? stack}) =>
      _i._add('error', m,
          context: context, error: error?.toString(), stack: stack?.toString());
}
