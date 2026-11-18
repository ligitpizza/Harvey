import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hypertension/core/constants/enums.dart';
import 'package:hypertension/features/orders/data/order_models.dart';
import 'package:hypertension/features/orders/presentation/pharmacy_shared.dart';
import 'package:hypertension/features/records/data/records_repository.dart';
import 'package:hypertension/features/records/presentation/record_viewer_page.dart';
import 'package:hypertension/features/records/presentation/record_widgets.dart';
import 'package:hypertension/features/records/state/records_providers.dart';
import 'package:hypertension/shared/widgets/reorderable_card_grid.dart';
import 'package:shared_preferences/shared_preferences.dart';

// UAT round 2 (D-113 to D-116): record links, inventory validation, draggable dashboards.

class _Records implements RecordsRepository {
  @override
  Future<Uint8List> fileBytes(String recordId) async => Uint8List(0);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _receipt = HealthRecord(
  id: 'rec1',
  patientId: 'p1',
  category: RecordCategory.other,
  fileName: 'receipt.pdf',
  contentType: 'application/pdf',
  sizeBytes: 10,
  uploadedAt: DateTime(2026, 11, 18),
);

const _catalog = [
  CatalogItem(
    id: 'a5',
    name: 'Amlodipine',
    strength: '5mg',
    form: 'tablet',
    unitPrice: 0.3,
    drugClass: 'Calcium channel blocker',
  ),
  CatalogItem(id: 'a10', name: 'Amlodipine', strength: '10mg', form: 'tablet', unitPrice: 0.45),
];

void main() {
  group('D-113 links into Records open the saved record', () {
    Widget app() => ProviderScope(
      overrides: [
        myRecordsProvider.overrideWith((_) => Stream.value([_receipt])),
        recordsRepositoryProvider.overrideWithValue(_Records()),
        pdfPagesBuilderProvider.overrideWithValue((_, _) => const Text('pdf pages')),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => Column(
                    children: [
                      TextButton(
                        key: const Key('known'),
                        onPressed: () => openRecordById(context, ref, 'rec1'),
                        child: const Text('known'),
                      ),
                      TextButton(
                        key: const Key('unknown'),
                        onPressed: () => openRecordById(context, ref, 'gone'),
                        child: const Text('unknown'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            GoRoute(path: '/records', builder: (_, _) => const Text('records tab')),
          ],
        ),
      ),
    );

    testWidgets('a known id opens that record full screen', (t) async {
      await t.pumpWidget(app());
      await t.tap(find.byKey(const Key('known')));
      await t.pumpAndSettle();
      expect(find.byType(RecordViewerPage), findsOneWidget);
    });

    testWidgets('an unknown id goes to the Records tab instead of an empty page', (t) async {
      await t.pumpWidget(app());
      await t.tap(find.byKey(const Key('unknown')));
      await t.pumpAndSettle();
      expect(find.text('records tab'), findsOneWidget);
    });
  });

  group('D-114 inventory rules', () {
    test('stock units, warning level and medicine name', () {
      expect(StockRules.units('0'), isNotNull);
      expect(StockRules.units('100001'), isNotNull);
      expect(StockRules.units('500'), isNull);
      expect(StockRules.warnAt(''), isNotNull);
      expect(StockRules.warnAt('50'), isNull);
      expect(StockRules.name('Paracetamol', const []), contains('strength'));
      expect(StockRules.name('Paracetamol 500mg', const []), isNull);
      expect(StockRules.name('amlodipine 5mg', const ['Amlodipine 5mg']), contains('Already'));
    });

    test('catalogue name, strength, class and price', () {
      expect(CatalogRules.name('Amlodipine 5mg'), contains('Name only'));
      expect(CatalogRules.name('Olmesartan'), isNull);
      expect(CatalogRules.strength('20'), isNotNull);
      expect(CatalogRules.strength('6.25mg'), isNull);
      expect(CatalogRules.drugClass(''), isNotNull);
      expect(CatalogRules.price('0'), isNotNull);
      expect(CatalogRules.price('1.234'), isNotNull);
      expect(CatalogRules.price('0.45'), isNull);
    });

    Future<Object?> openForm(WidgetTester t, Widget dialog) async {
      Object? result;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await showDialog<Object>(context: context, builder: (_) => dialog),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return result;
    }

    testWidgets('adding a medicine already in the catalogue is refused', (t) async {
      t.view.physicalSize = const Size(1400, 1200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await openForm(t, const CatalogFormDialog(catalog: _catalog));
      await t.enterText(find.byKey(const Key('catalog-name')), 'Amlodipine');
      await t.enterText(find.byKey(const Key('catalog-strength')), '5mg');
      await t.pump();
      expect(find.text('Already in the catalogue.'), findsOneWidget);
    });

    testWidgets('the form is chosen from a menu and returned', (t) async {
      t.view.physicalSize = const Size(1400, 1200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      CatalogEntry? saved;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => saved = await showDialog<CatalogEntry>(
                  context: context,
                  builder: (_) => const CatalogFormDialog(catalog: _catalog),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('catalog-name')), 'Olmesartan');
      await t.enterText(find.byKey(const Key('catalog-strength')), '20mg');
      await t.enterText(find.byKey(const Key('catalog-price')), '1.20');
      await t.tap(find.byKey(const Key('catalog-form')));
      await t.pumpAndSettle();
      for (final f in ['Tablet', 'Capsule', 'Syrup', 'Injection', 'Other']) {
        expect(find.text(f), findsWidgets);
      }
      await t.tap(find.text('Capsule').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('catalog-save')));
      await t.pumpAndSettle();
      // No class yet: the error shows and nothing is saved.
      expect(find.text('Choose or type the drug class.'), findsOneWidget);
      expect(saved, isNull);
      await t.enterText(find.byKey(const Key('catalog-class')), 'Angiotensin receptor blocker');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('catalog-save')));
      await t.pumpAndSettle();
      expect(saved?.form, 'capsule');
      expect(saved?.price, 1.2);
      expect(saved?.name, 'Olmesartan');
    });

    testWidgets('new stock offers only catalogue medicines not yet in stock', (t) async {
      t.view.physicalSize = const Size(1400, 1200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await openForm(
        t,
        const StockDialog(
          title: 'New stock item',
          askName: true,
          catalog: _catalog,
          existing: ['Amlodipine 5mg'],
        ),
      );
      await t.tap(find.byKey(const Key('stock-catalog')));
      await t.pumpAndSettle();
      expect(find.text('Amlodipine 10mg'), findsWidgets);
      expect(find.text('Amlodipine 5mg'), findsNothing);
      await t.tap(find.text('Amlodipine 10mg').last);
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('stock-units')), '0');
      await t.pump();
      expect(find.text('Enter at least 1 unit.'), findsOneWidget);
      final save = t.widget<FilledButton>(find.byKey(const Key('stock-save')));
      expect(save.onPressed, isNull);
    });
  });

  group('D-115 dashboard cards can be rearranged', () {
    test('saved order first, new cards at the end, unknown ids dropped', () {
      expect(ReorderableCardGrid.arrange(['a', 'b', 'c'], ['c', 'x', 'a']), ['c', 'a', 'b']);
      expect(ReorderableCardGrid.arrange(['a', 'b'], null), ['a', 'b']);
    });

    test('a card dropped on another takes its place', () {
      expect(ReorderableCardGrid.move(['a', 'b', 'c'], 'a', 'c'), ['b', 'c', 'a']);
      expect(ReorderableCardGrid.move(['a', 'b', 'c'], 'c', 'a'), ['c', 'a', 'b']);
    });

    testWidgets('dragging a card saves the order and Reset restores it', (t) async {
      SharedPreferences.setMockInitialValues({});
      t.view.physicalSize = const Size(1600, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      Widget card(String id) => SizedBox(
        key: ValueKey(id),
        height: 120,
        child: Card(child: Center(child: Text(id))),
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReorderableCardGrid(
              storageKey: 'test',
              children: [card('one'), card('two'), card('three')],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final g = await t.startGesture(t.getCenter(find.text('one')));
      await t.pump(const Duration(milliseconds: 50));
      await g.moveBy(const Offset(20, 0));
      await t.pump();
      await g.moveTo(t.getCenter(find.text('three')));
      await t.pump();
      await g.up();
      await t.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('dashboard-order:test'), ['two', 'three', 'one']);
      expect(t.getTopLeft(find.text('one')).dx, greaterThan(t.getTopLeft(find.text('three')).dx));
      await t.tap(find.byKey(const Key('dash-reset-layout')));
      await t.pumpAndSettle();
      expect(prefs.getStringList('dashboard-order:test'), isNull);
      expect(t.getTopLeft(find.text('one')).dx, lessThan(t.getTopLeft(find.text('two')).dx));
    });
  });
}
