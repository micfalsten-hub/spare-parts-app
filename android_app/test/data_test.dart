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
  test('Deleted products, suppliers, and purchases can be restored from trash', () async {
    await store.loadExamples();

    await store.deleteProduct('P001');
    expect(store.products.length, 2);
    expect(store.purchases.length, 2);
    final productTrash = store.trashEntries.singleWhere((r) => r['entity_type'] == 'product');
    await store.restoreTrashEntry(productTrash['id'] as String);
    expect(store.products.length, 3);
    expect(store.purchases.length, 3);

    await store.deleteSupplier('S002');
    expect(store.suppliers.length, 2);
    expect(store.purchases.length, 2);
    final supplierTrash = store.trashEntries.singleWhere((r) => r['entity_type'] == 'supplier');
    await store.restoreTrashEntry(supplierTrash['id'] as String);
    expect(store.suppliers.length, 3);
    expect(store.purchases.length, 3);

    final purchaseId = store.purchases.first['id'] as String;
    await store.deletePurchase(purchaseId);
    expect(store.purchases.length, 2);
    final purchaseTrash = store.trashEntries.singleWhere((r) => r['entity_type'] == 'purchase');
    await store.restoreTrashEntry(purchaseTrash['id'] as String);
    expect(store.purchases.length, 3);
    expect(store.trashEntries, isEmpty);
  });

  test('Database v1 upgrades without losing data and adds origin and trash', () async {
    await store.close();
    await dir.delete(recursive: true);
    final active = Directory(p.join(dir.path, 'active'));
    await active.create(recursive: true);
    final legacy = await databaseFactoryFfi.openDatabase(
      p.join(active.path, 'database.sqlite'),
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''CREATE TABLE products (
            id TEXT PRIMARY KEY, name TEXT NOT NULL CHECK(length(trim(name))>0),
            code TEXT NOT NULL DEFAULT '', category TEXT NOT NULL DEFAULT '',
            selling_price INTEGER CHECK(selling_price >= 0),
            image TEXT, notes TEXT NOT NULL DEFAULT '')''');
          await db.execute('''CREATE TABLE suppliers (
            id TEXT PRIMARY KEY, name TEXT NOT NULL CHECK(length(trim(name))>0),
            phone TEXT NOT NULL DEFAULT '', whatsapp TEXT NOT NULL DEFAULT '',
            address TEXT NOT NULL DEFAULT '', notes TEXT NOT NULL DEFAULT '')''');
          await db.execute('''CREATE TABLE purchases (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL,
            product_id TEXT NOT NULL REFERENCES products(id),
            supplier_id TEXT NOT NULL REFERENCES suppliers(id),
            date TEXT, price INTEGER NOT NULL CHECK(price >= 0),
            notes TEXT NOT NULL DEFAULT '')''');
          await db.execute('CREATE INDEX purchase_product ON purchases(product_id, date DESC, sequence DESC)');
          await db.execute('CREATE INDEX purchase_supplier ON purchases(supplier_id, date DESC, sequence DESC)');
        },
      ),
    );
    await legacy.insert('products', {'id': 'old-p', 'name': 'قطعة قديمة', 'selling_price': 1200});
    await legacy.insert('suppliers', {'id': 'old-s', 'name': 'مورد قديم'});
    await legacy.insert('purchases', {
      'id': 'old-b',
      'product_id': 'old-p',
      'supplier_id': 'old-s',
      'price': 900,
      'date': null,
    });
    await legacy.close();

    await store.open();
    expect(store.products.single['name'], 'قطعة قديمة');
    expect(store.products.single['country_of_origin'], '');
    expect(store.purchases.single['id'], 'old-b');
    expect(await store.db.getVersion(), appDatabaseVersion);
    expect(store.trashEntries, isEmpty);
  });

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
        'country_of_origin': 'اليابان',
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
      await store.saveProduct({
        'id': 'P001',
        'name': 'تيل فرامل تويوتا',
        'country_of_origin': 'اليابان',
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
        expect(target.products.firstWhere((p) => p['id'] == 'P001')['country_of_origin'], 'اليابان');
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
