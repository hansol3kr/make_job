/// 업주 리포지토리 — 요청 목록/생성, 매칭 시작, 매칭 현황 실시간.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/supabase_client.dart';
import 'models.dart';

class EmployerRepository {
  String? get _uid => supabase.auth.currentUser?.id;

  /// 내 요청 목록(최신순, 보관된 요청 제외).
  /// 진행 중 상태는 보관 여부와 무관하게 항상 표시 — 보관된 expired 요청이
  /// '다시 찾기'로 재활성화돼도 목록에서 안 보이는 구멍을 막는다.
  Future<List<JobRequest>> myRequests() async {
    final uid = _uid;
    if (uid == null) return [];
    final rows = await supabase
        .from('job_requests')
        .select(
            'id, title, category_id, pay_amount, pay_type, headcount, filled_count, status, start_at, end_at, address')
        .eq('employer_id', uid)
        .or('archived_at.is.null,status.in.(open,matching,confirmed,in_progress)')
        .order('created_at', ascending: false);
    return (rows as List)
        .map((e) => JobRequest.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  /// 요청 생성(RPC) → request_id. 위치는 미지정 시 업주 기본 위치.
  Future<String> createRequest({
    required String title,
    required DateTime startAt,
    required DateTime endAt,
    required int payAmount,
    int headcount = 1,
    String? categoryId,
    double? lng,
    double? lat,
    String? address,
    String payType = 'daily',
    bool requiresProfessional = false,
    String? storeId,
  }) async {
    final id = await supabase.rpc('create_job_request', params: {
      'p_title': title,
      'p_start_at': startAt.toUtc().toIso8601String(),
      'p_end_at': endAt.toUtc().toIso8601String(),
      'p_pay_amount': payAmount,
      'p_headcount': headcount,
      'p_category_id': categoryId,
      'p_lng': lng,
      'p_lat': lat,
      'p_address': address,
      'p_pay_type': payType,
      'p_require_professional': requiresProfessional, // RPC 파라미터명과 일치(과거 오타 수정)
      'p_store_id': storeId,
    });
    return id as String;
  }

  /// 매칭 시작(RPC) → 생성된 오퍼 수.
  Future<int> requestMatching(String requestId) async {
    final n =
        await supabase.rpc('request_matching', params: {'p_request_id': requestId});
    return (n as num).toInt();
  }

  /// 요청 취소. matching 중이면 무료, 확정 근로자 있으면 보상 수수료.
  /// 반환: {cancelled, confirmed_cancelled, fee_pct, fee_total}
  Future<Map<String, dynamic>> cancelRequest(String requestId) async {
    final res = await supabase
        .rpc('cancel_job_request', params: {'p_request_id': requestId});
    return (res as Map).cast<String, dynamic>();
  }

  /// 종료된 요청을 목록에서 숨김(보관, soft-delete). 기록은 서버에 보존.
  Future<void> archiveRequest(String requestId) =>
      supabase.rpc('archive_job_request', params: {'p_request_id': requestId});

  /// 매칭 전진: 만료 오퍼 정리 → 다음 웨이브(반경 확장) → 소진 시 expired.
  /// expired 요청에 소유자가 호출하면 '다시 찾기'(이력 리셋 후 재탐색).
  /// 반환: {state: waiting|rewaved|searching|exhausted|noop, radius_m?, live_offers?...}
  Future<Map<String, dynamic>> continueMatching(String requestId) async {
    final res = await supabase
        .rpc('continue_matching', params: {'p_request_id': requestId});
    return (res as Map).cast<String, dynamic>();
  }

  /// 재예약 — 완료된 배정의 근로자에게 지명 오퍼(TTL 10분). 새 요청 id 반환.
  Future<String> rebookWorker(
    String assignmentId, {
    required DateTime startAt,
    required DateTime endAt,
    int? payAmount,
  }) async {
    final res = await supabase.rpc('rebook_worker', params: {
      'p_assignment_id': assignmentId,
      'p_start_at': startAt.toUtc().toIso8601String(),
      'p_end_at': endAt.toUtc().toIso8601String(),
      'p_pay_amount': payAmount,
    });
    return res as String;
  }

  /// 요청 1건 조회(수정 화면 프리필용).
  Future<JobRequest> getRequest(String requestId) async {
    final rows = await supabase
        .from('job_requests')
        .select(
            'id, title, category_id, pay_amount, pay_type, headcount, filled_count, status, start_at, end_at, address')
        .eq('id', requestId)
        .limit(1);
    return JobRequest.fromMap((rows as List).first as Map<String, dynamic>);
  }

  /// 요청 수정(open/matching만). 수정 후 옛 오퍼 취소·open 복귀 → requestMatching으로 재매칭.
  Future<void> editRequest(
    String requestId, {
    String? title,
    DateTime? startAt,
    DateTime? endAt,
    int? payAmount,
    int? headcount,
    String? payType,
    bool? requiresProfessional,
  }) =>
      supabase.rpc('edit_job_request', params: {
        'p_request_id': requestId,
        'p_title': title,
        'p_start_at': startAt?.toUtc().toIso8601String(),
        'p_end_at': endAt?.toUtc().toIso8601String(),
        'p_pay_amount': payAmount,
        'p_headcount': headcount,
        'p_pay_type': payType,
        'p_require_professional': requiresProfessional,
      });

  /// 매칭 현황 스냅샷 1회 조회.
  Future<MatchingSnapshot> matchingSnapshot(String requestId) async {
    final res = await supabase
        .rpc('matching_snapshot', params: {'p_request_id': requestId});
    return MatchingSnapshot.fromMap((res as Map).cast<String, dynamic>());
  }

  /// 매칭 현황 실시간: 요청 row 변경(상태/충원)마다 스냅샷 재조회.
  Stream<MatchingSnapshot> watchMatching(String requestId) {
    final reqStream = supabase
        .from('job_requests')
        .stream(primaryKey: ['id']).eq('id', requestId);
    return reqStream.asyncMap((_) => matchingSnapshot(requestId));
  }

  /// 노쇼 신고 → 신뢰도 패널티 + 자동 백필(재매칭). 생성된 백필 오퍼 수 반환.
  Future<int> reportNoShow(String assignmentId) async {
    final n = await supabase
        .rpc('report_no_show', params: {'p_assignment_id': assignmentId});
    return (n as num).toInt();
  }

  /// 근로자 평점 제출(더블블라인드).
  Future<void> submitRating(String assignmentId, int stars,
          {Map<String, dynamic>? subScores, String? comment}) =>
      supabase.rpc('submit_rating', params: {
        'p_assignment_id': assignmentId,
        'p_stars': stars,
        'p_sub_scores': subScores,
        'p_comment': comment,
      });
}

final employerRepositoryProvider =
    Provider<EmployerRepository>((ref) => EmployerRepository());

/// 내 요청 목록.
final myRequestsProvider = FutureProvider.autoDispose<List<JobRequest>>((ref) {
  return ref.watch(employerRepositoryProvider).myRequests();
});

/// 특정 요청의 매칭 현황(실시간).
final matchingProvider = StreamProvider.autoDispose
    .family<MatchingSnapshot, String>((ref, requestId) {
  return ref.watch(employerRepositoryProvider).watchMatching(requestId);
});

/// 매칭 연속성 폴링 — 매칭 화면이 떠 있는 동안 15초마다 continue_matching.
/// (만료 오퍼 정리 → 다음 웨이브 + 반경 확장 → 소진 시 expired. autoDispose로
/// 화면 이탈 시 자동 중단. 백그라운드는 서버 pg_cron sweep이 보조.)
final matchingContinuityProvider = StreamProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, requestId) async* {
  final repo = ref.watch(employerRepositoryProvider);
  while (true) {
    try {
      yield await repo.continueMatching(requestId);
    } catch (_) {
      // 일시 실패는 다음 틱에 재시도.
    }
    await Future.delayed(const Duration(seconds: 15));
  }
});
