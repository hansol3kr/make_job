import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/logger.dart';
import '../../core/theme.dart';
import '../../data/auth.dart';
import '../../data/models.dart';
import '../../data/employer_repository.dart';
import '../../data/profile_repository.dart';

class EmployerHomePage extends ConsumerWidget {
  const EmployerHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(myRequestsProvider);
    final profile = ref.watch(myProfileProvider);
    final bizVerified = ref.watch(employerBizVerifiedProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('사장님 홈'),
        actions: [
          IconButton(
            icon: const Icon(Icons.store_rounded),
            tooltip: '매장 관리',
            onPressed: () => context.push('/employer/stores'),
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: '로그아웃',
            onPressed: () async {
              await ref.read(authRepositoryProvider).signOut();
              if (context.mounted) context.go('/');
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(myRequestsProvider),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primary, AppColors.primaryDark],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.asData?.value?.displayName ?? '사장님',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Text('필요한 순간, 확정된 사람을 실시간으로.',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 14)),
                ],
              ),
            ),
            if (bizVerified.asData?.value == false) ...[
              const SizedBox(height: 16),
              _BizVerifyBanner(onTap: () => _showBizVerifySheet(context, ref)),
            ],
            const SizedBox(height: 24),
            const Text('최근 요청',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            requests.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => _ErrorBox(message: '요청을 불러오지 못했어요\n$e'),
              data: (list) => list.isEmpty
                  ? const _EmptyBox()
                  : Column(
                      children: [
                        for (final r in list) ...[
                          _RequestTile(
                            request: r,
                            onTap: () =>
                                context.go('/employer/matching/${r.id}'),
                            onCancel: () => _cancelRequest(context, ref, r),
                            onDelete: () => _deleteRequest(context, ref, r),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 80),
          ],
        ),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: SizedBox(
          width: double.infinity,
          child: FloatingActionButton.extended(
            onPressed: () => context.go('/employer/new'),
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add_rounded),
            label: const Text('지금 사람 찾기',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  /// 홈 카드에서 바로 취소 — 확정 근로자가 있으면 보상 수수료 경고(상세 화면과 동일 규칙).
  Future<void> _cancelRequest(
      BuildContext context, WidgetRef ref, JobRequest r) async {
    final hasConfirmed = r.filledCount > 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('요청 취소'),
        content: Text(hasConfirmed
            ? '확정된 근로자가 있어요.\n지금 취소하면 근로자에게 드릴 보상 수수료가 붙어요(근무 시점에 따라 급여의 0~50%).\n계속할까요?'
            : '요청을 취소할까요?\n대기 중인 제안이 모두 취소돼요.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('닫기')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('요청 취소'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res =
          await ref.read(employerRepositoryProvider).cancelRequest(r.id);
      final fee = (res['fee_total'] as num?)?.toInt() ?? 0;
      AppLog.i('request_cancelled',
          context: {'request_id': r.id, 'fee': fee, 'from': 'home'});
      ref.invalidate(myRequestsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(fee > 0
                ? '요청을 취소했어요. 근로자 보상 수수료 ${formatWon(fee)}원이 붙었어요.'
                : '요청을 취소했어요.')));
      }
    } catch (e, s) {
      AppLog.e('request_cancel_failed',
          context: {'request_id': r.id, 'from': 'home'}, error: e, stack: s);
      final msg = e.toString().contains('already_closed')
          ? '이미 종료된 요청이에요.'
          : '취소 실패: $e';
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
        ref.invalidate(myRequestsProvider);
      }
    }
  }

  /// 종료된 요청을 목록에서 삭제(보관) — 기록은 보존, 목록에서만 숨김.
  Future<void> _deleteRequest(
      BuildContext context, WidgetRef ref, JobRequest r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('목록에서 삭제'),
        content: const Text('이 요청을 목록에서 삭제할까요?\n근무·정산 기록은 안전하게 보관돼요.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('닫기')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(employerRepositoryProvider).archiveRequest(r.id);
      AppLog.i('request_archived',
          context: {'request_id': r.id, 'from': 'home'});
      ref.invalidate(myRequestsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('목록에서 삭제했어요.')));
      }
    } catch (e, s) {
      AppLog.e('request_archive_failed',
          context: {'request_id': r.id, 'from': 'home'}, error: e, stack: s);
      final msg = e.toString().contains('not_closed')
          ? '진행 중인 요청은 먼저 취소해주세요.'
          : '삭제 실패: $e';
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }
}

class _RequestTile extends StatelessWidget {
  final JobRequest request;
  final VoidCallback onTap;
  final VoidCallback onCancel;
  final VoidCallback onDelete;
  const _RequestTile({
    required this.request,
    required this.onTap,
    required this.onCancel,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final (label, color) = _statusStyle(request);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${request.title} · ${timeRangeLabel(request.startAt, request.endAt)}',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration:
                            BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text(label,
                          style: TextStyle(
                              fontSize: 13,
                              color: color,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, color: AppColors.inkSub),
              tooltip: '요청 관리',
              onSelected: (v) => v == 'cancel' ? onCancel() : onDelete(),
              itemBuilder: (_) => [
                // 진행 중 → 취소, 종료 → 목록에서 삭제(서버 허용 상태와 동일 기준)
                if (isClosedRequestStatus(request.status))
                  const PopupMenuItem(value: 'delete', child: Text('목록에서 삭제'))
                else
                  const PopupMenuItem(value: 'cancel', child: Text('요청 취소')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  (String, Color) _statusStyle(JobRequest r) {
    switch (r.status) {
      case 'confirmed':
      case 'in_progress':
        return ('확정 · ${r.filledCount}/${r.headcount}명', AppColors.accent);
      case 'completed':
        return ('완료', AppColors.inkSub);
      case 'cancelled':
      case 'expired':
        return ('종료', AppColors.inkSub);
      default:
        return ('매칭 중 · ${r.filledCount}/${r.headcount}명', AppColors.warn);
    }
  }
}

class _EmptyBox extends StatelessWidget {
  const _EmptyBox();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
        alignment: Alignment.center,
        child: const Column(
          children: [
            Text('📭', style: TextStyle(fontSize: 44)),
            SizedBox(height: 12),
            Text('아직 요청이 없어요.\n아래 버튼으로 지금 사람을 찾아보세요.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.inkSub)),
          ],
        ),
      );
}

class _ErrorBox extends StatelessWidget {
  final String message;
  const _ErrorBox({required this.message});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(message,
            style: const TextStyle(color: AppColors.danger, fontSize: 13)),
      );
}

/// 미인증 사장님에게 사업자 인증을 권하는 홈 배너.
class _BizVerifyBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _BizVerifyBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.warn.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.warn.withValues(alpha: 0.35)),
        ),
        child: Row(children: [
          const Icon(Icons.verified_user_rounded, color: AppColors.warn),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('사업자 인증하기',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                SizedBox(height: 2),
                Text('인증하면 근로자에게 “인증 사업장”으로 표시돼 더 믿고 지원해요.',
                    style: TextStyle(fontSize: 13, color: AppColors.inkSub)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.inkSub),
        ]),
      ),
    );
  }
}

void _showBizVerifySheet(BuildContext context, WidgetRef ref) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: const _BizVerifySheet(),
    ),
  );
}

class _BizVerifySheet extends ConsumerStatefulWidget {
  const _BizVerifySheet();
  @override
  ConsumerState<_BizVerifySheet> createState() => _BizVerifySheetState();
}

class _BizVerifySheetState extends ConsumerState<_BizVerifySheet> {
  final _biz = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _biz.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final digits = _biz.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 10) {
      setState(() => _error = '사업자등록번호 10자리를 정확히 입력해 주세요');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(employerRepositoryProvider)
          .submitBusinessVerification(digits);
      ref.invalidate(employerBizVerifiedProvider);
      AppLog.i('biz_verified');
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('사업자 인증 완료! 이제 “인증 사업장”으로 표시돼요 ✅')));
    } catch (e, s) {
      AppLog.e('biz_verify_failed', error: e, stack: s);
      if (mounted) setState(() => _error = '인증하지 못했어요. 번호를 다시 확인해 주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('사업자 인증',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            const Text(
                '사업자등록번호를 입력하면 “인증 사업장”으로 표시돼요. 지금은 시범 운영 중이라 형식만 확인하고 바로 인증돼요.',
                style: TextStyle(fontSize: 14, color: AppColors.inkSub)),
            const SizedBox(height: 20),
            TextField(
              controller: _biz,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                hintText: '사업자등록번호 10자리 (- 없이)',
                prefixIcon: Icon(Icons.badge_rounded),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style:
                      const TextStyle(color: AppColors.danger, fontSize: 13)),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('인증하기'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
