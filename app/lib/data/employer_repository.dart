/// 업주 리포지토리 — 요청 목록/생성, 매칭 시작, 매칭 현황 실시간.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/supabase_client.dart';
import 'models.dart';

class EmployerRepository {
  String? get _uid => supabase.auth.currentUser?.id;

  /// 내 요청 목록(최신순).
  Future<List<JobRequest>> myRequests() async {
    final uid = _uid;
    if (uid == null) return [];
    final rows = await supabase
        .from('job_requests')
        .select(
            'id, title, category_id, pay_amount, pay_type, headcount, filled_count, status, start_at, end_at, address')
        .eq('employer_id', uid)
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
    });
    return id as String;
  }

  /// 매칭 시작(RPC) → 생성된 오퍼 수.
  Future<int> requestMatching(String requestId) async {
    final n =
        await supabase.rpc('request_matching', params: {'p_request_id': requestId});
    return (n as num).toInt();
  }

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
