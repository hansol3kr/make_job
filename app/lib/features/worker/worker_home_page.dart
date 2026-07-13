import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../data/auth.dart';
import '../../data/models.dart';
import '../../data/location_service.dart';
import '../../data/worker_repository.dart';

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
    super.dispose();
  }

  Future<void> _toggle(bool v) async {
    setState(() {
      _available = v;
      _busy = true;
    });
    try {
      final loc = currentLocation();
      await ref
          .read(workerRepositoryProvider)
          .setAvailability(v, lng: loc.lng, lat: loc.lat);
    } catch (e) {
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
    } catch (e) {
      _snack(_friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decline(OfferView o) async {
    setState(() => _busy = true);
    try {
      await ref.read(workerRepositoryProvider).declineOffer(o.offerId);
    } catch (e) {
      _snack(_friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkIn(Assignment a) async {
    setState(() => _busy = true);
    try {
      final loc = currentLocation();
      await ref
          .read(workerRepositoryProvider)
          .checkIn(a.id, loc.lng, loc.lat);
    } catch (e) {
      _snack('체크인 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkOut(Assignment a) async {
    setState(() => _busy = true);
    try {
      await ref.read(workerRepositoryProvider).checkOut(a.id);
      _snack('근무 완료! 수고하셨어요 👏');
    } catch (e) {
      _snack('체크아웃 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
    final offers = ref.watch(myOffersProvider).asData?.value ?? const [];
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
            _availabilityCard(),
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

  Widget _availabilityCard() {
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
            onChanged: _busy ? null : _toggle,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.primaryDark,
          ),
        ],
      ),
    );
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
          const SizedBox(height: 24),
          SizedBox(
            width: 220,
            child: FilledButton.icon(
              style: checkedIn
                  ? FilledButton.styleFrom(backgroundColor: AppColors.warn)
                  : null,
              onPressed: _busy
                  ? null
                  : () => checkedIn ? _checkOut(a) : _checkIn(a),
              icon: Icon(checkedIn
                  ? Icons.logout_rounded
                  : Icons.login_rounded),
              label: Text(checkedIn ? 'GPS 체크아웃' : 'GPS 체크인'),
            ),
          ),
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
