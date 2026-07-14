/// 근로자 활동/수익 내역 — my_activity_history RPC 래핑.
/// 모델을 이 파일에 두어 공용 models.dart와 독립(병렬 작업 충돌 회피).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/supabase_client.dart';

/// 활동 요약(상단 카드용).
class ActivitySummary {
  final int completedCount;
  final int totalEarned;
  final int noShowCount;
  final int cancelledCount;
  final int upcomingCount;
  const ActivitySummary({
    required this.completedCount,
    required this.totalEarned,
    required this.noShowCount,
    required this.cancelledCount,
    required this.upcomingCount,
  });

  factory ActivitySummary.fromMap(Map<String, dynamic> m) => ActivitySummary(
        completedCount: (m['completed_count'] as num?)?.toInt() ?? 0,
        totalEarned: (m['total_earned'] as num?)?.toInt() ?? 0,
        noShowCount: (m['no_show_count'] as num?)?.toInt() ?? 0,
        cancelledCount: (m['cancelled_count'] as num?)?.toInt() ?? 0,
        upcomingCount: (m['upcoming_count'] as num?)?.toInt() ?? 0,
      );
}

/// 활동 항목(지난 근무 1건).
class ActivityItem {
  final String assignmentId;
  final String title;
  final int payAmount;
  final String payType;
  final String status; // completed/no_show/cancelled_*/confirmed/checked_in
  final DateTime workedAt;
  final String? employerName;
  final int? myRating; // 내가 준 별점
  final int? receivedRating; // 받은 별점(공개된 것만)

  const ActivityItem({
    required this.assignmentId,
    required this.title,
    required this.payAmount,
    required this.payType,
    required this.status,
    required this.workedAt,
    required this.employerName,
    required this.myRating,
    required this.receivedRating,
  });

  factory ActivityItem.fromMap(Map<String, dynamic> m) => ActivityItem(
        assignmentId: m['assignment_id'] as String,
        title: (m['title'] as String?) ?? '',
        payAmount: (m['pay_amount'] as num?)?.toInt() ?? 0,
        payType: (m['pay_type'] as String?) ?? 'daily',
        status: (m['status'] as String?) ?? 'completed',
        workedAt: DateTime.parse(m['worked_at'] as String).toLocal(),
        employerName: m['employer_name'] as String?,
        myRating: (m['my_rating'] as num?)?.toInt(),
        receivedRating: (m['received_rating'] as num?)?.toInt(),
      );

  bool get isCompleted => status == 'completed';
  bool get isNoShow => status == 'no_show';
  bool get isCancelled =>
      status == 'cancelled_worker' || status == 'cancelled_employer';
  bool get isUpcoming => status == 'confirmed' || status == 'checked_in';
}

class ActivityHistory {
  final ActivitySummary summary;
  final List<ActivityItem> items;
  const ActivityHistory({required this.summary, required this.items});
}

class HistoryRepository {
  Future<ActivityHistory> myActivity() async {
    final res = await supabase.rpc('my_activity_history');
    final m = (res as Map).cast<String, dynamic>();
    return ActivityHistory(
      summary: ActivitySummary.fromMap(
          (m['summary'] as Map).cast<String, dynamic>()),
      items: ((m['items'] as List?) ?? const [])
          .map((e) => ActivityItem.fromMap((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }
}

final historyRepositoryProvider =
    Provider<HistoryRepository>((ref) => HistoryRepository());

/// 근로자 활동 내역(자동 갱신). 화면 진입/새로고침 시 재조회.
final myActivityProvider = FutureProvider.autoDispose<ActivityHistory>((ref) {
  return ref.watch(historyRepositoryProvider).myActivity();
});
