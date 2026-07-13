/// 위치 서비스. M1b는 디바이스/에뮬레이터가 없어 프리셋 좌표로 결정적 테스트.
/// M2에서 geolocator 실 GPS로 [current] 구현을 교체(인터페이스 유지).
library;

class GeoPoint {
  final double lng;
  final double lat;
  const GeoPoint(this.lng, this.lat);
}

class LocationPreset {
  final String label;
  final GeoPoint point;
  final String address;
  const LocationPreset(this.label, this.point, this.address);
}

/// 데모용 프리셋 (강남 기본). 근로자·업주가 같은 지역이면 반경 3km 내 매칭됨.
const kLocationPresets = <LocationPreset>[
  LocationPreset('강남역', GeoPoint(127.0276, 37.4979), '서울 강남구 · 강남역 3번출구'),
  LocationPreset('역삼역', GeoPoint(127.0364, 37.5006), '서울 강남구 · 역삼역'),
  LocationPreset('선릉역', GeoPoint(127.0489, 37.5045), '서울 강남구 · 선릉역'),
  LocationPreset('홍대입구역', GeoPoint(126.9236, 37.5563), '서울 마포구 · 홍대입구역'),
  LocationPreset('판교역', GeoPoint(127.1112, 37.3946), '경기 성남 · 판교역'),
];

/// 현재 위치. M1b: 기본 프리셋(강남역) 반환. M2: 실 GPS.
GeoPoint currentLocation() => kLocationPresets.first.point;
