/// 업장(매장) 리포지토리 — 사장님의 매장 목록·추가·수정·기본전환·삭제.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/supabase_client.dart';
import 'models.dart';

class StoreRepository {
  Future<List<Store>> myStores() async {
    final res = await supabase.rpc('my_stores');
    return ((res as List?) ?? const [])
        .map((m) => Store.fromMap((m as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<String> addStore({
    required String name,
    required double lat,
    required double lng,
    String? address,
    bool isDefault = false,
  }) async {
    final res = await supabase.rpc('add_store', params: {
      'p_name': name,
      'p_lat': lat,
      'p_lng': lng,
      'p_address': address,
      'p_is_default': isDefault,
    });
    return res as String;
  }

  Future<void> updateStore(String id,
          {String? name, double? lat, double? lng, String? address}) =>
      supabase.rpc('update_store', params: {
        'p_id': id,
        'p_name': name,
        'p_lat': lat,
        'p_lng': lng,
        'p_address': address,
      });

  Future<void> setDefault(String id) =>
      supabase.rpc('set_default_store', params: {'p_id': id});

  Future<void> deleteStore(String id) =>
      supabase.rpc('delete_store', params: {'p_id': id});
}

final storeRepositoryProvider =
    Provider<StoreRepository>((ref) => StoreRepository());

/// 내 매장 목록(요청 생성·매장 관리 공용).
final myStoresProvider = FutureProvider.autoDispose<List<Store>>((ref) {
  return ref.watch(storeRepositoryProvider).myStores();
});
