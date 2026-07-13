/// 위치 서비스 — 실 디바이스 GPS(geolocator).
/// GPS 거부/불가 시 호출부가 지역 선택(regions) 또는 fallback으로 대체.
library;

import 'package:geolocator/geolocator.dart';
import '../core/logger.dart';

class GeoPoint {
  final double lng;
  final double lat;
  const GeoPoint(this.lng, this.lat);
}

/// 서울시청 — GPS도 지역선택도 없을 때 최후 fallback(비상용).
const kFallbackPoint = GeoPoint(126.9780, 37.5665);

/// 실 디바이스 GPS. 위치서비스/권한 확인 포함. 실패·거부 시 null.
Future<GeoPoint?> currentDeviceLocation() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      AppLog.w('gps_service_disabled');
      return null;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      AppLog.w('gps_permission_denied', context: {'perm': perm.name});
      return null;
    }
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    return GeoPoint(pos.longitude, pos.latitude);
  } catch (e, s) {
    AppLog.e('gps_error', error: e, stack: s);
    return null;
  }
}

/// GPS 우선, 실패 시 fallback 좌표. (체크인 등 위치가 반드시 필요한 곳에서 사용)
Future<GeoPoint> currentOrFallback() async =>
    await currentDeviceLocation() ?? kFallbackPoint;
