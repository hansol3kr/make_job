/// Supabase 응답(JSON Map)을 앱 도메인 모델로 파싱. M1b 실데이터 연동.
library;

/// 카테고리 (DB categories 테이블). 이모지는 slug 기준 로컬 매핑(테이블엔 없음).
class AppCategory {
  final String id;
  final String slug;
  final String name;
  const AppCategory({required this.id, required this.slug, required this.name});

  factory AppCategory.fromMap(Map<String, dynamic> m) => AppCategory(
        id: m['id'] as String,
        slug: m['slug'] as String,
        name: m['name'] as String,
      );

  /// slug → 이모지 (표시용). 없으면 기본 아이콘.
  String get emoji => _emoji[slug] ?? '🧰';
  static const _emoji = {
    'store-cafe': '☕',
    'store-cvs': '🏪',
    'store-fnb': '🍽️',
    'store-retail': '🛍️',
    'store-cover': '⚡',
    'store': '🏬',
  };
}

/// 내 프로필 (profiles).
class MyProfile {
  final String id;
  final String role; // worker/employer/both/admin
  final String? displayName;
  final String? phone;
  const MyProfile({
    required this.id,
    required this.role,
    this.displayName,
    this.phone,
  });

  factory MyProfile.fromMap(Map<String, dynamic> m) => MyProfile(
        id: m['id'] as String,
        role: (m['role'] as String?) ?? 'worker',
        displayName: m['display_name'] as String?,
        phone: m['phone'] as String?,
      );
}

/// 온보딩 상태: 역할별 프로필 존재 여부로 홈/온보딩 분기.
class OnboardingStatus {
  final bool hasWorkerProfile;
  final bool hasEmployerProfile;
  const OnboardingStatus({
    required this.hasWorkerProfile,
    required this.hasEmployerProfile,
  });
}

/// 업주 요청 (job_requests) — 목록/상태 표시용.
class JobRequest {
  final String id;
  final String title;
  final String? categoryId;
  final int payAmount;
  final String payType; // daily/hourly
  final int headcount;
  final int filledCount;
  final String status; // open/matching/confirmed/in_progress/...
  final DateTime startAt;
  final DateTime endAt;
  final String? address;

  const JobRequest({
    required this.id,
    required this.title,
    required this.categoryId,
    required this.payAmount,
    required this.payType,
    required this.headcount,
    required this.filledCount,
    required this.status,
    required this.startAt,
    required this.endAt,
    required this.address,
  });

  factory JobRequest.fromMap(Map<String, dynamic> m) => JobRequest(
        id: m['id'] as String,
        title: (m['title'] as String?) ?? '',
        categoryId: m['category_id'] as String?,
        payAmount: (m['pay_amount'] as num?)?.toInt() ?? 0,
        payType: (m['pay_type'] as String?) ?? 'daily',
        headcount: (m['headcount'] as num?)?.toInt() ?? 1,
        filledCount: (m['filled_count'] as num?)?.toInt() ?? 0,
        status: (m['status'] as String?) ?? 'open',
        startAt: DateTime.parse(m['start_at'] as String).toLocal(),
        endAt: DateTime.parse(m['end_at'] as String).toLocal(),
        address: m['address'] as String?,
      );

  bool get isConfirmed =>
      status == 'confirmed' || status == 'in_progress' || status == 'completed';
}

/// 근로자에게 온 오퍼 + 해당 요청 상세 (match_offers ⨝ job_requests).
/// 업주 실명(business_name)은 확정 전 RLS로 비공개 → title/주소만 노출.
class OfferView {
  final String offerId;
  final String requestId;
  final String status; // offered/accepted/...
  final int? rank;
  final int? distanceM; // reason.distance_m
  final num? reliability; // reason.reliability
  final DateTime expiresAt;
  // 요청 상세
  final String title;
  final String? categoryId;
  final int payAmount;
  final String payType;
  final DateTime startAt;
  final DateTime endAt;
  final String? address;

  const OfferView({
    required this.offerId,
    required this.requestId,
    required this.status,
    required this.rank,
    required this.distanceM,
    required this.reliability,
    required this.expiresAt,
    required this.title,
    required this.categoryId,
    required this.payAmount,
    required this.payType,
    required this.startAt,
    required this.endAt,
    required this.address,
  });

  /// offer row + 별도 조회한 request map을 합쳐 생성.
  factory OfferView.from(Map<String, dynamic> offer, Map<String, dynamic> req) {
    final reason = (offer['reason'] as Map?)?.cast<String, dynamic>() ?? const {};
    return OfferView(
      offerId: offer['id'] as String,
      requestId: offer['request_id'] as String,
      status: (offer['status'] as String?) ?? 'offered',
      rank: (offer['rank'] as num?)?.toInt(),
      distanceM: (reason['distance_m'] as num?)?.toInt(),
      reliability: reason['reliability'] as num?,
      expiresAt: DateTime.parse(offer['expires_at'] as String).toLocal(),
      title: (req['title'] as String?) ?? '',
      categoryId: req['category_id'] as String?,
      payAmount: (req['pay_amount'] as num?)?.toInt() ?? 0,
      payType: (req['pay_type'] as String?) ?? 'daily',
      startAt: DateTime.parse(req['start_at'] as String).toLocal(),
      endAt: DateTime.parse(req['end_at'] as String).toLocal(),
      address: req['address'] as String?,
    );
  }
}

/// 배정 (assignments) — 근로자 확정/체크인/아웃 상태.
class Assignment {
  final String id;
  final String requestId;
  final String workerId;
  final String status; // confirmed/checked_in/completed/...
  final DateTime? checkInAt;
  final DateTime? checkOutAt;

  const Assignment({
    required this.id,
    required this.requestId,
    required this.workerId,
    required this.status,
    required this.checkInAt,
    required this.checkOutAt,
  });

  factory Assignment.fromMap(Map<String, dynamic> m) => Assignment(
        id: m['id'] as String,
        requestId: m['request_id'] as String,
        workerId: m['worker_id'] as String,
        status: (m['status'] as String?) ?? 'confirmed',
        checkInAt: m['check_in_at'] == null
            ? null
            : DateTime.parse(m['check_in_at'] as String).toLocal(),
        checkOutAt: m['check_out_at'] == null
            ? null
            : DateTime.parse(m['check_out_at'] as String).toLocal(),
      );
}

/// 확정된 근로자(업주에게 제한 노출) — matching_snapshot.workers[].
class ConfirmedWorker {
  final String assignmentId;
  final String status;
  final String? displayName;
  final num? reliability;
  final int? distanceM;
  const ConfirmedWorker({
    required this.assignmentId,
    required this.status,
    required this.displayName,
    required this.reliability,
    required this.distanceM,
  });

  factory ConfirmedWorker.fromMap(Map<String, dynamic> m) => ConfirmedWorker(
        assignmentId: m['assignment_id'] as String,
        status: (m['status'] as String?) ?? 'confirmed',
        displayName: m['display_name'] as String?,
        reliability: m['reliability'] as num?,
        distanceM: (m['dist_m'] as num?)?.toInt(),
      );
}

/// 업주 매칭 화면 스냅샷 — matching_snapshot RPC 결과.
class MatchingSnapshot {
  final String status; // open/matching/confirmed/...
  final int headcount;
  final int filledCount;
  final int offeredCount;
  final List<ConfirmedWorker> workers;
  const MatchingSnapshot({
    required this.status,
    required this.headcount,
    required this.filledCount,
    required this.offeredCount,
    required this.workers,
  });

  factory MatchingSnapshot.fromMap(Map<String, dynamic> m) => MatchingSnapshot(
        status: (m['status'] as String?) ?? 'open',
        headcount: (m['headcount'] as num?)?.toInt() ?? 1,
        filledCount: (m['filled_count'] as num?)?.toInt() ?? 0,
        offeredCount: (m['offered_count'] as num?)?.toInt() ?? 0,
        workers: ((m['workers'] as List?) ?? const [])
            .map((e) => ConfirmedWorker.fromMap(e as Map<String, dynamic>))
            .toList(),
      );

  bool get isConfirmed => status == 'confirmed' || status == 'in_progress';
}

/// 금액 콤마 포맷 (₩ 제외).
String formatWon(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// "오늘 14:00 ~ 20:00 (6시간)" 형태 라벨.
String timeRangeLabel(DateTime start, DateTime end) {
  String hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  final now = DateTime.now();
  final sameDay =
      start.year == now.year && start.month == now.month && start.day == now.day;
  final dayLabel = sameDay ? '오늘' : '${start.month}/${start.day}';
  final hours = end.difference(start).inMinutes / 60.0;
  final hoursLabel =
      hours == hours.roundToDouble() ? '${hours.toInt()}시간' : '${hours.toStringAsFixed(1)}시간';
  return '$dayLabel ${hhmm(start)} ~ ${hhmm(end)} ($hoursLabel)';
}
