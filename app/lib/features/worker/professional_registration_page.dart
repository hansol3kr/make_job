import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../core/logger.dart';
import '../../data/worker_repository.dart';

/// 전문인력 등록 — 본인확인을 마친 사람만 자격/경력을 제출해 전문인력으로 인증.
/// 전문인력만 "전문가 필요" 요청에 매칭된다.
class ProfessionalRegistrationPage extends ConsumerStatefulWidget {
  const ProfessionalRegistrationPage({super.key});

  @override
  ConsumerState<ProfessionalRegistrationPage> createState() =>
      _ProfessionalRegistrationPageState();
}

class _ProfessionalRegistrationPageState
    extends ConsumerState<ProfessionalRegistrationPage> {
  final _cert = TextEditingController();
  final _ref = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _cert.dispose();
    _ref.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final cert = _cert.text.trim();
    if (cert.isEmpty) {
      setState(() => _error = '자격·전문 분야를 입력하세요');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(workerRepositoryProvider).registerProfessional(cert,
          certRef: _ref.text.trim().isEmpty ? null : _ref.text.trim());
      ref.invalidate(myReliabilityProvider);
      AppLog.i('professional_registered');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('전문인력 등록 완료! 전문가 요청을 받을 수 있어요 🎓')));
      context.pop();
    } catch (e, s) {
      AppLog.e('professional_register_failed', error: e, stack: s);
      final msg = e.toString().contains('identity_required')
          ? '먼저 본인확인을 완료해 주세요.'
          : '등록 실패: $e';
      if (mounted) setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('전문인력 등록')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          children: [
            const Text('전문가로 등록하고\n더 높은 단가의 일을 받으세요',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            const Text('본인확인을 마친 분만 등록할 수 있어요. 자격·경력은 심사 후 인증됩니다.',
                style: TextStyle(fontSize: 14, color: AppColors.inkSub)),
            const SizedBox(height: 24),
            const Text('전문 분야 / 자격',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _cert,
              decoration: const InputDecoration(
                hintText: '예: 바리스타 2급 / 행사 MC / 전기기능사',
                prefixIcon: Icon(Icons.workspace_premium_rounded),
              ),
            ),
            const SizedBox(height: 16),
            const Text('증빙 (선택)',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _ref,
              decoration: const InputDecoration(
                hintText: '자격증 번호 / 포트폴리오 링크 등',
                prefixIcon: Icon(Icons.link_rounded),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  style: const TextStyle(color: AppColors.danger, fontSize: 13)),
            ],
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(children: [
                Icon(Icons.info_outline_rounded,
                    size: 18, color: AppColors.primary),
                SizedBox(width: 8),
                Expanded(
                    child: Text('현재는 데모 승인 단계예요. 실 서비스에선 자격 심사를 거칩니다.',
                        style: TextStyle(fontSize: 12, color: AppColors.inkSub))),
              ]),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('전문인력으로 등록'),
            ),
          ],
        ),
      ),
    );
  }
}
