import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hypertension/features/orders/presentation/cashflow_page.dart';
import 'package:hypertension/features/settings/data/settings_repository.dart';
import 'package:hypertension/features/settings/state/settings_providers.dart';
import 'package:hypertension/shared/providers/api_providers.dart';

import '../helpers/fakes.dart';

// D-85: cashflow, order payments and receipts for the pharmacy and admin.

final _now = DateTime.now().toUtc();

class CashApi extends FakeApiClient {
  final calls = <String>[];
  bool paid = true;

  @override
  Future<Map<String, dynamic>> cashflow(int days) async {
    calls.add('cashflow:$days');
    return {
      'days': days,
      'received': 83.2,
      'medicineRevenue': 75.0,
      'deliveryFees': 8.2,
      'paidCount': 2,
      'averagePayment': 41.6,
      'failedCount': 1,
      'failedAmount': 25.0,
      'outstanding': 30.0,
      'outstandingCount': 1,
      'byMethod': {'delivery': 58.2, 'collection': 25.0},
      'byDay': [
        for (var i = days - 1; i >= 0; i--)
          {
            'date': _now.subtract(Duration(days: i)).toIso8601String().substring(0, 10),
            'amount': i == 1 ? 58.2 : 0,
          },
      ],
      'transactions': [
        {
          'id': 'ch_1',
          'orderId': 'o1',
          'orderRef': 'CF-AD10F4',
          'patientName': 'Woo Yee Ping',
          'amount': 58.2,
          'status': 'succeeded',
          'processedAt': _now.toIso8601String(),
          'chargeId': 'ch_1',
        },
        {
          'id': 'pi_9_failed',
          'orderId': 'o2',
          'orderRef': 'CF-FF1191',
          'patientName': 'Woo Yee Ping',
          'amount': 25.0,
          'status': 'failed',
          'processedAt': _now.toIso8601String(),
          'chargeId': 'pi_9',
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> orderPayments(String orderId) async => {
    'orderId': orderId,
    'orderRef': 'CF-AD10F4',
    'patient': {'name': 'Woo Yee Ping', 'email': 'woo@x.my'},
    'paymentStatus': paid ? 'paid' : 'pending',
    'transactions': paid
        ? [
            {
              'id': 'ch_1',
              'amount': 58.2,
              'status': 'succeeded',
              'processedAt': _now.toIso8601String(),
              'chargeId': 'ch_1',
            },
          ]
        : [],
    'receipt': paid
        ? {
            'paidAt': _now.toIso8601String(),
            'reference': 'ch_1',
            'medication': 'Felodipine 5mg x30',
            'medicineAmount': 50.0,
            'deliveryFee': 8.2,
            'method': 'home_delivery',
            'total': 58.2,
            'processor': 'Stripe (test mode)',
          }
        : null,
  };

  @override
  Future<List<int>> receiptPdf(String orderId) async {
    calls.add('pdf:$orderId');
    return [37, 80, 68, 70];
  }
}

class FakeSharer implements FileSharer {
  final shared = <String>[];

  @override
  Future<void> share(Uint8List bytes, {required String fileName, required String mimeType}) async =>
      shared.add('$fileName:$mimeType:${bytes.length}');
}

late CashApi api;
late FakeSharer sharer;

Widget host(Widget page, {String at = '/'}) {
  final router = GoRouter(
    initialLocation: at,
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(body: page),
      ),
      GoRoute(
        path: '/admin/orders/:id',
        builder: (_, s) => Text('ORDER ${s.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/pharmacy/order/:id',
        builder: (_, s) => Text('PH ORDER ${s.pathParameters['id']}'),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      fileSharerProvider.overrideWithValue(sharer),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

Future<void> wide(WidgetTester t) async {
  t.view.physicalSize = const Size(1400, 1800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() {
    api = CashApi();
    sharer = FakeSharer();
  });

  testWidgets('cashflow shows received, owed, failed and opens an order', (t) async {
    await wide(t);
    await t.pumpWidget(host(const CashflowPage(admin: true)));
    await t.pumpAndSettle();
    expect(api.calls, ['cashflow:30']);
    expect(find.text('RM83.20'), findsOneWidget);
    expect(find.text('RM30.00'), findsOneWidget);
    expect(find.textContaining('1 order(s) waiting'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget); // the failed payment's chip
    await t.tap(find.text('7 days'));
    await t.pumpAndSettle();
    expect(api.calls.last, 'cashflow:7');
    await t.tap(find.byKey(const Key('payment-ch_1')));
    await t.pumpAndSettle();
    expect(find.text('ORDER o1'), findsOneWidget);
  });

  testWidgets('the pharmacist opens orders on the pharmacy side', (t) async {
    await wide(t);
    await t.pumpWidget(host(const CashflowPage()));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('payment-pi_9_failed')));
    await t.pumpAndSettle();
    expect(find.text('PH ORDER o2'), findsOneWidget);
  });

  testWidgets('order payment card shows the receipt and downloads the PDF', (t) async {
    await wide(t);
    await t.pumpWidget(host(const SingleChildScrollView(child: OrderPaymentCard(orderId: 'o1'))));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('receipt')), findsOneWidget);
    expect(find.textContaining('Harvey payment receipt · CF-AD10F4'), findsOneWidget);
    expect(find.text('RM58.20'), findsWidgets);
    expect(find.textContaining('Reference ch_1'), findsOneWidget);
    await t.tap(find.byKey(const Key('download-receipt')));
    await t.pumpAndSettle();
    expect(api.calls, ['pdf:o1']);
    expect(sharer.shared, ['receipt-CF-AD10F4.pdf:application/pdf:4']);
  });

  testWidgets('an unpaid order says there is no receipt yet', (t) async {
    api.paid = false;
    await wide(t);
    await t.pumpWidget(host(const SingleChildScrollView(child: OrderPaymentCard(orderId: 'o3'))));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('no-receipt')), findsOneWidget);
    expect(find.byKey(const Key('download-receipt')), findsNothing);
  });
}
