import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spare_parts/data.dart';
import 'package:spare_parts/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final loader = FontLoader('NotoArabic');
    loader.addFont(rootBundle.load('assets/fonts/NotoSansArabic.ttf'));
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  late Directory dir;
  late Store store;
  setUp(() async {
    sqfliteFfiInit();
    dir = await Directory.systemTemp.createTemp('daftar-ui-');
    store = Store(dir, factory: databaseFactoryFfi);
    await store.open();
    await store.loadExamples();
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  testWidgets(
    'Arabic catalog, search, profiles and forms render at phone sizes',
    (tester) async {
      debugDisableShadows = false;
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: SparePartsApp(store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        Directionality.of(tester.element(find.text('دفتر القطع'))),
        TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
      if (Platform.environment['CAPTURE_UI'] == '1') {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '../../work/catalog.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.enterText(find.byType(TextField).first, 'تويوتا');
      await tester.pumpAndSettle();
      expect(find.text('تيل فرامل تويوتا'), findsOneWidget);
      expect(find.text('فلتر زيت نيسان'), findsNothing);
      await tester.tap(find.text('تيل فرامل تويوتا'));
      await tester.pumpAndSettle();
      expect(find.text('تفاصيل القطعة'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['CAPTURE_UI'] == '1') {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '../../work/product.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byTooltip('تعديل القطعة'));
      await tester.pumpAndSettle();
      expect(find.text('حفظ القطعة'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('الموردون'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('النور لقطع الغيار'));
      await tester.pumpAndSettle();
      expect(find.text('ملف المورد'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('تسجيل شراء من هذا المورد'));
      await tester.pumpAndSettle();
      expect(find.text('حفظ عملية الشراء'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('النسخ الاحتياطي والإعدادات'));
      await tester.pumpAndSettle();
      expect(find.text('حفظ نسخة احتياطية'), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugDisableShadows = true;
    },
  );
}
