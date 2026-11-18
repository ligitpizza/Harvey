import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hypertension/shared/widgets/care_plan_history.dart';
import 'package:hypertension/shared/models/health_models.dart';
import 'package:hypertension/shared/widgets/structured_text.dart';

// UAT: clinical notes and care plans laid out for reading.

void main() {
  Future<void> pump(WidgetTester t, Widget w) => t.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: w)),
    ),
  );

  testWidgets('headings are bold, empty template lines show a dash', (t) async {
    await pump(
      t,
      const StructuredText('Hypertension follow-up\nHome BP readings: 130s\nAssessment:'),
    );
    expect(find.text('Hypertension follow-up'), findsOneWidget);
    expect(find.textContaining('Home BP readings: 130s', findRichText: true), findsOneWidget);
    expect(find.textContaining('Assessment: —', findRichText: true), findsOneWidget);
  });

  testWidgets('care plan versions: current open, older ones fold to a preview', (t) async {
    await pump(
      t,
      CarePlanHistoryList(
        shrinkWrap: true,
        versions: [
          CarePlanVersion(content: 'Target: below 130/80', savedAt: DateTime(2026, 11, 18, 20, 38)),
          CarePlanVersion(
            content: 'Drink water\nSleep early',
            savedAt: DateTime(2026, 10, 14, 22, 30),
          ),
        ],
      ),
    );
    expect(find.text('Current'), findsOneWidget);
    expect(find.textContaining('Target: below 130/80', findRichText: true), findsOneWidget);
    expect(find.text('Drink water'), findsOneWidget); // the folded preview line
    expect(find.text('Sleep early'), findsNothing);
    await t.tap(find.byKey(const Key('care-plan-version-1')));
    await t.pumpAndSettle();
    expect(find.text('Sleep early'), findsOneWidget);
  });
}
