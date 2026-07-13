import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigeum/features/landing/landing_page.dart';

void main() {
  testWidgets('랜딩: 역할 선택 카드가 보인다', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LandingPage()));

    expect(find.text('지금인력'), findsOneWidget);
    expect(find.text('사장님이에요'), findsOneWidget);
    expect(find.text('일하고 싶어요'), findsOneWidget);
  });
}
