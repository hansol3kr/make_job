/// 프로필/온보딩 리포지토리 — role 확정, 근로자/업주 프로필 생성.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/supabase_client.dart';
import 'models.dart';

class ProfileRepository {
  /// 내 프로필(profiles). 세션 없으면 null.
  Future<MyProfile?> myProfile() async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) return null;
    final row = await supabase
        .from('profiles')
        .select('id, role, display_name, phone')
        .eq('id', uid)
        .maybeSingle();
    return row == null ? null : MyProfile.fromMap(row);
  }

  /// 온보딩 상태: worker/employer 프로필 존재 여부.
  Future<OnboardingStatus> onboardingStatus() async {
    final uid = supabase.auth.currentUser?.id;
    if (uid == null) {
      return const OnboardingStatus(
          hasWorkerProfile: false, hasEmployerProfile: false);
    }
    final w = await supabase
        .from('worker_profiles')
        .select('profile_id')
        .eq('profile_id', uid)
        .maybeSingle();
    final e = await supabase
        .from('employer_profiles')
        .select('profile_id')
        .eq('profile_id', uid)
        .maybeSingle();
    return OnboardingStatus(
      hasWorkerProfile: w != null,
      hasEmployerProfile: e != null,
    );
  }

  /// 근로자 온보딩 완료(RPC). 위치는 프리셋 좌표.
  Future<void> completeWorkerOnboarding({
    required String displayName,
    required double lng,
    required double lat,
  }) =>
      supabase.rpc('complete_worker_onboarding', params: {
        'p_display_name': displayName,
        'p_lng': lng,
        'p_lat': lat,
      });

  /// 업주 온보딩 완료(RPC).
  Future<void> completeEmployerOnboarding({
    required String businessName,
    required double lng,
    required double lat,
    String? address,
  }) =>
      supabase.rpc('complete_employer_onboarding', params: {
        'p_business_name': businessName,
        'p_lng': lng,
        'p_lat': lat,
        'p_address': address,
      });
}

final profileRepositoryProvider =
    Provider<ProfileRepository>((ref) => ProfileRepository());

/// 내 프로필(표시용).
final myProfileProvider = FutureProvider.autoDispose<MyProfile?>((ref) {
  return ref.watch(profileRepositoryProvider).myProfile();
});

/// 매장(store-*) 카테고리 로드.
final storeCategoriesProvider = FutureProvider<List<AppCategory>>((ref) async {
  final rows = await supabase
      .from('categories')
      .select('id, slug, name')
      .like('slug', 'store-%')
      .eq('is_active', true)
      .order('sort');
  return (rows as List)
      .map((e) => AppCategory.fromMap(e as Map<String, dynamic>))
      .toList();
});
