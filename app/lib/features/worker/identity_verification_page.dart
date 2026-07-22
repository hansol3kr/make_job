import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../core/logger.dart';
import '../../data/worker_repository.dart';

/// 본인확인 — 실명·계좌 제출 → 매칭 대상(identity_verified)이 됨.
/// MVP 스텁: 제출 즉시 승인(실 본인확인기관 연동 전까지). 원문 식별정보는 서버에 미저장.
class IdentityVerificationPage extends ConsumerStatefulWidget {
  const IdentityVerificationPage({super.key});

  @override
  ConsumerState<IdentityVerificationPage> createState() =>
      _IdentityVerificationPageState();
}

class _IdentityVerificationPageState
    extends ConsumerState<IdentityVerificationPage> {
  final _name = TextEditingController();
  final _account = TextEditingController();
  String? _bank;
  bool _busy = false;
  String? _error;

  static const _banks = [
    '국민', '신한', '우리', '하나', '농협', '기업', '카카오뱅크', '토스뱅크', '새마을', '우체국'
  ];

  @override
  void dispose() {
    _name.dispose();
    _account.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '실명을 입력하세요');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 계좌 원문은 서버로 보내지 않는다 — 표시용 뒤 4자리만 마스킹해 전송.
      final acct = _account.text.trim();
      final acctLast4 = (_bank != null && acct.length >= 4)
          ? acct.substring(acct.length - 4)
          : null;
      await ref.read(workerRepositoryProvider).submitIdentityVerification(
            realName: name,
            bank: _bank,
            acctLast4: acctLast4,
          );
      ref.invalidate(myReliabilityProvider);
      AppLog.i('identity_verified');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('본인확인 완료! 이제 일감을 받을 수 있어요 ✅')));
      context.pop();
    } catch (e, s) {
      AppLog.e('identity_verify_failed', error: e, stack: s);
      if (mounted) setState(() => _error = '제출 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('본인확인')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          children: [
            const Text('안전한 매칭을 위해\n본인확인이 필요해요',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            const Text('실명은 신뢰 보호에, 계좌는 급여 정산에 쓰여요. 계좌번호 원문은 저장하지 않고 뒤 4자리만 보관해요.',
                style: TextStyle(fontSize: 14, color: AppColors.inkSub)),
            const SizedBox(height: 24),
            const Text('실명', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                hintText: '주민등록상 성함',
                prefixIcon: Icon(Icons.badge_rounded),
              ),
            ),
            const SizedBox(height: 20),
            const Text('정산 계좌 (선택)',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.line),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _bank,
                  hint: const Text('은행 선택',
                      style: TextStyle(color: AppColors.inkSub)),
                  items: [
                    for (final b in _banks)
                      DropdownMenuItem(value: b, child: Text('$b은행')),
                  ],
                  onChanged: (v) => setState(() => _bank = v),
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _account,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                hintText: '계좌번호 (- 없이)',
                prefixIcon: Icon(Icons.account_balance_rounded),
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
                Icon(Icons.lock_rounded, size: 18, color: AppColors.primary),
                SizedBox(width: 8),
                Expanded(
                    child: Text('현재는 데모 승인 단계예요. 실 서비스에선 본인확인기관을 거칩니다.',
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
                  : const Text('본인확인 완료하기'),
            ),
          ],
        ),
      ),
    );
  }
}
