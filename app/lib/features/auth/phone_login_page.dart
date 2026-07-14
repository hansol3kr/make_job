import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme.dart';
import '../../core/env.dart';
import '../../core/supabase_client.dart';
import '../../core/logger.dart';
import '../../data/auth.dart';
import '../../data/profile_repository.dart';

/// 간편 로그인 provider 정의(표시 순서대로). 네이버·토스는 Supabase 커스텀 OAuth.
class _OAuthOption {
  final String label; // 버튼 문구용 이름
  final OAuthProvider provider;
  final Color bg;
  final Color fg;
  final IconData icon;
  final bool border;
  const _OAuthOption(this.label, this.provider,
      {required this.bg, required this.fg, required this.icon, this.border = false});
}

const _oauthOptions = <_OAuthOption>[
  _OAuthOption('카카오', OAuthProvider.kakao,
      bg: Color(0xFFFEE500), fg: Color(0xFF191600), icon: Icons.chat_bubble_rounded),
  _OAuthOption('네이버', OAuthProvider('naver'),
      bg: Color(0xFF03C75A), fg: Colors.white, icon: Icons.navigation_rounded),
  _OAuthOption('토스', OAuthProvider('toss'),
      bg: Color(0xFF0064FF), fg: Colors.white, icon: Icons.account_balance_wallet_rounded),
  _OAuthOption('Apple', OAuthProvider.apple,
      bg: Color(0xFF111111), fg: Colors.white, icon: Icons.apple_rounded),
  _OAuthOption('Google', OAuthProvider.google,
      bg: Colors.white, fg: Color(0xFF1F1F1F), icon: Icons.g_mobiledata_rounded, border: true),
];

/// 폰 OTP 로그인. role('worker'|'employer')에 따라 이후 온보딩/홈 분기.
class PhoneLoginPage extends ConsumerStatefulWidget {
  final String role;
  const PhoneLoginPage({super.key, required this.role});

  @override
  ConsumerState<PhoneLoginPage> createState() => _PhoneLoginPageState();
}

class _PhoneLoginPageState extends ConsumerState<PhoneLoginPage> {
  final _phone = TextEditingController();
  final _otp = TextEditingController();
  bool _otpSent = false;
  bool _busy = false;
  String? _error;
  String _phoneE164 = '';
  bool _oauthPending = false;
  StreamSubscription<AuthState>? _authSub;

  bool get _isEmployer => widget.role == 'employer';

  @override
  void initState() {
    super.initState();
    // 소셜 로그인은 외부 브라우저 → 딥링크 복귀로 세션이 수립되므로,
    // signedIn 이벤트를 받아 온보딩/홈으로 분기한다.
    _authSub = supabase.auth.onAuthStateChange.listen((data) {
      // 진단: 어떤 이벤트가 오는지 원격 로그로 확인.
      AppLog.i('auth_event', context: {
        'event': data.event.name,
        'has_session': data.session != null,
        'oauth_pending': _oauthPending,
        'route': '/login/${widget.role}',
      });
      // 소셜 로그인 복귀 시 세션 수립 → 온보딩/홈으로. _oauthPending 유무와 무관하게
      // signedIn이면 이동(복귀 중 페이지 리빌드로 플래그가 초기화돼도 안전하게 처리).
      if (data.event == AuthChangeEvent.signedIn && mounted) {
        _oauthPending = false;
        _postLoginNav();
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _phone.dispose();
    _otp.dispose();
    super.dispose();
  }

  /// 로그인 성공 후 공통 분기: 역할 프로필 없으면 온보딩, 있으면 홈.
  Future<void> _postLoginNav() async {
    try {
      final status = await ref.read(profileRepositoryProvider).onboardingStatus();
      if (!mounted) return;
      final needsOnboarding =
          _isEmployer ? !status.hasEmployerProfile : !status.hasWorkerProfile;
      final target = needsOnboarding
          ? '/onboarding/${widget.role}'
          : (_isEmployer ? '/employer' : '/worker');
      AppLog.i('post_login_nav', context: {'target': target, 'role': widget.role});
      context.go(target);
    } catch (e, s) {
      AppLog.e('post_login_nav_failed', error: e, stack: s);
      if (mounted) setState(() => _error = '로그인 후 이동 실패: $e');
    }
  }

  Future<void> _oauth(_OAuthOption opt) async {
    // 서버에 설정이 끝난 provider만 실제 실행. 미설정 provider는 외부 브라우저 에러로
    // 빠지므로(앱 catch로 안 잡힘) 여기서 먼저 안내한다.
    if (!Env.enabledOAuth.contains(opt.provider.name)) {
      setState(() => _error =
          '${opt.label} 로그인은 아직 준비 중이에요. 지금은 Google 또는 휴대폰 번호로 로그인해주세요.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _oauthPending = true;
    });
    try {
      await ref.read(authRepositoryProvider).signInWithOAuth(opt.provider);
      // 이후 흐름은 onAuthStateChange(signedIn) 리스너가 처리.
    } catch (e, s) {
      AppLog.e('oauth_failed', context: {'provider': opt.provider.name}, error: e, stack: s);
      if (mounted) {
        final msg = oauthErrorMessage(opt.label, e);
        setState(() {
          _oauthPending = false;
          if (msg.isNotEmpty) _error = msg; // 사용자가 창을 닫은 경우엔 조용히 무시
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendOtp() async {
    // 서버로 보내기 전 형식 검증 → 형식 오류는 그 자리에서 안내.
    final formatError = validateKoreanPhone(_phone.text);
    if (formatError != null) {
      setState(() => _error = formatError);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    _phoneE164 = normalizeKoreanPhone(_phone.text);
    try {
      await ref.read(authRepositoryProvider).sendOtp(_phoneE164);
      if (!mounted) return;
      setState(() => _otpSent = true);
    } on AuthException catch (e) {
      AppLog.w('otp_send_failed',
          context: {'code': e.code, 'status': e.statusCode}, error: e);
      if (mounted) setState(() => _error = authErrorMessage(e));
    } catch (e, s) {
      AppLog.e('otp_send_failed', error: e, stack: s);
      if (mounted) setState(() => _error = authErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    // 6자리 숫자인지 먼저 확인 → 형식 오류는 서버 호출 없이 안내.
    final formatError = validateOtpToken(_otp.text);
    if (formatError != null) {
      setState(() => _error = formatError);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).verifyOtp(_phoneE164, _otp.text.trim());
      await _postLoginNav();
    } on AuthException catch (e) {
      AppLog.w('otp_verify_failed',
          context: {'code': e.code, 'status': e.statusCode}, error: e);
      if (mounted) setState(() => _error = authErrorMessage(e));
    } catch (e, s) {
      AppLog.e('otp_verify_failed', error: e, stack: s);
      if (mounted) setState(() => _error = authErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = _isEmployer ? AppColors.primary : AppColors.accent;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEmployer ? '사장님 로그인' : '근로자 로그인'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go('/'),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          children: [
            Text(
              _otpSent ? '인증번호를 입력하세요' : '휴대폰 번호로 시작하기',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              _otpSent
                  ? '$_phoneE164 로 보낸 6자리 코드'
                  : '가입/로그인이 한 번에 됩니다. 번호는 안심번호로 보호돼요.',
              style: const TextStyle(fontSize: 14, color: AppColors.inkSub),
            ),
            const SizedBox(height: 24),
            if (!_otpSent) ...[
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-]'))
                ],
                decoration: const InputDecoration(
                  labelText: '휴대폰 번호',
                  hintText: '010-1234-5678',
                  prefixIcon: Icon(Icons.phone_rounded),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _sendOtp,
                child: _busy
                    ? const _Spinner()
                    : const Text('인증번호 받기'),
              ),
            ] else ...[
              TextField(
                controller: _otp,
                keyboardType: TextInputType.number,
                autofocus: true,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: '인증번호 6자리',
                  prefixIcon: Icon(Icons.lock_rounded),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: accent),
                onPressed: _busy ? null : _verify,
                child: _busy ? const _Spinner() : const Text('확인'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _otpSent = false;
                          _otp.clear();
                        }),
                child: const Text('번호 다시 입력'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        color: AppColors.danger, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(_error!,
                            style: const TextStyle(
                                color: AppColors.danger, fontSize: 13))),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('간편 로그인',
                    style: TextStyle(fontSize: 12, color: AppColors.inkSub)),
              ),
              const Expanded(child: Divider()),
            ]),
            const SizedBox(height: 16),
            for (final opt in _oauthOptions) ...[
              _SocialButton(
                label: '${opt.label}로 시작하기',
                bg: opt.bg,
                fg: opt.fg,
                icon: opt.icon,
                border: opt.border,
                pending: !Env.enabledOAuth.contains(opt.provider.name),
                onTap: _busy ? null : () => _oauth(opt),
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.line),
              ),
              child: const Text(
                '🧪 로컬 데모 계정\n'
                '· 근로자: 010-1234-1111\n'
                '· 사장님: 010-1234-2222\n'
                '· 인증번호: 123456',
                style: TextStyle(
                    fontSize: 12, height: 1.6, color: AppColors.inkSub),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
}

class _SocialButton extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  final IconData icon;
  final bool border;
  final bool pending;
  final VoidCallback? onTap;
  const _SocialButton({
    required this.label,
    required this.bg,
    required this.fg,
    required this.icon,
    required this.onTap,
    this.border = false,
    this.pending = false,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: pending ? 0.55 : 1,
      child: SizedBox(
        height: 52,
        child: FilledButton(
          onPressed: onTap,
          style: FilledButton.styleFrom(
            backgroundColor: bg,
            foregroundColor: fg,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: border
                  ? const BorderSide(color: AppColors.line)
                  : BorderSide.none,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: fg),
              const SizedBox(width: 8),
              Text(label,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              if (pending) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: fg.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('준비 중',
                      style: TextStyle(
                          fontSize: 10, fontWeight: FontWeight.w700, color: fg)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
