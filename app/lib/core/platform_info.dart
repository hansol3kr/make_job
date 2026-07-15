// 플랫폼별 OS 정보 진입점.
// 네이티브는 dart:io(platform_info_io), web은 스텁(platform_info_web)으로
// 컴파일 타임에 분기한다. dart:io를 직접 import하면 web 빌드가 깨지므로 이 우회가 필요.
export 'platform_info_io.dart'
    if (dart.library.js_interop) 'platform_info_web.dart';
