/// 전자 근로계약서 리포지토리 — 확정 배정의 계약 조회(없으면 생성)·서명.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/supabase_client.dart';
import 'models.dart';

class ContractRepository {
  /// 계약 조회(없으면 확정 조건으로 생성). 당사자만 호출 가능.
  Future<WorkContract> getOrCreate(String assignmentId) async {
    final res = await supabase
        .rpc('get_or_create_contract', params: {'p_assignment': assignmentId});
    return WorkContract.fromMap((res as Map).cast<String, dynamic>());
  }

  /// 내 역할 측 서명(근로자/업주는 서버가 판별).
  Future<WorkContract> sign(String assignmentId) async {
    final res =
        await supabase.rpc('sign_contract', params: {'p_assignment': assignmentId});
    return WorkContract.fromMap((res as Map).cast<String, dynamic>());
  }
}

final contractRepositoryProvider =
    Provider<ContractRepository>((ref) => ContractRepository());

/// 배정별 계약(최초 조회 시 생성). 서명 후 invalidate로 갱신.
final contractProvider =
    FutureProvider.autoDispose.family<WorkContract, String>((ref, assignmentId) {
  return ref.watch(contractRepositoryProvider).getOrCreate(assignmentId);
});
