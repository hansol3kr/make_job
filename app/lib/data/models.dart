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
  final int? proxPct; // reason.prox_pct (근접 기여 %)
  final int? relPct; // reason.rel_pct (신뢰 기여 %)
  final bool isRebook; // reason.rebook — 단골 사장님의 지명 요청
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
    this.proxPct,
    this.relPct,
    this.isRebook = false,
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
      proxPct: (reason['prox_pct'] as num?)?.toInt(),
      relPct: (reason['rel_pct'] as num?)?.toInt(),
      isRebook: reason['rebook'] == true,
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

  /// 왜 이 오퍼가 상위인지 한 줄 설명(설명가능 랭킹). 근거 없으면 null.
  String? get matchReason {
    if (isRebook) return '함께 일했던 사장님의 지명 요청이에요';
    if (proxPct == null || relPct == null) return null;
    return proxPct! >= relPct!
        ? '가까운 거리로 우선 매칭 (근접 $proxPct%)'
        : '높은 신뢰도로 우선 매칭 (신뢰 $relPct%)';
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
  bool get isCompleted => status == 'completed';
  bool get isExpired => status == 'expired';
}

/// 업장(매장) — 사장님이 여러 매장을 두고 매장별로 요청 (stores).
class Store {
  final String id;
  final String name;
  final String? address;
  final bool isDefault;
  const Store({
    required this.id,
    required this.name,
    this.address,
    required this.isDefault,
  });

  factory Store.fromMap(Map<String, dynamic> m) => Store(
        id: m['id'] as String,
        name: (m['name'] as String?) ?? '매장',
        address: m['address'] as String?,
        isDefault: (m['is_default'] as bool?) ?? false,
      );
}

/// 인앱 채팅 메시지 (messages). 확정 배정 당사자 간 소통 + 분쟁 증거.
class Message {
  final String id;
  final String assignmentId;
  final String senderId;
  final String body;
  final DateTime createdAt;
  const Message({
    required this.id,
    required this.assignmentId,
    required this.senderId,
    required this.body,
    required this.createdAt,
  });

  factory Message.fromMap(Map<String, dynamic> m) => Message(
        id: m['id'] as String,
        assignmentId: m['assignment_id'] as String,
        senderId: m['sender_id'] as String,
        body: (m['body'] as String?) ?? '',
        createdAt: DateTime.parse(m['created_at'] as String).toLocal(),
      );
}

/// 실시간 위치 공유 (live_locations). 근무 중 근로자 위치 + 근무지까지 거리.
class LiveLocation {
  final String assignmentId;
  final String sharerId;
  final int? distToSiteM;
  final DateTime updatedAt;
  const LiveLocation({
    required this.assignmentId,
    required this.sharerId,
    required this.distToSiteM,
    required this.updatedAt,
  });

  factory LiveLocation.fromMap(Map<String, dynamic> m) => LiveLocation(
        assignmentId: m['assignment_id'] as String,
        sharerId: m['sharer_id'] as String,
        distToSiteM: (m['dist_to_site_m'] as num?)?.toInt(),
        updatedAt: DateTime.parse(m['updated_at'] as String).toLocal(),
      );

  int get secondsAgo => DateTime.now().difference(updatedAt).inSeconds;
  bool get isStale => secondsAgo > 45; // 45초 이상 미갱신이면 오래된 것
}

/// 원터치 SOS (sos_alerts). 근무 중 긴급 상황 기록·상대 알림.
class SosAlert {
  final String id;
  final String? assignmentId;
  final String reporterId;
  final String status; // open/resolved
  final String? note;
  final DateTime createdAt;
  const SosAlert({
    required this.id,
    required this.assignmentId,
    required this.reporterId,
    required this.status,
    required this.note,
    required this.createdAt,
  });

  factory SosAlert.fromMap(Map<String, dynamic> m) => SosAlert(
        id: m['id'] as String,
        assignmentId: m['assignment_id'] as String?,
        reporterId: m['reporter_id'] as String,
        status: (m['status'] as String?) ?? 'open',
        note: m['note'] as String?,
        createdAt: DateTime.parse(m['created_at'] as String).toLocal(),
      );
}

DateTime? _tsOrNull(dynamic v) =>
    v == null ? null : DateTime.parse(v as String).toLocal();

/// 페널티 (penalties) — 노쇼/임박취소 등으로 부과. 근로자는 이의신청 가능.
/// [id]는 구 백엔드(요약에 id 미노출)와의 호환을 위해 nullable — null이면 이의신청 불가.
class PenaltyView {
  final String? id;
  final String kind; // no_show | late_cancel | ...
  final String? reason; // 시스템이 기록한 부과 사유
  final bool waived; // 면제됨
  final String appealStatus; // none | requested | ... (운영자 처리 후 확장)
  final DateTime? at;
  const PenaltyView({
    required this.id,
    required this.kind,
    required this.reason,
    required this.waived,
    required this.appealStatus,
    required this.at,
  });

  factory PenaltyView.fromMap(Map<String, dynamic> m) => PenaltyView(
        id: m['id'] as String?,
        kind: (m['kind'] as String?) ?? 'penalty',
        reason: m['reason'] as String?,
        waived: m['waived'] == true,
        appealStatus: (m['appeal_status'] as String?) ?? 'none',
        at: _tsOrNull(m['at']),
      );

  /// 이의신청 가능 조건: id를 알고(신 백엔드) · 미면제 · 아직 미신청.
  bool get canAppeal => id != null && !waived && appealStatus == 'none';
}

/// 분쟁 증거 1건 (disputes.evidence 배열의 요소).
class DisputeEvidence {
  final String? by; // 작성자 profile id
  final String? category; // 최초 신고 항목에만 존재
  final String text;
  final DateTime? at;
  const DisputeEvidence({
    required this.by,
    required this.category,
    required this.text,
    required this.at,
  });

  factory DisputeEvidence.fromMap(Map<String, dynamic> m) => DisputeEvidence(
        by: m['by'] as String?,
        category: m['category'] as String?,
        text: (m['text'] as String?) ?? '',
        at: _tsOrNull(m['at']),
      );
}

/// 분쟁 (disputes) — 배정 당사자가 연 문제 제기 + 증거 타임라인.
/// 해소(status/resolution)는 운영자가 처리. 앱은 신고·증거·조회까지.
class DisputeView {
  final String id;
  final String assignmentId;
  final String status; // open | resolved ...
  final String? resolution;
  final DateTime? slaDeadline;
  final DateTime? createdAt;
  final bool iOpened; // 내가 연 분쟁인지
  final List<DisputeEvidence> evidence;
  const DisputeView({
    required this.id,
    required this.assignmentId,
    required this.status,
    required this.resolution,
    required this.slaDeadline,
    required this.createdAt,
    required this.iOpened,
    required this.evidence,
  });

  factory DisputeView.fromMap(Map<String, dynamic> m) => DisputeView(
        id: m['id'] as String,
        assignmentId: m['assignment_id'] as String,
        status: (m['status'] as String?) ?? 'open',
        resolution: m['resolution'] as String?,
        slaDeadline: _tsOrNull(m['sla_deadline']),
        createdAt: _tsOrNull(m['created_at']),
        iOpened: m['i_opened'] == true,
        evidence: ((m['evidence'] as List?) ?? const [])
            .map((e) => DisputeEvidence.fromMap((e as Map).cast<String, dynamic>()))
            .toList(),
      );

  bool get isOpen => status == 'open';
}

/// 전자 근로계약서 (contracts) — 확정 조건 스냅샷(terms) + 양측 서명.
class WorkContract {
  final String id;
  final String assignmentId;
  final Map<String, dynamic> terms;
  final String incomeType; // daily_wage 등
  final DateTime? signedWorkerAt;
  final DateTime? signedEmployerAt;
  final String? workerId;
  final String? employerId;

  const WorkContract({
    required this.id,
    required this.assignmentId,
    required this.terms,
    required this.incomeType,
    required this.signedWorkerAt,
    required this.signedEmployerAt,
    required this.workerId,
    required this.employerId,
  });

  factory WorkContract.fromMap(Map<String, dynamic> m) => WorkContract(
        id: m['id'] as String,
        assignmentId: m['assignment_id'] as String,
        terms: ((m['terms'] as Map?) ?? const {}).cast<String, dynamic>(),
        incomeType: (m['income_type'] as String?) ?? 'daily_wage',
        signedWorkerAt: _tsOrNull(m['signed_worker_at']),
        signedEmployerAt: _tsOrNull(m['signed_employer_at']),
        workerId: m['worker_id'] as String?,
        employerId: m['employer_id'] as String?,
      );

  bool get workerSigned => signedWorkerAt != null;
  bool get employerSigned => signedEmployerAt != null;
  bool get fullySigned => workerSigned && employerSigned;

  String get employerName => (terms['employer_name'] as String?) ?? '요청자';
  String get workerName => (terms['worker_name'] as String?) ?? '근로자';
  String get title => (terms['title'] as String?) ?? '';
  int get payAmount => (terms['pay_amount'] as num?)?.toInt() ?? 0;
  String get payType => (terms['pay_type'] as String?) ?? 'daily';
  String? get address => terms['address'] as String?;
  DateTime? get startAt => _tsOrNull(terms['start_at']);
  DateTime? get endAt => _tsOrNull(terms['end_at']);
  String? get brokerNote => terms['broker_note'] as String?;
  String get incomeTypeLabel =>
      incomeType == 'daily_wage' ? '일용근로소득' : incomeType;
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
