import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hypertension/core/constants/enums.dart';
import 'package:hypertension/features/appointments/presentation/pre_visit_summary_page.dart';
import 'package:hypertension/features/appointments/state/appointment_providers.dart';

// D-127: the pre-visit summary names the overall risk and each disease properly.
void main() {
  test('overall level is the highest complication level when not stored', () {
    expect(
      overallRiskLevel({
        'overallLevel': null,
        'scores': {
          'stroke': {'value': 0.04, 'level': 'moderate'},
          'ckd': {'value': 0.226, 'level': 'high'},
        },
      }),
      RiskLevel.high,
    );
    expect(overallRiskLevel({'overallLevel': 'low', 'scores': {}}), RiskLevel.low);
    expect(overallRiskLevel({'scores': {}}), isNull);
  });

  testWidgets('risk shows an overall pill and disease names, never NULL', (t) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          preVisitSummaryProvider('a1').overrideWith(
            (ref) async => {
              'dateTime': DateTime.utc(2026, 11, 25, 3, 30).toIso8601String(),
              'vitals': null,
              'risk': {
                'overallLevel': null,
                'scores': {
                  'stroke': {'value': 0.04, 'level': 'moderate'},
                  'ckd': {'value': 0.226, 'level': 'high'},
                },
              },
              'medications': const [],
              'openItems': const [],
              'dataGaps': const [],
            },
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: PreVisitSummaryView(appointmentId: 'a1')),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('NULL'), findsNothing);
    expect(find.byKey(const Key('summary-overall')), findsOneWidget);
    expect(find.text('High Risk'), findsOneWidget);
    expect(find.text('Stroke'), findsOneWidget);
    expect(find.text('Previous stroke'), findsNothing);
    expect(find.text('Kidney disease'), findsOneWidget);
    expect(find.text('23%'), findsOneWidget);
  });
}
