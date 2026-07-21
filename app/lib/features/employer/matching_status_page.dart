import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/logger.dart';
import '../../core/theme.dart';
import '../../core/supabase_client.dart';
import '../../data/models.dart';
import '../../data/employer_repository.dart';
import '../common/safety_widgets.dart';
import '../common/dispute_sheet.dart';

/// 실시간 매칭 상태: 매칭중(오퍼 전송) → 확정(배정 근로자 카드).
class MatchingStatusPage extends ConsumerWidget {
  final String requestId;
  const MatchingStatusPage({super.key, required this.requestId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(matchingProvider(requestId));
    final s0 = snap.asData?.value;
    final confirmed = s0?.isConfirmed ?? false;
    final completed = s0?.isCompleted ?? false;
    final expired = s0?.isExpired ?? false;
    final cancelled = s0?.isCancelled ?? false;
    final status = s0?.status;
    final filled = s0?.filledCount ?? 0;
    final canCancel = status != null && !isClosedRequestStatus(status);
    // 확정 근로자가 하나라도 있으면 수정 불가(취소-보상 흐름으로). 서버도 동일 가드.
    final canEdit = (status == 'open' || status == 'matching') && filled == 0;

    // 매칭 진행 중일 때만 연속성 폴링(만료→재웨이브→반경확장→소진).
    Map<String, dynamic>? cont;
    final polling = !confirmed && !completed && !expired && status != 'cancelled';
    if (polling) {
      cont = ref.watch(matchingContinuityProvider(requestId)).asData?.value;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(completed
            ? '근무 완료'
            : cancelled
                ? '요청 취소됨'
                : expired
                    ? '매칭 실패'
                    : confirmed
                        ? '확정 완료'
                        : '실시간 매칭 중'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => context.go('/employer'),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: snap.when(
          loading: () => _matchingView(null, null),
          error: (e, _) => Center(
            child: Text('매칭 현황을 불러오지 못했어요\n$e',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.danger)),
          ),
          data: (s) => s.isCancelled
              ? _cancelledView(context, ref)
              : s.isExpired
                  ? _expiredView(context, ref)
                  : (s.isConfirmed || s.isCompleted) && s.workers.isNotEmpty
                      ? _confirmedView(context, ref, s)
                      : _matchingView(s, cont),
        ),
      ),
      // 요청 수정/취소를 ⋮ 메뉴에 숨기지 않고 하단에 큰 버튼으로 상시 노출
      // (연령친화: 50대도 바로 찾도록). 노출 조건은 기존 ⋮ 와 동일.
      bottomNavigationBar: canCancel
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Row(
                  children: [
                    if (canEdit) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _editRequest(context, ref),
                          icon: const Icon(Icons.edit_rounded),
                          label: const Text('요청 수정'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(54),
                            textStyle: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      // 수수료 경고는 status가 아니라 확정 인원 존재로 판정 —
                      // 부분충원(matching+filled>0)도 서버는 배정 기준 수수료 부과.
                      child: OutlinedButton.icon(
                        onPressed: () => _cancelRequest(
                            context, ref, confirmed || filled > 0),
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('요청 취소'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(54),
                          foregroundColor: AppColors.danger,
                          side: const BorderSide(color: AppColors.danger),
                          textStyle: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }

  /// 취소된 요청 — 매칭이 끝났음을 명확히 알리고 목록 정리(보관)까지 제공.
  /// (기존엔 cancelled 분기가 없어 "매칭 중" 스피너로 오표시됐다.)
  Widget _cancelledView(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        const SizedBox(height: 48),
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppColors.danger.withValues(alpha: 0.10),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.event_busy_rounded,
              size: 40, color: AppColors.danger),
        ),
        const SizedBox(height: 24),
        const Text('취소된 요청이에요',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
        const SizedBox(height: 10),
        const Text('이 요청은 취소돼서 더 이상 매칭이 진행되지 않아요.\n필요 없으면 목록에서 삭제할 수 있어요.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: AppColors.inkSub, height: 1.5)),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: () => _archiveRequest(context, ref),
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('목록에서 삭제'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: () => context.go('/employer'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: const Text('홈으로'),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Future<void> _archiveRequest(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(employerRepositoryProvider).archiveRequest(requestId);
      AppLog.i('request_archived',
          context: {'request_id': requestId, 'from': 'matching_page'});
      ref.invalidate(myRequestsProvider);
      if (context.mounted) context.go('/employer');
    } catch (e, s) {
      AppLog.e('request_archive_failed',
          context: {'request_id': requestId, 'from': 'matching_page'},
          error: e,
          stack: s);
      final msg = e.toString().contains('not_closed')
          ? '진행 중인 요청은 먼저 취소해주세요.'
          : '삭제 실패: $e';
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  /// 매칭 실패(후보 소진) — 정직하게 알리고 다시 찾기/취소 제공. 수수료 0 약속.
  Widget _expiredView(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        const SizedBox(height: 48),
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppColors.inkSub.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.search_off_rounded,
              size: 40, color: AppColors.inkSub),
        ),
        const SizedBox(height: 24),
        const Text('지금은 가능한 분을 못 찾았어요',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
        const SizedBox(height: 10),
        const Text('반경 10km까지 넓혀 찾았지만 응답이 없었어요.\n약속대로 수수료는 0원입니다.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: AppColors.inkSub, height: 1.5)),
        const Spacer(),
        FilledButton.icon(
          onPressed: () async {
            try {
              await ref
                  .read(employerRepositoryProvider)
                  .continueMatching(requestId); // expired + 소유자 → 이력 리셋 후 재탐색
              ref.invalidate(matchingProvider(requestId));
              ref.invalidate(myRequestsProvider);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('다시 찾기 실패: $e')));
              }
            }
          },
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('다시 찾기'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: () => context.go('/employer'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: const Text('홈으로'),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Future<void> _editRequest(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(employerRepositoryProvider);
    JobRequest req;
    try {
      req = await repo.getRequest(requestId);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('요청 조회 실패: $e')));
      }
      return;
    }
    if (!context.mounted) return;
    var pay = req.payAmount;
    var head = req.headcount;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              20, 18, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('요청 수정',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
              const SizedBox(height: 16),
              const Text('급여 (일급, 총액)',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              _editStepper('₩${formatWon(pay)}',
                  () => setSheet(() => pay = (pay - 5000).clamp(0, 2000000)),
                  () => setSheet(() => pay = (pay + 5000).clamp(0, 2000000))),
              const SizedBox(height: 16),
              const Text('인원', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              _editStepper('$head명',
                  () => setSheet(() => head = (head - 1).clamp(1, 20)),
                  () => setSheet(() => head = (head + 1).clamp(1, 20))),
              const SizedBox(height: 12),
              const Text('수정하면 대기 중인 제안을 취소하고 새 조건으로 다시 매칭돼요.',
                  style: TextStyle(fontSize: 12, color: AppColors.inkSub)),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('수정하고 다시 매칭'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved != true) return;
    try {
      await repo.editRequest(requestId, payAmount: pay, headcount: head);
      final offers = await repo.requestMatching(requestId);
      AppLog.i('request_edited',
          context: {'request_id': requestId, 'pay': pay, 'head': head, 'offers': offers});
      ref.invalidate(myRequestsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(offers > 0
                ? '수정하고 새 조건으로 다시 매칭했어요.'
                : '수정했어요. 다만 지금은 조건에 맞는 근로자가 없어요.')));
      }
    } catch (e, s) {
      AppLog.e('request_edit_failed',
          context: {'request_id': requestId}, error: e, stack: s);
      final es = e.toString();
      final msg = es.contains('below_minimum_wage')
          ? '급여가 최저임금에 못 미쳐요. 근무시간 대비 급여를 올려주세요.'
          : es.contains('has_confirmed_workers')
              ? '이미 확정된 근로자가 있어 수정할 수 없어요. 취소 후 다시 요청해주세요.'
              : '수정 실패: $e';
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  Widget _editStepper(String text, VoidCallback onMinus, VoidCallback onPlus) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
                onPressed: onMinus,
                icon: const Icon(Icons.remove_circle_outline_rounded)),
            Text(text,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            IconButton(
                onPressed: onPlus,
                icon: const Icon(Icons.add_circle_outline_rounded)),
          ],
        ),
      );

  /// 재예약 시트 — 날짜(내일/모레/3일 후) 선택, 시간대·급여는 원 요청 그대로.
  Future<void> _rebookSheet(
      BuildContext context, WidgetRef ref, ConfirmedWorker w) async {
    final repo = ref.read(employerRepositoryProvider);
    JobRequest req;
    try {
      req = await repo.getRequest(requestId);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('요청 조회 실패: $e')));
      }
      return;
    }
    if (!context.mounted) return;
    var dayOffset = 1; // 기본: 내일
    final picked = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${w.displayName ?? '근로자'}님 다시 부르기',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              Text(
                  '같은 시간대(${timeRangeLabel(req.startAt, req.endAt)})·같은 급여(₩${formatWon(req.payAmount)})로 지명 요청을 보내요.',
                  style:
                      const TextStyle(fontSize: 13, color: AppColors.inkSub)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                children: [
                  for (final (label, off) in [('내일', 1), ('모레', 2), ('3일 후', 3)])
                    ChoiceChip(
                      label: Text(label),
                      selected: dayOffset == off,
                      onSelected: (_) => setSheet(() => dayOffset = off),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.send_rounded),
                  label: const Text('지명 요청 보내기 (10분간 유효)'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != true) return;
    try {
      // 원 요청의 시각(시간대)을 선택한 날짜에 적용
      final now = DateTime.now();
      final base = DateTime(now.year, now.month, now.day)
          .add(Duration(days: dayOffset));
      final start = base.add(Duration(
          hours: req.startAt.hour, minutes: req.startAt.minute));
      final end = start.add(req.endAt.difference(req.startAt));
      final newId = await repo.rebookWorker(w.assignmentId,
          startAt: start, endAt: end);
      AppLog.i('rebook_sent',
          context: {'assignment_id': w.assignmentId, 'new_request': newId});
      ref.invalidate(myRequestsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('지명 요청을 보냈어요. 10분 안에 응답이 없으면 자동으로 다른 분을 찾아요.')));
        context.go('/employer/matching/$newId');
      }
    } catch (e, s) {
      AppLog.e('rebook_failed',
          context: {'assignment_id': w.assignmentId}, error: e, stack: s);
      final es = e.toString();
      final msg = es.contains('worker_schedule_conflict')
          ? '이 분은 그 시간에 이미 다른 근무가 잡혀 있어요. 다른 날짜를 골라주세요.'
          : es.contains('rebook_pending')
              ? '이미 이 분께 보낸 지명 요청이 진행 중이에요.'
              : es.contains('bad_time_range')
                  ? '시작 시간이 이미 지났어요. 날짜를 다시 선택해주세요.'
                  : '재예약 실패: $e';
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  Future<void> _cancelRequest(
      BuildContext context, WidgetRef ref, bool confirmed) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('요청 취소'),
        content: Text(confirmed
            ? '확정된 근로자가 있어요.\n취소하면 근로자 보상 수수료가 부과돼요(근무 시점에 따라 급여의 0~50%).\n계속할까요?'
            : '요청을 취소할까요?\n대기 중인 제안이 모두 취소됩니다.'),
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
          await ref.read(employerRepositoryProvider).cancelRequest(requestId);
      final fee = (res['fee_total'] as num?)?.toInt() ?? 0;
      AppLog.i('request_cancelled',
          context: {'request_id': requestId, 'fee': fee});
      ref.invalidate(myRequestsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(fee > 0
                ? '요청을 취소했어요. 근로자 보상 수수료 ${formatWon(fee)}원이 부과됐어요.'
                : '요청을 취소했어요.')));
        context.go('/employer');
      }
    } catch (e, s) {
      AppLog.e('request_cancel_failed',
          context: {'request_id': requestId}, error: e, stack: s);
      final msg = e.toString().contains('already_closed')
          ? '이미 종료된 요청이에요.'
          : '취소 실패: $e';
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  Widget _matchingView(MatchingSnapshot? s, Map<String, dynamic>? cont) {
    final offered = s?.offeredCount ?? 0;
    final radiusM = (cont?['radius_m'] as num?)?.toInt();
    final radiusLabel = radiusM != null && radiusM > 3000
        ? '반경 ${(radiusM / 1000).toStringAsFixed(0)}km로 넓혀서 찾는 중'
        : null;
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
          radiusLabel ??
              (offered == 0
                  ? '반경 3km · 인증 완료 · 신뢰도순 정렬'
                  : '$offered명에게 오퍼 전송됨 · 응답 대기(60초)'),
          style: const TextStyle(fontSize: 15, color: AppColors.inkSub),
        ),
        if (radiusLabel != null) ...[
          const SizedBox(height: 6),
          const Text('무응답 시 자동으로 다음 분들에게 넘어가요',
              style: TextStyle(fontSize: 12, color: AppColors.inkSub)),
        ],
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
    final myId = supabase.auth.currentUser?.id ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SosBanner(assignmentId: w.assignmentId, myUserId: myId),
        LiveLocationCard(assignmentId: w.assignmentId, myUserId: myId),
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
                      } else if (v == 'dispute') {
                        showDisputeSheet(context, w.assignmentId);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rate', child: Text('평가하기')),
                      PopupMenuItem(value: 'noshow', child: Text('노쇼 신고')),
                      PopupMenuItem(value: 'dispute', child: Text('문제 신고 / 분쟁')),
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
        if (s.isCompleted) ...[
          FilledButton.icon(
            onPressed: () => _rebookSheet(context, ref, w),
            icon: const Icon(Icons.replay_rounded),
            label: Text('${w.displayName ?? '이 분'} 다시 부르기'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
          const SizedBox(height: 10),
        ],
        OutlinedButton.icon(
          onPressed: () => context.push('/contract/${w.assignmentId}'),
          icon: const Icon(Icons.description_outlined),
          label: const Text('근로계약서 보기·서명'),
          style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: 10),
        SosButton(assignmentId: w.assignmentId),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => context.push('/chat/${w.assignmentId}'),
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                label: const Text('채팅'),
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
