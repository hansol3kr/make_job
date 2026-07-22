import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../core/logger.dart';
import '../../data/consent_repository.dart';

/// 법적 동의 화면 — 회원가입(온보딩) 전 필수. 필수 전부 동의해야 진행.
class ConsentAgreementPage extends ConsumerStatefulWidget {
  final String role;
  const ConsentAgreementPage({super.key, required this.role});

  @override
  ConsumerState<ConsentAgreementPage> createState() =>
      _ConsentAgreementPageState();
}

class _ConsentAgreementPageState extends ConsumerState<ConsentAgreementPage> {
  final Map<String, bool> _checked = {for (final c in kConsents) c.type: false};
  final Set<String> _expanded = {};
  bool _busy = false;
  String? _error;

  bool get _allRequiredChecked =>
      kConsents.where((c) => c.required).every((c) => _checked[c.type] == true);
  bool get _allChecked => kConsents.every((c) => _checked[c.type] == true);

  void _toggleAll(bool v) => setState(() {
        for (final c in kConsents) {
          _checked[c.type] = v;
        }
      });

  Future<void> _submit() async {
    if (!_allRequiredChecked) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(consentRepositoryProvider).record(_checked);
      ref.invalidate(consentRequiredMetProvider);
      AppLog.i('consents_recorded', context: {'role': widget.role});
      if (!mounted) return;
      context.go('/onboarding/${widget.role}');
    } catch (e, s) {
      AppLog.e('consents_failed', error: e, stack: s);
      if (mounted) setState(() => _error = '동의 내용을 저장하지 못했어요. 잠시 후 다시 시도해 주세요.\n($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('약관 동의')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                children: [
                  const Text('서비스 이용을 위해\n약관에 동의해 주세요',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 6),
                  const Text('안전하고 믿을 수 있는 매칭을 위해 꼭 필요한 절차예요.',
                      style: TextStyle(fontSize: 14, color: AppColors.inkSub)),
                  const SizedBox(height: 20),
                  _allAgreeTile(),
                  const Divider(height: 24),
                  for (final c in kConsents) _consentTile(c),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: const TextStyle(
                            color: AppColors.danger, fontSize: 13)),
                  ],
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: FilledButton(
                  onPressed:
                      (_busy || !_allRequiredChecked) ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('동의하고 계속'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _allAgreeTile() {
    return InkWell(
      onTap: () => _toggleAll(!_allChecked),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Checkbox(
              value: _allChecked,
              onChanged: (v) => _toggleAll(v ?? false),
            ),
            const Expanded(
              child: Text('전체 동의 (선택 항목 포함)',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _consentTile(ConsentDef c) {
    final open = _expanded.contains(c.type);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Checkbox(
              value: _checked[c.type] ?? false,
              onChanged: (v) =>
                  setState(() => _checked[c.type] = v ?? false),
            ),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(
                    () => _checked[c.type] = !(_checked[c.type] ?? false)),
                child: Row(
                  children: [
                    Text(c.required ? '[필수] ' : '[선택] ',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: c.required
                                ? AppColors.primary
                                : AppColors.inkSub)),
                    Expanded(
                      child: Text(c.title,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            ),
            TextButton(
              onPressed: () => setState(() =>
                  open ? _expanded.remove(c.type) : _expanded.add(c.type)),
              child: Text(open ? '접기' : '보기',
                  style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
        if (open)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(left: 12, bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.line),
            ),
            child: Text(c.text.trim(),
                style: const TextStyle(
                    fontSize: 12.5, height: 1.6, color: AppColors.ink)),
          ),
      ],
    );
  }
}
