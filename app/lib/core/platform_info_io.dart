import 'dart:io' show Platform;

/// 네이티브(모바일·데스크톱)용 플랫폼 정보.
/// web 빌드에서는 컴파일 타임에 [platform_info_web.dart]로 대체된다.
String platformOs() => Platform.operatingSystem;

String platformDevice() =>
    '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
