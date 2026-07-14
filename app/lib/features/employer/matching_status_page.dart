import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/logger.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/employer_repository.dart';

/// 실시간 매칭 상태: 매칭중(오퍼 전송) → 확정(배정 근로자 카드).
class MatchingStatusPage extends ConsumerWidget {
  final String requestId;
  const MatchingStatusPage({super.key, required this.requestId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(matchingProvider(requestId));
    final confirmed = snap.asData?.value.isConfirmed ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text(confirmed ? '확정 완료' : '실시간 매칭 중'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => context.go('/employer'),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: snap.when(
          loading: () => _matchingView(null),
          error: (e, _) => Center(
            child: Text('매칭 현황을 불러오지 못했어요\n$e',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.danger)),
          ),
          data: (s) => s.isConfirmed && s.workers.isNotEmpty
              ? _confirmedView(context, ref, s)
              : _matchingView(s),
        ),
      ),
    );
  }

  Widget _matchingView(MatchingSnapshot? s) {
    final offered = s?.offeredCount ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 40),
        const SizedBox(
          width: 72,
          height: 72,
          child: CircularProgressIndicator(strokeWidth: 6),
        ),
        const SizedBox(height: 28),
        const Text('가까운 검증된 분들에게\n오퍼를 보내는 중...',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 22, height: 1.35, fontWeight: FontWeight.w900)),
        const SizedBox(height: 12),
        Text(
          offered == 0
              ? '반경 3km · 인증 완료 · 신뢰도순 정렬'
              : '$offered명에게 오퍼 전송됨 · 응답 대기(60초)',
          style: const TextStyle(fontSize: 15, color: AppColors.inkSub),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Row(
            children: [
              Icon(Icons.info_outline_rounded, color: AppColors.primary),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '“지원자”가 아니라 수락 즉시 “확정된 사람”이 배정됩니다. 취소돼도 자동 백필로 다시 채워요.',
                  style: TextStyle(fontSize: 13, height: 1.45),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _confirmedView(BuildContext context, WidgetRef ref, MatchingSnapshot s) {
    final w = s.workers.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                  color: AppColors.accent, shape: BoxShape.circle),
              child: const Icon(Icons.check_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text(s.filledCount >= s.headcount ? '확정됐어요!' : '확정 중 (${s.filledCount}/${s.headcount})',
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
          ],
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  const CircleAvatar(
                    radius: 30,
                    backgroundColor: AppColors.bg,
                    child: Text('🧑', style: TextStyle(fontSize: 28)),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(w.displayName ?? '확정된 근로자',
                            style: const TextStyle(
                                fontSize: 20, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(Icons.star_rounded,
                                color: AppColors.warn, size: 18),
                            Text(' ${(w.reliability ?? 0).toStringAsFixed(0)} 신뢰도',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            Text(w.status == 'checked_in' ? '  ·  근무 중' : '  ·  대기 중',
                                style:
                                    const TextStyle(color: AppColors.inkSub)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: (v) {
                      if (v == 'noshow') {
                        _reportNoShow(context, ref, w.assignmentId);
                      } else if (v == 'rate') {
                        _rateWorker(context, ref, w.assignmentId);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rate', child: Text('평가하기')),
                      PopupMenuItem(value: 'noshow', child: Text('노쇼 신고')),
                    ],
                  ),
                ],
              ),
              const Divider(height: 28),
              Row(
                children: [
                  _stat('거리', w.distanceM == null ? '-' : '${w.distanceM}m'),
                  _stat('인원', '${s.filledCount}/${s.headcount}'),
                  _stat('계약', 'e-근로계약'),
                ],
              ),
            ],
          ),
        ),
        const Spacer(),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.call_rounded),
                label: const Text('안심통화'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => context.go('/employer'),
                icon: const Icon(Icons.check_rounded),
                label: const Text('완료'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Future<void> _reportNoShow(
      BuildContext context, WidgetRef ref, String assignmentId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('노쇼 신고'),
        content: const Text(
            '근로자가 나타나지 않았나요? 신고 시 해당 근로자 신뢰도가 하락하고, 빈자리는 자동으로 백필됩니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('닫기')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('신고')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final n =
          await ref.read(employerRepositoryProvider).reportNoShow(assignmentId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('노쇼 처리됨 · 백필 오퍼 $n건 전송')));
      }
    } catch (e, s) {
      AppLog.e('report_no_show_failed',
          context: {'assignment_id': assignmentId}, error: e, stack: s);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('신고 실패: $e')));
      }
    }
  }

  Future<void> _rateWorker(
      BuildContext context, WidgetRef ref, String assignmentId) async {
    var stars = 5;
    final comment = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              left: 24,
              right: 24,
              top: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('근로자는 어땠나요?',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              const Text('서로 평가를 남기면 양쪽에 공개돼요 (더블블라인드).',
                  style: TextStyle(fontSize: 13, color: AppColors.inkSub)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 1; i <= 5; i++)
                    IconButton(
                      onPressed: () => setSheet(() => stars = i),
                      icon: Icon(
                          i <= stars
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          size: 40,
                          color: AppColors.warn),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: comment,
                decoration: const InputDecoration(
                    hintText: '한줄 후기 (선택)',
                    prefixIcon: Icon(Icons.rate_review_rounded)),
                maxLength: 100,
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () async {
                  try {
                    await ref
                        .read(employerRepositoryProvider)
                        .submitRating(assignmentId, stars,
                            comment: comment.text.trim().isEmpty
                                ? null
                                : comment.text.trim());
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('평가 완료 👏')));
                    }
                  } catch (e, s) {
                    AppLog.e('rate_worker_failed',
                        context: {'assignment_id': assignmentId},
                        error: e,
                        stack: s);
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx)
                          .showSnackBar(SnackBar(content: Text('평가 실패: $e')));
                    }
                  }
                },
                child: const Text('평가 제출'),
              ),
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('나중에')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Column(
          children: [
            Text(value,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(fontSize: 12, color: AppColors.inkSub)),
          ],
        ),
      );
}
