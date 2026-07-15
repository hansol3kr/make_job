/// web용 플랫폼 정보 스텁. dart:io가 없는 web 빌드에서 사용된다.
/// device/platform 컬럼은 'web'으로 남아 안드로이드 로그와 구분된다.
String platformOs() => 'web';

String platformDevice() => 'web';
