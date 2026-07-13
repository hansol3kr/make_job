import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/supabase_client.dart';

/// 전국 지역(시/도 → 시/군/구) 레퍼런스 항목.
class Region {
  final String sido;
  final String sigungu;
  final double lat;
  final double lng;
  const Region(this.sido, this.sigungu, this.lat, this.lng);

  String get label => '$sido $sigungu';
}

class RegionRepository {
  /// 전국 지역 전체 로드(약 250행 — 1회 로드 후 메모리 그룹핑).
  Future<List<Region>> all() async {
    final rows = await supabase
        .from('regions')
        .select('sido, sigungu, lat, lng')
        .order('id');
    return rows
        .map((r) => Region(
              r['sido'] as String,
              r['sigungu'] as String,
              (r['lat'] as num).toDouble(),
              (r['lng'] as num).toDouble(),
            ))
        .toList();
  }
}

/// 전국 지역 목록(캐시). 온보딩 지역 선택 + GPS 최근접 라벨에 사용.
final regionsProvider =
    FutureProvider<List<Region>>((ref) => RegionRepository().all());

/// 좌표에서 가장 가까운 지역(표시 라벨용). 짧은 거리엔 위경도 제곱합으로 충분.
Region? nearestRegion(List<Region> regions, double lat, double lng) {
  Region? best;
  double bestD = double.infinity;
  for (final r in regions) {
    final dLat = r.lat - lat;
    final dLng = r.lng - lng;
    final d = dLat * dLat + dLng * dLng;
    if (d < bestD) {
      bestD = d;
      best = r;
    }
  }
  return best;
}

/// 시/도 목록(등장 순서 유지, 중복 제거).
List<String> sidoList(List<Region> regions) {
  final seen = <String>{};
  final out = <String>[];
  for (final r in regions) {
    if (seen.add(r.sido)) out.add(r.sido);
  }
  return out;
}

/// 특정 시/도의 시/군/구 목록.
List<Region> sigunguOf(List<Region> regions, String sido) =>
    regions.where((r) => r.sido == sido).toList();
