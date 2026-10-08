import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spare_parts/main.dart';

void main() {
  testWidgets('Startup failure offers diagnostics and prevents parallel retries',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    const details = 'Daftar Parts 1.0.1 (2)\nDatabaseException: test failure';
    String? copied;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final pending = Completer<void>();
    var attempts = 0;
    await tester.pumpWidget(StartupFailureApp(
      details: details,
      retry: () {
        attempts++;
        return pending.future;
      },
    ));
    await tester.pumpAndSettle();
    expect(find.text('تعذر فتح الدفتر المحلي'), findsOneWidget);
    expect(Directionality.of(tester.element(find.text('تعذر فتح الدفتر المحلي'))),
        TextDirection.rtl);
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pump();
    expect(attempts, 1);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('إعادة المحاولة'), findsOneWidget);
    await tester.tap(find.text('تفاصيل الخطأ'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('نسخ التفاصيل'));
    await tester.tap(find.text('نسخ التفاصيل'));
    await tester.pumpAndSettle();
    expect(copied, details);
    expect(tester.takeException(), isNull);
  });
}
