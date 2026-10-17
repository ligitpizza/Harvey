import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hypertension/features/admin/data/admin_repository.dart';
import 'package:hypertension/features/admin/presentation/custom_charts.dart';
import 'package:hypertension/features/admin/presentation/system_health_page.dart';
import 'package:hypertension/features/admin/state/admin_providers.dart';
import 'package:hypertension/shared/providers/api_providers.dart';
import 'package:hypertension/shared/widgets/import_dialog.dart';

import '../helpers/admin_fakes.dart';
import '../helpers/fakes.dart';

// D-79: imports, custom charts and System health actions.

class D79Api extends FakeApiClient {
  final calls = <String>[];
  List<Map<String, dynamic>> charts = [];

  @override
  Future<Map<String, dynamic>> importUsers(String format, String content, bool commit) async {
    calls.add('users:$format:$commit');
    final rows = [
      {'row': 1, 'name': 'Dr Aisha', 'email': 'aisha@x.my', 'role': 'doctor', 'error': null},
      {'row': 2, 'name': 'Bad', 'email': 'nope', 'role': 'admin', 'error': 'email: invalid'},
    ];
    return commit
        ? {'rows': rows, 'valid': 1, 'invalid': 1, 'committed': true, 'created': 1}
        : {'rows': rows, 'valid': 1, 'invalid': 1, 'committed': false};
  }

  @override
  Future<Map<String, dynamic>> chartMeasures() async => {
    'measures': [
      {
        'key': 'readings_per_day',
        'label': 'BP readings logged per day',
        'kind': 'time',
        'page': 'hospital',
      },
      {
        'key': 'alerts_by_severity',
        'label': 'Clinical alerts by severity',
        'kind': 'category',
        'page': 'hospital',
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> myCharts() async => {'charts': charts};

  @override
  Future<Map<String, dynamic>> saveCharts(List<Map<String, dynamic>> c) async {
    calls.add('save:${c.length}');
    charts = c;
    return {'charts': c};
  }

  @override
  Future<Map<String, dynamic>> chartSeries(String measure, int days) async => {
    'kind': 'category',
    'labels': ['low', 'high'],
    'series': {
      'Count': [2, 3],
    },
  };

  @override
  Future<Map<String, dynamic>> testService(String key) async {
    calls.add('test:$key');
    return {'ok': true, 'message': 'Gemini answered: OK', 'latencyMs': 120};
  }

  @override
  Future<Map<String, dynamic>> serviceErrors(String key) async => {
    'errors': [
      {'at': '2026-10-18T02:00:00Z', 'message': 'Gemini timed out'},
    ],
  };
}

late D79Api api;

Future<void> wide(WidgetTester t) async {
  t.view.physicalSize = const Size(1400, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() => api = D79Api());

  testWidgets('import: preview shows good and bad rows, then imports the good ones', (t) async {
    await wide(t);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          importFilePickerProvider.overrideWithValue(
            () async => ('staff.csv', Uint8List.fromList(utf8.encode('name,email,role\n'))),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ImportDialog(kind: ImportKind.users)),
        ),
      ),
    );
    await t.tap(find.byKey(const Key('import-choose')));
    await t.pumpAndSettle();
    expect(api.calls, ['users:csv:false']);
    expect(find.textContaining('1 row(s) ready'), findsOneWidget);
    expect(find.text('email: invalid'), findsOneWidget);
    await t.tap(find.byKey(const Key('import-commit')));
    await t.pumpAndSettle();
    expect(api.calls.last, 'users:csv:true');
    expect(find.text('Created 1 account(s).'), findsOneWidget);
  });

  testWidgets('custom charts: add a chart and it is drawn', (t) async {
    await wide(t);
    await t.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(api)],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: CustomChartsSection(page: 'hospital')),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const Key('no-custom-charts')), findsOneWidget);
    await t.tap(find.byKey(const Key('add-chart')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('chart-measure')));
    await t.pumpAndSettle();
    await t.tap(find.text('Clinical alerts by severity').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Donut'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('chart-save')));
    await t.pumpAndSettle();
    expect(api.calls, contains('save:1'));
    expect(api.charts.single['type'], 'donut');
    expect(find.text('Clinical alerts by severity'), findsOneWidget);
    expect(find.textContaining('Donut · last 30 days'), findsOneWidget);
  });

  testWidgets('system health: test a service and read its recent errors', (t) async {
    await wide(t);
    final repo = FakeAdminRepository()
      ..health = SystemHealth(
        overall: 'operational',
        checkedAt: DateTime.utc(2026, 10, 18, 2),
        services: const [
          ServiceHealth(key: 'ai', name: 'AI Health Agent', status: 'operational', note: 'Gemini'),
        ],
      );
    final opened = <String>[];
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          adminRepositoryProvider.overrideWithValue(repo),
          apiClientProvider.overrideWithValue(api),
          urlOpenerProvider.overrideWithValue((url) async {
            opened.add(url);
            return true;
          }),
        ],
        child: const MaterialApp(home: Scaffold(body: SystemHealthPage())),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('test-ai')));
    await t.pumpAndSettle();
    expect(api.calls, ['test:ai']);
    expect(find.text('Gemini answered: OK'), findsOneWidget);
    await t.tap(find.byKey(const Key('console-ai')));
    expect(opened.single, contains('aistudio.google.com'));
    await t.tap(find.byKey(const Key('errors-ai')));
    await t.pumpAndSettle();
    expect(find.text('Gemini timed out'), findsOneWidget);
  });

  test('chart series parse numbers and labels', () {
    final s = ChartSeries.fromJson({
      'kind': 'time',
      'labels': ['2026-10-17', '2026-10-18'],
      'series': {
        'Count': [1, 4],
      },
    });
    expect(s.series['Count'], [1, 4]);
    expect(
      ChartDef.fromJson({
        'id': 'c1',
        'title': 'T',
        'measure': 'm',
        'type': 'bar',
        'days': 7,
        'page': 'usage',
      }).toJson()['days'],
      7,
    );
  });
}
