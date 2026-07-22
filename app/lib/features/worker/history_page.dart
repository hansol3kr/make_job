import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme.dart';
import '../../data/models.dart' show formatWon;
import '../../data/history_repository.dart';

/// 근로자 활동/수익 내역 — 총수익 요약 + 지난 근무 리스트.
class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myActivityProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('내 활동 내역'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('내역을 불러오지 못했어요\n$e',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.danger)),
          ),
        ),
        data: (h) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(myActivityProvider),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _summaryCard(h.summary),
              const SizedBox(height: 20),
              const Text('지난 근무',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              if (h.items.isEmpty)
                _empty()
              else
                for (final it in h.items) ...[
                  _itemTile(it),
                  const SizedBox(height: 10),
                ],
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryCard(ActivitySummary s) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.accent, Color(0xFF0E9F63)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('누적 수익',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9), fontSize: 14)),
          const SizedBox(height: 6),
          Text('₩${formatWon(s.totalEarned)}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 16),
          Row(
            children: [
              _stat('완료', '${s.completedCount}건'),
              _divider(),
              _stat('예정', '${s.upcomingCount}건'),
              _divider(),
              _stat('안 나옴', '${s.noShowCount}건'),
              _divider(),
              _stat('취소', '${s.cancelledCount}건'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85), fontSize: 12)),
          ],
        ),
      );

  Widget _divider() => Container(
      width: 1,
      height: 28,
      color: Colors.white.withValues(alpha: 0.25),
      margin: const EdgeInsets.symmetric(horizontal: 8));

  Widget _itemTile(ActivityItem it) {
    final (label, color) = _statusStyle(it);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(it.title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800)),
              ),
              Text('₩${formatWon(it.payAmount)}',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: it.isCompleted ? AppColors.accent : AppColors.inkSub)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: color)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    '${it.employerName ?? '매장'} · ${_dateLabel(it.workedAt)}',
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 13, color: AppColors.inkSub)),
              ),
              if (it.receivedRating != null) ...[
                const Icon(Icons.star_rounded,
                    size: 15, color: AppColors.warn),
                Text(' ${it.receivedRating}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ],
            ],
          ),
        ],
      ),
    );
  }

  (String, Color) _statusStyle(ActivityItem it) {
    if (it.isCompleted) return ('완료', AppColors.accent);
    if (it.isUpcoming) return ('예정', AppColors.primary);
    if (it.isNoShow) return ('안 나옴', AppColors.danger);
    return ('취소', AppColors.inkSub);
  }

  String _dateLabel(DateTime d) => '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

  Widget _empty() => Container(
        padding: const EdgeInsets.symmetric(vertical: 40),
        alignment: Alignment.center,
        child: const Column(
          children: [
            Text('🗂️', style: TextStyle(fontSize: 44)),
            SizedBox(height: 12),
            Text('아직 근무 내역이 없어요.\n첫 일감을 받아보세요!',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.inkSub)),
          ],
        ),
      );
}
