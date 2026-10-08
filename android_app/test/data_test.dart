import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:spare_parts/data.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory dir;
  late Store store;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('daftar-test-');
    store = Store(dir, factory: databaseFactoryFfi);
    await store.open();
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test(
    'Arabic search and exact prices accept Arabic digits, reject ambiguity',
    () {
      expect(normalize('فِلْتَر أَصْلِي ٠١۲'), 'فلتر اصلي 012');
      expect(money('١٢٥٠٫٥٠'), 125050);
      expect(money('۰.۰۱'), 1);
      expect(money(''), null);
      expect(() => money('1,250'), throwsFormatException);
      expect(() => money('-1'), throwsFormatException);
      expect(() => money('12.123'), throwsFormatException);
      expect(validDate('2026-02-30'), isFalse);
    },
  );
  test(
    'Original examples keep unknown purchase dates and no fabricated contact details',
    () async {
      await store.loadExamples();
      expect(store.products.length, 3);
      expect(store.purchases.every((p) => p['date'] == null), isTrue);
      expect(
        store.suppliers.every((p) => p['phone'] == '' && p['address'] == ''),
        isTrue,
      );
      expect(
        store.products.firstWhere((p) => p['id'] == 'P001')['selling_price'],
        95000,
      );
    },
  );
  test(
    'Latest purchase uses business date, then entry order; old entry does not overwrite latest',
    () async {
      await store.loadExamples();
      await store.savePurchase({
        'id': 'recent',
        'product_id': 'P001',
        'supplier_id': 'S002',
        'date': '2026-10-08',
        'price': 80000,
      }, sellingPrice: 105000);
      await store.savePurchase({
        'id': 'old',
        'product_id': 'P001',
        'supplier_id': 'S003',
        'date': '2025-01-01',
        'price': 60000,
      });
      var product = store.products.firstWhere((p) => p['id'] == 'P001');
      expect(product['latest_price'], 80000);
      expect(product['latest_supplier_id'], 'S002');
      expect(product['selling_price'], 105000);
      await store.savePurchase({
        'id': 'tie',
        'product_id': 'P001',
        'supplier_id': 'S001',
        'date': '2026-10-08',
        'price': 81000,
      });
      product = store.products.firstWhere((p) => p['id'] == 'P001');
      expect(product['latest_price'], 81000);
      await store.close();
      await store.open();
      expect(store.purchases.length, 6);
    },
  );
  test(
    'Foreign key failure rolls back selling price together with purchase',
    () async {
      await store.loadExamples();
      await expectLater(
        store.savePurchase({
          'product_id': 'P001',
          'supplier_id': 'missing',
          'date': '2026-10-08',
          'price': 80000,
        }, sellingPrice: 1),
        throwsA(anything),
      );
      expect(store.purchases.length, 3);
      expect(
        store.products.firstWhere((p) => p['id'] == 'P001')['selling_price'],
        95000,
      );
    },
  );
  test(
    'Backup round trips SQLite and image bytes; corruption leaves live data untouched',
    () async {
      await store.loadExamples();
      final image = File(p.join(dir.path, 'test.png'));
      await image.writeAsBytes([137, 80, 78, 71, 1, 2, 3, 4]);
      await store.saveProduct({
        'id': 'P001',
        'name': 'تيل فرامل تويوتا',
        'selling_price': 95000,
      }, photoSource: image.path);
      final backup = await store.backup();
      final originalImage =
          store.products.firstWhere((p) => p['id'] == 'P001')['image']
              as String;
      await store.saveSupplier({'name': 'مورد جديد'});
      await store.restore(backup);
      expect(store.suppliers.length, 3);
      expect(store.products.length, 3);
      expect(await File(store.imagePath(originalImage)).readAsBytes(), [
        137,
        80,
        78,
        71,
        1,
        2,
        3,
        4,
      ]);
      final corrupt = decodeZip(backup);
      corrupt['database.sqlite'] = Uint8List.fromList([1, 2, 3]);
      await expectLater(
        store.restore(encodeZip(corrupt)),
        throwsFormatException,
      );
      expect(store.products.length, 3);
      expect(await store.db.rawQuery('PRAGMA integrity_check'), [
        {'integrity_check': 'ok'},
      ]);
    },
  );
  test('Restore rejects path traversal', () async {
    final malicious = encodeZip({
      '../outside': Uint8List.fromList([1]),
    });
    expect(() => decodeZip(malicious), throwsFormatException);
    expect(await File(p.join(dir.parent.path, 'outside')).exists(), isFalse);
  });
  test(
    'CSV handles Arabic, quotes, commas, multiline notes and preserves relations',
    () async {
      await store.loadExamples();
      await store.saveSupplier({
        'id': 'S001',
        'name': 'المتحدة "قطع، غيار"',
        'phone': '01000000000',
        'notes': 'سطر أول\nسطر ثانٍ, مكتوب',
      });
      final exported = await store.exportCsv();
      final plan = parseCsvImport(exported, 'tables.zip');
      expect(plan.count, 9);
      final targetDir = await Directory.systemTemp.createTemp('daftar-import-');
      final target = Store(targetDir, factory: databaseFactoryFfi);
      await target.open();
      try {
        await target.importCsv(plan);
        expect(target.products.length, 3);
        expect(target.purchases.length, 3);
        expect(
          target.suppliers.firstWhere((s) => s['id'] == 'S001')['notes'],
          'سطر أول\nسطر ثانٍ, مكتوب',
        );
        await target.importCsv(plan);
        expect(target.purchases.length, 3);
      } finally {
        await target.close();
        await targetDir.delete(recursive: true);
      }
    },
  );
  test('CSV relation errors roll back whole import', () async {
    final plan = ImportPlan({
      'products': [
        {'id': 'good', 'name': 'قطعة'},
      ],
      'purchases': [
        {
          'id': 'bad',
          'product_id': 'good',
          'supplier_id': 'missing',
          'price': 100,
        },
      ],
    });
    await expectLater(store.importCsv(plan), throwsA(anything));
    await store.refresh();
    expect(store.products, isEmpty);
    expect(store.purchases, isEmpty);
  });
  test(
    'Crash recovery restores previous folder when active rename was interrupted',
    () async {
      await store.loadExamples();
      await store.close();
      await store.active.rename(p.join(dir.path, 'previous'));
      await store.open();
      expect(store.products.length, 3);
    },
  );
}
