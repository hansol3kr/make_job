import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/logger.dart';
import '../../core/theme.dart';
import '../../core/supabase_client.dart';
import '../../data/auth.dart';
import '../../data/models.dart';
import '../../data/location_service.dart';
import '../../data/worker_repository.dart';
import '../../data/contract_repository.dart';
import '../../data/safety_repository.dart';
import '../common/safety_widgets.dart';
import '../common/dispute_sheet.dart';

/// 근로자 홈: 가용 토글 → 실시간 오퍼 수신 → 수락/거절 → 체크인/아웃.
class WorkerHomePage extends ConsumerStatefulWidget {
  const WorkerHomePage({super.key});

  @override
  ConsumerState<WorkerHomePage> createState() => _WorkerHomePageState();
}

class _WorkerHomePageState extends ConsumerState<WorkerHomePage> {
  bool _available = false;
  bool _busy = false;
  Timer? _ticker;
  Timer? _locShareTimer; // 근무 중 위치 공유 주기 전송
  String? _sharingAid;

  @override
  void initState() {
    super.initState();
    // 오퍼 카운트다운 갱신용 1초 틱.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _locShareTimer?.cancel();
    super.dispose();
  }

  /// 배정 상태에 따라 위치 공유 시작/중지. checked_in 동안만 15초마다 전송.
  void _syncLocationSharing(Assignment? a) {
    final shouldShare = a != null && a.status == 'checked_in';
    if (shouldShare) {
      if (_sharingAid == a.id && _locShareTimer != null) return; // 이미 공유 중
      _sharingAid = a.id;
      _locShareTimer?.cancel();
      _shareLocationOnce(a.id); // 즉시 1회
      _locShareTimer = Timer.periodic(
          const Duration(seconds: 15), (_) => _shareLocationOnce(a.id));
    } else if (_locShareTimer != null) {
      _locShareTimer!.cancel();
      _locShareTimer = null;
      final prev = _sharingAid;
      _sharingAid = null;
      if (prev != null) {
        ref
            .read(safetyRepositoryProvider)
            .stopLiveLocation(prev)
            .catchError((_) {});
      }
    }
  }

  Future<void> _shareLocationOnce(String aid) async {
    final loc = await currentDeviceLocation();
    if (loc == null || !mounted) return;
    try {
      await ref
          .read(safetyRepositoryProvider)
          .updateLiveLocation(aid, loc.lat, loc.lng);
    } catch (_) {
      // 위치 공유 실패는 조용히 무시(다음 틱에 재시도).
    }
  }

  Future<void> _toggle(bool v) async {
    setState(() {
      _available = v;
      _busy = true;
    });
    try {
      final loc = await currentOrFallback();
      await ref
          .read(workerRepositoryProvider)
          .setAvailability(v, lng: loc.lng, lat: loc.lat);
    } catch (e, s) {
      AppLog.e('availability_toggle_failed',
          context: {'to': v}, error: e, stack: s);
      if (mounted) {
        setState(() => _available = !v); // 실패 시 롤백
        _snack('상태 변경 실패: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept(OfferView o) async {
    setState(() => _busy = true);
    try {
      await ref.read(workerRepositoryProvider).acceptOffer(o.offerId);
      // 배정 스트림이 갱신되며 화면이 확정 뷰로 전환됨.
    } catch (e, s) {
      AppLog.e('offer_accept_failed',
          context: {'offer_id': o.offerId}, error: e, stack: s);
      _snack(_friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decline(OfferView o) async {
    setState(() => _busy = true);
    try {
      await ref.read(workerRepositoryProvider).declineOffer(o.offerId);
    } catch (e, s) {
      AppLog.e('offer_decline_failed',
          context: {'offer_id': o.offerId}, error: e, stack: s);
      _snack(_friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkIn(Assignment a) async {
    setState(() => _busy = true);
    try {
      final loc = await currentOrFallback();
      await ref
          .read(workerRepositoryProvider)
          .checkIn(a.id, loc.lng, loc.lat);
    } catch (e, s) {
      AppLog.e('check_in_failed',
          context: {'assignment_id': a.id}, error: e, stack: s);
      _snack(_checkInErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 체크인 오류를 사용자 친화 메시지로. 근무지 반경 밖이면 거리를 안내.
  String _checkInErrorMessage(Object e) {
    final s = e.toString();
    final m = RegExp(r'too_far_from_site:(\d+)').firstMatch(s);
    if (m != null) {
      return '근무지에서 약 ${m.group(1)}m 떨어져 있어요. 근무지 근처에서 다시 시도해주세요.';
    }
    return '체크인 실패: $e';
  }

  Future<void> _checkOut(Assignment a) async {
    setState(() => _busy = true);
    try {
      await ref.read(workerRepositoryProvider).checkOut(a.id);
      ref.invalidate(myReliabilityProvider);
      if (mounted) await _showRatingSheet(a.id);
    } catch (e, s) {
      AppLog.e('check_out_failed',
          context: {'assignment_id': a.id}, error: e, stack: s);
      _snack('체크아웃 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(Assignment a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('배정 취소'),
        content: const Text(
            '정말 취소할까요? 근무 시작 2시간 이내 취소는 신뢰도에 영향이 있어요.\n빈자리는 자동으로 다른 분에게 백필됩니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('닫기')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('취소하기')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(workerRepositoryProvider).cancelAssignment(a.id);
      ref.invalidate(myReliabilityProvider);
      _snack('배정을 취소했어요. 빈자리는 백필됩니다.');
    } catch (e, s) {
      AppLog.e('assignment_cancel_failed',
          context: {'assignment_id': a.id}, error: e, stack: s);
      _snack('취소 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showRatingSheet(String assignmentId) async {
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
              const Text('오늘 매장은 어땠나요?',
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
                    await ref.read(workerRepositoryProvider).submitRating(
                          assignmentId,
                          stars,
                          comment: comment.text.trim().isEmpty
                              ? null
                              : comment.text.trim(),
                        );
                    if (ctx.mounted) Navigator.pop(ctx);
                    _snack('평가 고마워요! 👏');
                  } catch (e, s) {
                    AppLog.e('rate_employer_failed',
                        context: {'assignment_id': assignmentId},
                        error: e,
                        stack: s);
                    _snack('평가 실패: $e');
                  }
                },
                child: const Text('평가 제출'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('나중에'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('offer_expired')) return '오퍼가 만료됐어요. 다음 기회에!';
    if (s.contains('already_filled')) return '이미 마감된 자리예요.';
    if (s.contains('offer_not_open')) return '이미 처리된 오퍼예요.';
    return '처리 실패: $e';
  }

  @override
  Widget build(BuildContext context) {
    final assignment = ref.watch(myAssignmentProvider).asData?.value;
    // 근무(checked_in) 동안 위치 공유 시작/중지(idempotent, 가드로 중복 방지).
    _syncLocationSharing(assignment);
    final offers = ref.watch(myOffersProvider).asData?.value ?? const [];
    final rel = ref.watch(myReliabilityProvider).asData?.value;
    final verified = rel?['identity_verified'] == true;
    final now = DateTime.now();
    final active =
        offers.where((o) => o.expiresAt.isAfter(now)).toList();
    final offer = active.isEmpty ? null : active.first;

    return Scaffold(
      appBar: AppBar(
        title: const Text('일감 받기'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go('/'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long_rounded),
            tooltip: '내 활동 내역',
            onPressed: () => context.push('/history'),
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
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            if (rel != null && !verified) ...[
              _verifyGate(),
              const SizedBox(height: 12),
            ],
            _availabilityCard(verified),
            if (rel != null) ...[
              const SizedBox(height: 12),
              _reliabilityBar(rel),
            ],
            if (rel != null && verified && rel['professional'] != true) ...[
              const SizedBox(height: 12),
              _proRegisterEntry(),
            ],
            const SizedBox(height: 20),
            Expanded(
              child: assignment != null
                  ? _assignmentView(assignment)
                  : (_available && offer != null
                      ? _offerCard(offer, now)
                      : _waitingView()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _availabilityCard(bool verified) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _available ? AppColors.accent : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: _available ? AppColors.accent : AppColors.line),
      ),
      child: Row(
        children: [
          Icon(_available ? Icons.wifi_tethering_rounded : Icons.pause_rounded,
              color: _available ? Colors.white : AppColors.inkSub),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_available ? '실시간 일감 받는 중' : '지금 쉬는 중',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: _available ? Colors.white : AppColors.ink)),
                Text(_available ? '가까운 매장 오퍼가 오면 알려드려요' : '켜면 실시간 오퍼를 받아요',
                    style: TextStyle(
                        fontSize: 13,
                        color: _available
                            ? Colors.white.withValues(alpha: 0.9)
                            : AppColors.inkSub)),
              ],
            ),
          ),
          Switch(
            value: _available,
            onChanged: (_busy || !verified) ? null : _toggle,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.primaryDark,
          ),
        ],
      ),
    );
  }

  Widget _verifyGate() {
    return InkWell(
      onTap: () => context.push('/verify-identity'),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.warn.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.warn.withValues(alpha: 0.4)),
        ),
        child: Row(children: [
          const Icon(Icons.verified_user_rounded, color: AppColors.warn),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('본인확인이 필요해요',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                Text('완료하면 실시간 일감을 받을 수 있어요',
                    style: TextStyle(fontSize: 13, color: AppColors.inkSub)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.warn),
        ]),
      ),
    );
  }

  Widget _proRegisterEntry() {
    return InkWell(
      onTap: () => context.push('/register-professional'),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          const Icon(Icons.workspace_premium_rounded, color: AppColors.primary),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('전문인력으로 등록하기',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                Text('자격을 인증하면 전문가 요청·높은 단가를 받아요',
                    style: TextStyle(fontSize: 13, color: AppColors.inkSub)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.primary),
        ]),
      ),
    );
  }

  Widget _reliabilityBar(Map<String, dynamic> rel) {
    final score = (rel['reliability'] as num?)?.toDouble() ?? 50.0;
    final tier = (rel['tier'] as String?) ?? 'standard';
    final isPro = rel['professional'] == true;
    final penalties = ((rel['penalties'] as List?) ?? const [])
        .map((e) => PenaltyView.fromMap((e as Map).cast<String, dynamic>()))
        .toList();
    final tierLabel = {
      'top_pro': '탑프로',
      'verified': '인증',
      'standard': '일반'
    }[tier] ?? '일반';
    final tierColor = tier == 'top_pro'
        ? AppColors.primary
        : (tier == 'verified' ? AppColors.accent : AppColors.inkSub);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(children: [
        const Icon(Icons.shield_rounded, size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        Text('신뢰도 ${score.toStringAsFixed(0)}',
            style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: tierColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(tierLabel,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: tierColor)),
        ),
        if (isPro) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.workspace_premium_rounded,
                  size: 13, color: AppColors.primary),
              SizedBox(width: 3),
              Text('전문',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary)),
            ]),
          ),
        ],
        const Spacer(),
        if (penalties.isNotEmpty)
          InkWell(
            onTap: () => _showPenaltySheet(penalties),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 16, color: AppColors.danger),
                const SizedBox(width: 4),
                Text('페널티 ${penalties.length}',
                    style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.danger,
                        fontWeight: FontWeight.w700)),
                const Icon(Icons.chevron_right_rounded,
                    size: 15, color: AppColors.danger),
              ]),
            ),
          ),
      ]),
    );
  }

  static const _penaltyKindLabels = {
    'no_show': '노쇼 (근무 미이행)',
    'late_cancel': '근무 임박 취소',
    'declined': '거절',
  };

  /// 페널티 상세 + 이의신청 진입 시트.
  Future<void> _showPenaltySheet(List<PenaltyView> penalties) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            left: 20,
            right: 20,
            top: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('내 페널티',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            const Text('부당하다고 생각되면 이의신청 할 수 있어요. 담당자가 검토 후 처리합니다.',
                style: TextStyle(fontSize: 13, color: AppColors.inkSub)),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: penalties.length,
                separatorBuilder: (_, _) => const Divider(height: 20),
                itemBuilder: (_, i) => _penaltyRow(ctx, penalties[i]),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _penaltyRow(BuildContext sheetCtx, PenaltyView p) {
    final label = _penaltyKindLabels[p.kind] ?? p.reason ?? p.kind;
    final dateStr = p.at == null
        ? ''
        : '${p.at!.year}.${p.at!.month.toString().padLeft(2, '0')}.${p.at!.day.toString().padLeft(2, '0')}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
              if (dateStr.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(dateStr,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.inkSub)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        _penaltyTrailing(sheetCtx, p),
      ],
    );
  }

  Widget _penaltyTrailing(BuildContext sheetCtx, PenaltyView p) {
    if (p.waived) return _statusChip('면제됨', AppColors.accent);
    if (p.appealStatus == 'requested') {
      return _statusChip('이의신청 접수됨', AppColors.warn);
    }
    if (p.appealStatus != 'none') {
      return _statusChip('검토 완료', AppColors.inkSub);
    }
    if (!p.canAppeal) return const SizedBox.shrink();
    return FilledButton.tonal(
      onPressed: () => _appealPenalty(sheetCtx, p),
      style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 14)),
      child: const Text('이의신청'),
    );
  }

  Widget _statusChip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: color)),
      );

  Future<void> _appealPenalty(BuildContext sheetCtx, PenaltyView p) async {
    final reason = TextEditingController();
    try {
      final submitted = await showDialog<bool>(
        context: sheetCtx,
        builder: (dctx) => AlertDialog(
          title: const Text('이의신청'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('어떤 점이 부당했는지 알려주세요. 담당자가 검토합니다.',
                  style: TextStyle(fontSize: 13, color: AppColors.inkSub)),
              const SizedBox(height: 12),
              TextField(
                controller: reason,
                autofocus: true,
                maxLength: 500,
                maxLines: 3,
                decoration:
                    const InputDecoration(hintText: '예) 당일 병원 진단서가 있어요'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx, false),
                child: const Text('닫기')),
            FilledButton(
                onPressed: () => Navigator.pop(dctx, true),
                child: const Text('제출')),
          ],
        ),
      );
      if (submitted != true) return;
      final text = reason.text.trim();
      if (text.isEmpty) {
        _snack('사유를 입력해주세요');
        return;
      }
      try {
        await ref.read(workerRepositoryProvider).appealPenalty(p.id!, text);
        ref.invalidate(myReliabilityProvider);
        if (sheetCtx.mounted) Navigator.pop(sheetCtx); // 최신 상태로 다시 열도록 시트 닫기
        _snack('이의신청이 접수됐어요. 검토 후 알려드릴게요.');
      } catch (e, s) {
        AppLog.e('penalty_appeal_failed',
            context: {'penalty_id': p.id}, error: e, stack: s);
        _snack('이의신청 실패: ${_appealError(e)}');
      }
    } finally {
      reason.dispose();
    }
  }

  String _appealError(Object e) {
    final s = e.toString();
    if (s.contains('already_appealed')) return '이미 이의신청한 페널티예요';
    if (s.contains('already_waived')) return '이미 면제된 페널티예요';
    if (s.contains('not_your_penalty')) return '본인 페널티만 이의신청할 수 있어요';
    if (s.contains('empty_reason')) return '사유를 입력해주세요';
    return '잠시 후 다시 시도해주세요';
  }

  Widget _waitingView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_available ? '📡' : '☕', style: const TextStyle(fontSize: 56)),
          const SizedBox(height: 16),
          Text(_available ? '오퍼를 기다리는 중...' : '일감을 받으려면 위 스위치를 켜세요',
              style: const TextStyle(fontSize: 16, color: AppColors.inkSub)),
        ],
      ),
    );
  }

  Widget _offerCard(OfferView o, DateTime now) {
    final secs = o.expiresAt.difference(now).inSeconds.clamp(0, 999);
    return SingleChildScrollView(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.primary, width: 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('⏱ ${secs}s',
                      style: const TextStyle(
                          color: AppColors.danger,
                          fontWeight: FontWeight.w800)),
                ),
                const Spacer(),
                Text('₩${formatWon(o.payAmount)}',
                    style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: AppColors.primary)),
                Text(o.payType == 'hourly' ? '  시급' : '  일급',
                    style: const TextStyle(color: AppColors.inkSub)),
              ],
            ),
            const SizedBox(height: 16),
            Text(o.title,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text('${o.address ?? '위치 정보'} · ${timeRangeLabel(o.startAt, o.endAt)}',
                style: const TextStyle(fontSize: 14, color: AppColors.inkSub)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  _reasonRow(Icons.near_me_rounded, '거리',
                      o.distanceM == null ? '-' : '${o.distanceM}m'),
                  const SizedBox(height: 8),
                  _reasonRow(Icons.verified_rounded, '보호',
                      '에스크로 선결제 · 당일 정산'),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _decline(o),
                    child: const Text('지금은 안 함'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _busy ? null : () => _accept(o),
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('수락'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Center(
              child: Text('거절해도 불이익이 없어요. 신뢰도에 영향 없음 👍',
                  style: TextStyle(fontSize: 12, color: AppColors.accent)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _assignmentView(Assignment a) {
    final checkedIn = a.status == 'checked_in';
    final myId = supabase.auth.currentUser?.id ?? '';
    final contract = ref.watch(contractProvider(a.id)).asData?.value;
    final needsSign = contract != null && !contract.workerSigned;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SosBanner(assignmentId: a.id, myUserId: myId),
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
                color: AppColors.accent, shape: BoxShape.circle),
            child: Icon(checkedIn ? Icons.work_rounded : Icons.check_rounded,
                color: Colors.white, size: 40),
          ),
          const SizedBox(height: 20),
          Text(checkedIn ? '근무 중이에요' : '확정됐어요!',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text(
              checkedIn
                  ? '근무를 마치면 체크아웃하세요. 완료 시 신뢰도가 올라가요.'
                  : 'e-근로계약서가 발급됐어요. 근무 시작 시 GPS 체크인하세요.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: AppColors.inkSub)),
          if (checkedIn) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.my_location_rounded,
                    size: 14, color: AppColors.accent),
                const SizedBox(width: 6),
                Text('근무 중 실시간 위치 공유 중',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.accent)),
              ],
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            width: 220,
            child: FilledButton.icon(
              style: checkedIn
                  ? FilledButton.styleFrom(backgroundColor: AppColors.warn)
                  : null,
              onPressed: _busy
                  ? null
                  : () {
                      // 근무 전 계약서 서명 게이트: 미서명이면 계약서로 유도.
                      if (!checkedIn && needsSign) {
                        _snack('먼저 근로계약서에 서명해주세요.');
                        context.push('/contract/${a.id}');
                        return;
                      }
                      checkedIn ? _checkOut(a) : _checkIn(a);
                    },
              icon: Icon(checkedIn
                  ? Icons.logout_rounded
                  : Icons.login_rounded),
              label: Text(checkedIn ? 'GPS 체크아웃' : 'GPS 체크인'),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 260,
            child: OutlinedButton.icon(
              onPressed: () => context.push('/contract/${a.id}'),
              icon: Icon(needsSign
                  ? Icons.draw_rounded
                  : Icons.description_outlined),
              label: Text(needsSign ? '근로계약서 서명하기' : '근로계약서 보기'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 260,
            child: OutlinedButton.icon(
              onPressed: () => context.push('/chat/${a.id}'),
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              label: const Text('채팅으로 소통하기'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(width: 260, child: SosButton(assignmentId: a.id)),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => showDisputeSheet(context, a.id),
            icon: const Icon(Icons.gavel_rounded,
                size: 18, color: AppColors.inkSub),
            label: const Text('문제 신고 / 분쟁',
                style: TextStyle(color: AppColors.inkSub)),
          ),
          if (!checkedIn) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : () => _cancel(a),
              child: const Text('배정 취소',
                  style: TextStyle(color: AppColors.danger)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _reasonRow(IconData icon, String label, String value) => Row(
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
          Text(label,
              style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.inkSub,
                  fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(value,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        ],
      );
}
