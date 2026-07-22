/// 법적 동의(약관/개인정보/위치) — 정의·텍스트·기록. 공용 models.dart 미편집(병렬 충돌 회피).
/// 실제 출시 전 노무사·변호사 검토 필수. 약관 개정 시 version 올리고 재동의 유도.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/supabase_client.dart';

/// 약관 버전. 개정 시 올리면 기존 사용자도 재동의 대상이 된다.
const kConsentVersion = 'v1';

class ConsentDef {
  final String type;
  final String title;
  final bool required;
  final String text;
  const ConsentDef(this.type, this.title, this.required, this.text);
}

/// 필수 5 + 선택 1. 필수 미동의 시 서비스 이용 불가(0014 required_met).
const List<ConsentDef> kConsents = [
  ConsentDef('tos', '서비스 이용약관', true, '''
지금인력(이하 '회사')은 사업주(요청자)와 근로자를 연결하는 직업소개·통신판매중개 서비스를 제공합니다.

• 회사는 거래 당사자가 아니며, 사용자(사업주)가 아닙니다. 근로계약 체결, 지휘·감독, 임금 지급 의무는 요청자(사업주)에게 있습니다.
• 근로자는 일 제안을 자유롭게 수락·거절할 수 있으며, 거절에 따른 불이익이 없습니다.
• 회사는 통신판매중개자로서, 중개 과정에서 발생한 당사자 간 분쟁·손해에 대해 관계법령이 정한 범위를 넘어 책임을 지지 않습니다.
• 서비스 이용료(수수료)는 직업안정법상 유료직업소개 요율 상한 내에서 부과됩니다.
• 회사는 근로자를 파견하거나 공급하지 않으며, 강제 배차·지휘를 하지 않습니다.'''),
  ConsentDef('privacy', '개인정보 수집·이용 동의', true, '''
• 수집 항목: 이름, 휴대전화번호, 프로필 정보, (근로자) 정산 계좌·본인확인 정보, (매칭) 위치정보.
• 수집·이용 목적: 회원관리 및 본인확인, 실시간 매칭, 근로계약·정산, 서비스 개선.
• 보유·이용 기간: 회원 탈퇴 시까지. 단, 전자상거래법·근로기준법 등 관계법령에 따른 거래·근로 기록은 해당 법정 기간 동안 보존합니다.
• 귀하는 동의를 거부할 권리가 있으나, 필수 항목 미동의 시 서비스 이용이 제한됩니다.
• 주민등록번호 등 고유식별정보는 법령 근거 없이 수집하지 않으며, 본인확인은 본인확인기관을 통해 처리하고 원문을 저장하지 않습니다.'''),
  ConsentDef('privacy_3rd', '개인정보 제3자 제공 동의', true, '''
매칭이 성사되면 원활한 근로 제공을 위해 아래 정보가 상대방에게 제공됩니다.

• 근로자 → 사업주: 이름, 연락 수단(안심번호), 신뢰도, 대략적 위치·거리.
• 사업주 → 근로자: 상호, 근무지 위치, 근무 조건.

제공 목적: 근로계약 이행 및 당사자 간 연락.
보유·이용 기간: 거래 완료 및 분쟁 처리 종료 시까지.
미동의 시 매칭 서비스 이용이 제한됩니다.'''),
  ConsentDef('location', '위치기반서비스 이용약관 및 개인위치정보 수집·이용 동의', true, '''
회사는 위치정보의 보호 및 이용 등에 관한 법률에 따라 개인위치정보를 수집·이용합니다.

• 이용 목적: 반경 내 실시간 매칭, 근무지까지의 거리 계산, GPS 기반 체크인.
• 수집 방법: 이용자 단말기의 위치정보(GPS 등).
• 보유·이용 기간: 서비스 제공 목적 달성 시까지. 매칭·정산 기록은 관계법령에 따라 보존됩니다.
• 이용자는 개인위치정보 수집·이용 동의의 전부 또는 일부를 철회할 수 있으며, 철회 시 위치기반 매칭 이용이 제한됩니다.
• 개인위치정보 이용·제공 내역은 위치정보 처리방침 및 통보 기준에 따릅니다.'''),
  ConsentDef('age14', '만 14세 이상입니다', true, '''
본인은 만 14세 이상입니다.

• 만 14세 미만은 개인정보보호법상 법정대리인의 동의가 필요하며, 현재 가입이 제한됩니다.
• 근로는 근로기준법 등 관계법령상 연령 제한(원칙적으로 15세 이상, 13~15세는 취직인허증 필요)이 적용됩니다.'''),
  ConsentDef('marketing', '마케팅 정보 수신 동의 (선택)', false, '''
이벤트·혜택·신규 일감 추천 등 마케팅 정보를 앱 푸시·문자·이메일로 받는 데 동의합니다.
미동의 시에도 서비스 이용에는 제한이 없으며, 언제든 수신을 거부할 수 있습니다.'''),
];

class ConsentRepository {
  /// 여러 동의를 한 번에 기록(감사로그).
  Future<void> record(Map<String, bool> granted) =>
      supabase.rpc('record_consents', params: {
        'p_items': [
          for (final e in granted.entries)
            {'type': e.key, 'granted': e.value, 'version': kConsentVersion}
        ]
      });

  /// 필수 동의 충족 여부.
  Future<bool> requiredMet() async {
    final res = await supabase.rpc('my_consent_status');
    final m = (res as Map).cast<String, dynamic>();
    return m['required_met'] == true;
  }
}

final consentRepositoryProvider =
    Provider<ConsentRepository>((ref) => ConsentRepository());

/// 필수 동의 충족 여부(온보딩 게이트에서 사용).
final consentRequiredMetProvider =
    FutureProvider.autoDispose<bool>((ref) {
  return ref.watch(consentRepositoryProvider).requiredMet();
});
