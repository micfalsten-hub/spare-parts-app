import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

typedef DbRow = Map<String, Object?>;
const appDatabaseVersion = 3;
const trashRetention = Duration(days: 30);

String digits(String input) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  var result = input;
  for (var i = 0; i < 10; i++) {
    result = result.replaceAll(arabic[i], '$i').replaceAll(persian[i], '$i');
  }
  return result;
}

String normalize(String input) => digits(input)
    .toLowerCase()
    .replaceAll(RegExp('[أإآ]'), 'ا')
    .replaceAll('ى', 'ي')
    .replaceAll(RegExp('[\u064B-\u065F\u0670ـ]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Integer minor units keep prices exact. Group separators are rejected rather
/// than silently turning an ambiguous number into a different price.
int? money(String value) {
  final clean = digits(value.trim()).replaceAll('٫', '.');
  if (clean.isEmpty) return null;
  if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(clean)) {
    throw const FormatException('اكتب سعرًا صحيحًا، مثل 1250 أو 1250.50');
  }
  final parts = clean.split('.');
  return int.parse(parts[0]) * 100 +
      (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
}

String moneyInput(Object? value) {
  if (value == null) return '';
  final cents = value as int;
  return '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
}

String newId(String prefix) =>
    '$prefix${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random.secure().nextInt(1 << 24).toRadixString(36)}';
bool safeImage(String name) =>
    RegExp(r'^[a-zA-Z0-9_-]+\.(jpg|jpeg|png|webp)$').hasMatch(name);
bool validDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final date = DateTime.tryParse(value);
  return date != null && date.toIso8601String().substring(0, 10) == value;
}

const productSql = '''
SELECT p.*, b.price AS latest_price, b.date AS latest_date,
 b.supplier_id AS latest_supplier_id, s.name AS latest_supplier,
 (SELECT COUNT(*) FROM purchases WHERE product_id=p.id) AS purchase_count
FROM products p
LEFT JOIN purchases b ON b.id=(SELECT id FROM purchases WHERE product_id=p.id
 ORDER BY (date IS NULL) ASC, date DESC, sequence DESC LIMIT 1)
LEFT JOIN suppliers s ON s.id=b.supplier_id
''';

class Store extends ChangeNotifier {
  Store(this.root, {DatabaseFactory? factory})
    : factory = factory ?? databaseFactory;
  final Directory root;
  final DatabaseFactory factory;
  Database? _db;
  Database get db => _db ?? (throw StateError('الدفتر غير مفتوح'));
  List<DbRow> products = [];
  List<DbRow> suppliers = [];
  List<DbRow> purchases = [];
  List<DbRow> trashEntries = [];
  bool _busy = false;
  Timer? _purgeTimer;
  Directory get active => Directory(p.join(root.path, 'active'));
  Directory get imageDir => Directory(p.join(active.path, 'images'));
  String get dbPath => p.join(active.path, 'database.sqlite');
  String imagePath(String name) => p.join(imageDir.path, name);

  Future<void> open() async {
    await root.create(recursive: true);
    final previous = Directory(p.join(root.path, 'previous'));
    // Recovery if the process was killed between the two directory renames.
    if (!await active.exists() && await previous.exists()) {
      await previous.rename(active.path);
    }
    await imageDir.create(recursive: true);
    _db = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: appDatabaseVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys=ON');
          // Setting journal_mode returns a row. Android execSQL (execute)
          // rejects that statement; query it before any transaction starts.
          final mode = await db.rawQuery('PRAGMA journal_mode=DELETE');
          if (mode.isEmpty || mode.first.values.single != 'delete') {
            throw StateError('تعذر تهيئة قاعدة البيانات للنسخ الاحتياطي');
          }
        },
        onCreate: (db, _) async {
          await db.execute('''CREATE TABLE products (
          id TEXT PRIMARY KEY, name TEXT NOT NULL CHECK(length(trim(name))>0),
          code TEXT NOT NULL DEFAULT '', category TEXT NOT NULL DEFAULT '',
          country_of_origin TEXT NOT NULL DEFAULT '',
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
          await db.execute(
            'CREATE INDEX purchase_product ON purchases(product_id, date DESC, sequence DESC)',
          );
          await db.execute(
            'CREATE INDEX purchase_supplier ON purchases(supplier_id, date DESC, sequence DESC)',
          );
          await db.execute('''CREATE TABLE trash (
            id TEXT PRIMARY KEY, entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL, payload TEXT NOT NULL,
            deleted_at TEXT NOT NULL)''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              "ALTER TABLE products ADD COLUMN country_of_origin TEXT NOT NULL DEFAULT ''",
            );
          }
          if (oldVersion < 3) {
            await db.execute('''CREATE TABLE trash (
              id TEXT PRIMARY KEY, entity_type TEXT NOT NULL,
              entity_id TEXT NOT NULL, payload TEXT NOT NULL,
              deleted_at TEXT NOT NULL)''');
          }
        },
      ),
    );
    try {
      await _purgeExpiredTrash();
      await refresh();
      _purgeTimer?.cancel();
      _purgeTimer = Timer.periodic(const Duration(hours: 1), (_) {
        if (!_busy && _db != null) {
          unawaited(_write(() async {
            await _purgeExpiredTrash();
            await refresh();
          }));
        }
      });
    } catch (_) {
      // Release the handle so retry can reopen it. Never delete user files.
      try {
        await close();
      } catch (_) {
        // Preserve the original startup exception for diagnostics.
      }
      rethrow;
    }
  }

  Future<void> refresh() async {
    products = await db.rawQuery('$productSql ORDER BY p.name COLLATE NOCASE');
    suppliers = await db.rawQuery('''SELECT s.*,
      (SELECT COUNT(*) FROM purchases WHERE supplier_id=s.id) AS purchase_count
      FROM suppliers s ORDER BY name COLLATE NOCASE''');
    purchases = await db.rawQuery('''SELECT b.*, p.name AS product_name,
      p.image AS product_image, s.name AS supplier_name
      FROM purchases b JOIN products p ON p.id=b.product_id
      JOIN suppliers s ON s.id=b.supplier_id
      ORDER BY (b.date IS NULL) ASC, b.date DESC, b.sequence DESC''');
    trashEntries = await db.query('trash', orderBy: 'deleted_at DESC');
    notifyListeners();
  }

  Future<T> _write<T>(Future<T> Function() action) async {
    if (_busy) throw StateError('انتظر اكتمال العملية الحالية');
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }

  Future<String> saveProduct(
    DbRow row, {
    String? photoSource,
  }) => _write(() async {
    final value = Map<String, Object?>.from(row);
    final id = (value['id'] as String?) ?? newId('P');
    value['id'] = id;
    final oldRows = await db.query(
      'products',
      columns: ['image'],
      where: 'id=?',
      whereArgs: [id],
    );
    final oldImage = oldRows.isEmpty ? null : oldRows.first['image'] as String?;
    if (!value.containsKey('image')) {
      value['image'] = oldImage;
    }
    String? copied;
    if (photoSource != null) {
      final ext = p.extension(photoSource).toLowerCase().replaceFirst('.', '');
      if (!['jpg', 'jpeg', 'png', 'webp'].contains(ext)) {
        throw const FormatException('اختر صورة JPG أو PNG أو WebP');
      }
      copied = '${newId('IMG')}.$ext';
      final source = File(photoSource);
      if (await source.length() > 20 * 1024 * 1024) {
        throw const FormatException('الصورة كبيرة؛ الحد الأقصى 20 ميجابايت');
      }
      await source.copy(imagePath(copied));
      value['image'] = copied;
    }
    try {
      await db.transaction((txn) async {
        final exists = await txn.query(
          'products',
          columns: ['id'],
          where: 'id=?',
          whereArgs: [id],
        );
        if (exists.isEmpty) {
          await txn.insert('products', value);
        } else {
          await txn.update('products', value, where: 'id=?', whereArgs: [id]);
        }
      });
    } catch (_) {
      if (copied != null) await File(imagePath(copied)).delete();
      rethrow;
    }
    if (oldImage != null && oldImage != value['image'] && safeImage(oldImage)) {
      final remaining = await db.query(
        'products',
        columns: ['id'],
        where: 'image=?',
        whereArgs: [oldImage],
      );
      if (remaining.isEmpty) {
        try {
          final oldFile = File(imagePath(oldImage));
          if (await oldFile.exists()) await oldFile.delete();
        } on FileSystemException {
          /* Retry cleanup on a later edit; the committed record is safe. */
        }
      }
    }
    await refresh();
    return id;
  });

  Future<String> saveSupplier(DbRow row) => _write(() async {
    final value = Map<String, Object?>.from(row);
    final id = (value['id'] as String?) ?? newId('S');
    value['id'] = id;
    final exists = await db.query(
      'suppliers',
      columns: ['id'],
      where: 'id=?',
      whereArgs: [id],
    );
    if (exists.isEmpty) {
      await db.insert('suppliers', value);
    } else {
      await db.update('suppliers', value, where: 'id=?', whereArgs: [id]);
    }
    await refresh();
    return id;
  });

  Future<int> deleteProduct(String id) => _write(() async {
    final removedPurchases = await db.transaction((txn) async {
      final products = await txn.query('products', where: 'id=?', whereArgs: [id]);
      if (products.isEmpty) return 0;
      final linked = await txn.query('purchases', where: 'product_id=?', whereArgs: [id]);
      await txn.insert('trash', {
        'id': newId('T'),
        'entity_type': 'product',
        'entity_id': id,
        'payload': jsonEncode({'entity': products.first, 'purchases': linked}),
        'deleted_at': DateTime.now().toUtc().toIso8601String(),
      });
      await txn.delete('purchases', where: 'product_id=?', whereArgs: [id]);
      await txn.delete('products', where: 'id=?', whereArgs: [id]);
      return linked.length;
    });
    await refresh();
    return removedPurchases;
  });

  Future<int> deleteSupplier(String id) => _write(() async {
    final removedPurchases = await db.transaction((txn) async {
      final suppliers = await txn.query('suppliers', where: 'id=?', whereArgs: [id]);
      if (suppliers.isEmpty) return 0;
      final linked = await txn.query('purchases', where: 'supplier_id=?', whereArgs: [id]);
      await txn.insert('trash', {
        'id': newId('T'),
        'entity_type': 'supplier',
        'entity_id': id,
        'payload': jsonEncode({'entity': suppliers.first, 'purchases': linked}),
        'deleted_at': DateTime.now().toUtc().toIso8601String(),
      });
      await txn.delete('purchases', where: 'supplier_id=?', whereArgs: [id]);
      await txn.delete('suppliers', where: 'id=?', whereArgs: [id]);
      return linked.length;
    });
    await refresh();
    return removedPurchases;
  });

  Future<void> deletePurchase(String id) => _write(() async {
    await db.transaction((txn) async {
      final rows = await txn.query('purchases', where: 'id=?', whereArgs: [id]);
      if (rows.isEmpty) return;
      await txn.insert('trash', {
        'id': newId('T'),
        'entity_type': 'purchase',
        'entity_id': id,
        'payload': jsonEncode({'entity': rows.first, 'purchases': []}),
        'deleted_at': DateTime.now().toUtc().toIso8601String(),
      });
      await txn.delete('purchases', where: 'id=?', whereArgs: [id]);
    });
    await refresh();
  });

  Future<void> restoreTrashEntry(String id) => _write(() async {
    await db.transaction((txn) async {
      final entries = await txn.query('trash', where: 'id=?', whereArgs: [id]);
      if (entries.isEmpty) return;
      final entry = entries.first;
      final payload = jsonDecode(entry['payload'] as String) as Map<String, dynamic>;
      final entity = Map<String, Object?>.from(payload['entity'] as Map);
      final linked = (payload['purchases'] as List)
          .map((row) => Map<String, Object?>.from(row as Map))
          .toList();
      final table = switch (entry['entity_type']) {
        'product' => 'products',
        'supplier' => 'suppliers',
        'purchase' => 'purchases',
        _ => throw const FormatException('عنصر سلة غير معروف'),
      };
      final exists = await txn.query(table, where: 'id=?', whereArgs: [entity['id']]);
      if (exists.isNotEmpty) {
        throw const FormatException('يوجد عنصر آخر بنفس المعرّف؛ لم تتم الاستعادة');
      }
      await txn.insert(table, entity);
      for (final purchase in linked) {
        final exists = await txn.query('purchases', where: 'id=?', whereArgs: [purchase['id']]);
        if (exists.isNotEmpty) {
          throw const FormatException('إحدى عمليات الشراء موجودة بالفعل؛ لم تتم الاستعادة');
        }
        await txn.insert('purchases', purchase);
      }
      await txn.delete('trash', where: 'id=?', whereArgs: [id]);
    });
    await refresh();
  });

  Future<void> emptyTrash() => _write(() async {
    final entries = await db.query('trash');
    await db.transaction((txn) async => txn.delete('trash'));
    await _removeTrashedImages(entries);
    await refresh();
  });

  Future<void> _purgeExpiredTrash() async {
    final cutoff = DateTime.now().toUtc().subtract(trashRetention).toIso8601String();
    final expired = await db.query('trash', where: 'deleted_at<?', whereArgs: [cutoff]);
    if (expired.isEmpty) return;
    await db.transaction((txn) async {
      await txn.delete('trash', where: 'deleted_at<?', whereArgs: [cutoff]);
    });
    await _removeTrashedImages(expired);
    await refresh();
  }

  Future<void> _removeTrashedImages(List<DbRow> entries) async {
    for (final entry in entries) {
      if (entry['entity_type'] != 'product') continue;
      try {
        final payload = jsonDecode(entry['payload'] as String) as Map<String, dynamic>;
        final entity = Map<String, Object?>.from(payload['entity'] as Map);
        final image = entity['image'] as String?;
        if (image == null || !safeImage(image)) continue;
        final file = File(imagePath(image));
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // Expired data is gone; a leftover photo is safe and can be ignored.
      } on FormatException {
        // Skip a damaged optional trash photo reference.
      }
    }
  }

  Future<void> savePurchase(DbRow row, {int? sellingPrice}) => _write(() async {
    final value = Map<String, Object?>.from(row);
    final date = value['date'];
    if (date != null && !validDate(date as String)) {
      throw const FormatException('تاريخ غير صحيح');
    }
    value['id'] ??= newId('B');
    await db.transaction((txn) async {
      final exists = await txn.query(
        'purchases',
        columns: ['id'],
        where: 'id=?',
        whereArgs: [value['id']],
      );
      if (exists.isEmpty) {
        await txn.insert('purchases', value);
      } else {
        await txn.update(
          'purchases',
          value,
          where: 'id=?',
          whereArgs: [value['id']],
        );
      }
      if (sellingPrice != null) {
        await txn.update(
          'products',
          {'selling_price': sellingPrice},
          where: 'id=?',
          whereArgs: [value['product_id']],
        );
      }
    });
    await refresh();
  });

  Future<void> loadExamples() => _write(() async {
    if (products.isNotEmpty || suppliers.isNotEmpty || purchases.isNotEmpty) {
      throw StateError('البيانات السابقة متاحة فقط عندما تكون الدفاتر فارغة');
    }
    await db.transaction((txn) async {
      const names = ['تيل فرامل تويوتا', 'طلمبة مياه لانسر', 'فلتر زيت نيسان'];
      const supplierNames = [
        'المتحدة لقطع الغيار',
        'النور لقطع الغيار',
        'الشرق لقطع الغيار',
      ];
      const sell = [95000, 145000, 32000];
      const buy = [72000, 118000, 24000];
      for (var i = 0; i < 3; i++) {
        await txn.insert('products', {
          'id': 'P00${i + 1}',
          'name': names[i],
          'selling_price': sell[i],
          'notes': 'من بيانات النموذج السابق',
        });
        await txn.insert('suppliers', {
          'id': 'S00${i + 1}',
          'name': supplierNames[i],
        });
        await txn.insert('purchases', {
          'id': 'B00${i + 1}',
          'product_id': 'P00${i + 1}',
          'supplier_id': 'S00${i + 1}',
          'date': null,
          'price': buy[i],
          'notes': 'سعر من النموذج السابق؛ تاريخ الشراء غير مسجل',
        });
      }
    });
    await refresh();
  });

  Future<Uint8List> backup() => _write(() async {
    // DELETE journal mode and a serialized read transaction provide a
    // consistent file snapshot on old Android SQLite versions too.
    final snapshot = await db.transaction((txn) async {
      await txn.rawQuery('SELECT count(*) FROM products');
      return File(dbPath).readAsBytes();
    });
    final files = <String, Uint8List>{'database.sqlite': snapshot};
    final imageNames = <String>{
      for (final row in products)
        if (row['image'] != null) row['image'] as String,
    };
    for (final entry in trashEntries) {
      if (entry['entity_type'] != 'product') continue;
      final payload = jsonDecode(entry['payload'] as String) as Map<String, dynamic>;
      final entity = Map<String, Object?>.from(payload['entity'] as Map);
      final name = entity['image'] as String?;
      if (name != null) imageNames.add(name);
    }
    for (final name in imageNames) {
      if (!safeImage(name)) throw const FormatException('اسم صورة غير صالح');
      final file = File(imagePath(name));
      if (!await file.exists()) {
        throw const FormatException('صورة مفقودة؛ عدّل صورة المنتج أولًا');
      }
      files['images/$name'] = await file.readAsBytes();
    }
    files['manifest.json'] = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'spare-parts-backup',
          'version': 1,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'files': {
            for (final entry in files.entries)
              entry.key: sha256.convert(entry.value).toString(),
          },
        }),
      ),
    );
    if (files.values.fold<int>(0, (sum, bytes) => sum + bytes.length) >
        300 * 1024 * 1024) {
      throw const FormatException(
        'الصور أكبر من حد النسخة: 300 ميجابايت. استخدم صورًا أصغر.',
      );
    }
    final zip = encodeZip(files);
    if (zip.length > 100 * 1024 * 1024) {
      throw const FormatException(
        'النسخة أكبر من 100 ميجابايت. استخدم صورًا أصغر.',
      );
    }
    return zip;
  });

  Future<void> restore(Uint8List bytes) => _write(() async {
    final files = decodeZip(bytes);
    final manifestBytes = files.remove('manifest.json');
    if (manifestBytes == null) {
      throw const FormatException('هذا ليس ملف نسخة احتياطية للتطبيق');
    }
    final manifest =
        jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
    if (manifest['format'] != 'spare-parts-backup' ||
        manifest['version'] != 1) {
      throw const FormatException('صيغة النسخة غير مدعومة');
    }
    final hashes = manifest['files'] as Map<String, dynamic>;
    if (files.length != hashes.length ||
        !files.containsKey('database.sqlite')) {
      throw const FormatException('النسخة غير مكتملة');
    }
    for (final entry in files.entries) {
      if (entry.key != 'database.sqlite' &&
          !(entry.key.startsWith('images/') &&
              safeImage(entry.key.substring(7)))) {
        throw const FormatException('النسخة تحتوي على ملف غير صالح');
      }
      if (sha256.convert(entry.value).toString() != hashes[entry.key]) {
        throw const FormatException('ملف تالف داخل النسخة الاحتياطية');
      }
    }
    final staged = Directory(p.join(root.path, newId('restore')));
    Database? check;
    try {
      await Directory(p.join(staged.path, 'images')).create(recursive: true);
      for (final entry in files.entries) {
        await File(
          p.join(staged.path, entry.key),
        ).writeAsBytes(entry.value, flush: true);
      }
      check = await factory.openDatabase(
        p.join(staged.path, 'database.sqlite'),
        options: OpenDatabaseOptions(
          version: appDatabaseVersion,
          singleInstance: false,
          onUpgrade: (database, oldVersion, newVersion) async {
            if (oldVersion < 2) {
              await database.execute(
                "ALTER TABLE products ADD COLUMN country_of_origin TEXT NOT NULL DEFAULT ''",
              );
            }
            if (oldVersion < 3) {
              await database.execute('''CREATE TABLE trash (
                id TEXT PRIMARY KEY, entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL, payload TEXT NOT NULL,
                deleted_at TEXT NOT NULL)''');
            }
          },
        ),
      );
      if (await check.getVersion() != appDatabaseVersion ||
          (await check.rawQuery(
                'PRAGMA integrity_check',
              )).single.values.single !=
              'ok' ||
          (await check.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
        throw const FormatException('قاعدة البيانات غير صالحة');
      }
      // Verify all columns used by the app before touching live data.
      await check.rawQuery('$productSql LIMIT 1');
      await check.rawQuery(
        'SELECT id,name,phone,whatsapp,address,notes FROM suppliers LIMIT 1',
      );
      await check.rawQuery(
        'SELECT id,sequence,product_id,supplier_id,date,price,notes FROM purchases LIMIT 1',
      );
      for (final row in await check.query('products')) {
        final image = row['image'] as String?;
        if (image != null &&
            (!safeImage(image) || !files.containsKey('images/$image'))) {
          throw const FormatException('صورة مفقودة في النسخة');
        }
        if ((row['name'] as String).trim().isEmpty ||
            (row['selling_price'] != null &&
                (row['selling_price'] as int) < 0)) {
          throw const FormatException('بيانات منتج غير صالحة');
        }
      }
      for (final row in await check.query('purchases')) {
        if ((row['price'] as int) < 0 ||
            (row['date'] != null && !validDate(row['date'] as String))) {
          throw const FormatException('بيانات شراء غير صالحة');
        }
      }
      for (final entry in await check.query('trash')) {
        if (entry['entity_type'] != 'product') continue;
        final payload = jsonDecode(entry['payload'] as String) as Map<String, dynamic>;
        final entity = Map<String, Object?>.from(payload['entity'] as Map);
        final image = entity['image'] as String?;
        if (image != null &&
            (!safeImage(image) || !files.containsKey('images/$image'))) {
          throw const FormatException('صورة مفقودة في سلة المحذوفات');
        }
      }
      await check.close();
      check = null;
      final previous = Directory(p.join(root.path, 'previous'));
      if (await previous.exists()) await previous.delete(recursive: true);
      await db.close();
      var movedOld = false;
      try {
        await active.rename(previous.path);
        movedOld = true;
        await staged.rename(active.path);
        await open();
      } catch (_) {
        if (movedOld) {
          if (await active.exists()) await active.delete(recursive: true);
          await previous.rename(active.path);
        }
        await open();
        rethrow;
      }
    } finally {
      await check?.close();
      if (await staged.exists()) await staged.delete(recursive: true);
    }
  });

  Future<Uint8List> exportCsv() => _write(() async {
    final files = <String, Uint8List>{};
    for (final spec in csvSpecs) {
      final rows = await db.query(
        spec.table,
        orderBy: spec.table == 'purchases' ? 'sequence' : 'id',
      );
      files['${spec.table}.csv'] = Uint8List.fromList(
        utf8.encode(
          '\uFEFF${csvEncode([
            spec.columns,
            for (final row in rows) [for (var i = 0; i < spec.keys.length; i++) spec.moneyKeys.contains(spec.keys[i]) ? moneyInput(row[spec.keys[i]]) : '${row[spec.keys[i]] ?? ''}'],
          ])}',
        ),
      );
    }
    files['README.txt'] = Uint8List.fromList(
      utf8.encode(
        'UTF-8 CSV. Prices in EGP. Blank purchase dates mean unknown. IDs join the three tables. Import merges by ID; it never deletes rows. Photos are included only in full backups.',
      ),
    );
    return encodeZip(files);
  });

  Future<void> importCsv(ImportPlan plan) => _write(() async {
    await db.transaction((txn) async {
      for (final spec in csvSpecs) {
        for (final row in plan.tables[spec.table] ?? <DbRow>[]) {
          if (spec.table == 'purchases') {
            final product = await txn.query(
              'products',
              columns: ['id'],
              where: 'id=?',
              whereArgs: [row['product_id']],
            );
            final supplier = await txn.query(
              'suppliers',
              columns: ['id'],
              where: 'id=?',
              whereArgs: [row['supplier_id']],
            );
            if (product.isEmpty || supplier.isEmpty) {
              throw FormatException(
                'عملية ${row['id']} تشير إلى قطعة أو مورد غير موجود. استورد القطع والموردين معها أو قبلها.',
              );
            }
          }
          final exists = await txn.query(
            spec.table,
            columns: ['id'],
            where: 'id=?',
            whereArgs: [row['id']],
          );
          if (exists.isEmpty) {
            await txn.insert(spec.table, row);
          } else {
            await txn.update(
              spec.table,
              row,
              where: 'id=?',
              whereArgs: [row['id']],
            );
          }
        }
      }
    });
    await refresh();
  });

  Future<void> close() async {
    final opened = _db;
    _db = null;
    _purgeTimer?.cancel();
    _purgeTimer = null;
    await opened?.close();
  }
}

Uint8List encodeZip(Map<String, Uint8List> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Map<String, Uint8List> decodeZip(Uint8List bytes) {
  if (bytes.length > 100 * 1024 * 1024) {
    throw const FormatException('الملف أكبر من 100 ميجابايت');
  }
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  if (archive.length > 5000) {
    throw const FormatException('عدد الملفات أكبر من المسموح');
  }
  var size = 0;
  final files = <String, Uint8List>{};
  for (final file in archive) {
    if (!file.isFile) continue;
    if (file.isSymbolicLink ||
        file.name.contains('\\') ||
        file.name.startsWith('/') ||
        file.name.split('/').any((s) => s == '..' || s == '.') ||
        files.containsKey(file.name)) {
      throw const FormatException('مسار غير صالح في الملف');
    }
    size += file.size;
    if (size > 300 * 1024 * 1024 || file.size > 50 * 1024 * 1024) {
      throw const FormatException('محتويات الملف كبيرة جدًا');
    }
    files[file.name] = Uint8List.fromList(file.content);
  }
  return files;
}

class CsvSpec {
  const CsvSpec(
    this.table,
    this.columns,
    this.keys, {
    this.moneyKeys = const {},
  });
  final String table;
  final List<String> columns;
  final List<String> keys;
  final Set<String> moneyKeys;
}

const csvSpecs = [
  CsvSpec(
    'products',
    [
      'Product_ID',
      'Product_Name',
      'Code',
      'Category',
      'Country_of_Origin',
      'Selling_Price',
      'Notes',
    ],
    ['id', 'name', 'code', 'category', 'country_of_origin', 'selling_price', 'notes'],
    moneyKeys: {'selling_price'},
  ),
  CsvSpec(
    'suppliers',
    ['Supplier_ID', 'Supplier_Name', 'Phone', 'Address', 'Notes'],
    ['id', 'name', 'phone', 'address', 'notes'],
  ),
  CsvSpec(
    'purchases',
    [
      'Purchase_ID',
      'Product_ID',
      'Supplier_ID',
      'Date',
      'Purchase_Price',
      'Notes',
    ],
    ['id', 'product_id', 'supplier_id', 'date', 'price', 'notes'],
    moneyKeys: {'price'},
  ),
];

const legacyCsvSpecs = [
  CsvSpec(
    'products',
    ['Product_ID', 'Product_Name', 'Code', 'Category', 'Selling_Price', 'Notes'],
    ['id', 'name', 'code', 'category', 'selling_price', 'notes'],
    moneyKeys: {'selling_price'},
  ),
  CsvSpec(
    'suppliers',
    ['Supplier_ID', 'Supplier_Name', 'Phone', 'WhatsApp', 'Address', 'Notes'],
    ['id', 'name', 'phone', 'whatsapp', 'address', 'notes'],
  ),
];

String csvEncode(List<List<String>> rows) => rows
    .map((row) => row.map((s) => '"${s.replaceAll('"', '""')}"').join(','))
    .join('\r\n');

List<List<String>> csvDecode(String input) {
  final source = input.replaceFirst(RegExp('^\uFEFF'), '');
  final rows = <List<String>>[];
  var row = <String>[];
  var cell = StringBuffer();
  var quoted = false;
  var closed = false;
  for (var i = 0; i < source.length; i++) {
    final c = source[i];
    if (c == '"') {
      if (quoted && i + 1 < source.length && source[i + 1] == '"') {
        cell.write('"');
        i++;
      } else if (quoted) {
        quoted = false;
        closed = true;
      } else if (cell.isEmpty && !closed) {
        quoted = true;
      } else {
        throw const FormatException('علامات اقتباس غير صحيحة في CSV');
      }
    } else if (c == ',' && !quoted) {
      row.add(cell.toString());
      cell = StringBuffer();
      closed = false;
    } else if ((c == '\r' || c == '\n') && !quoted) {
      if (c == '\r' && i + 1 < source.length && source[i + 1] == '\n') i++;
      row.add(cell.toString());
      rows.add(row);
      row = [];
      cell = StringBuffer();
      closed = false;
    } else {
      if (closed) throw const FormatException('نص بعد نهاية حقل CSV');
      cell.write(c);
    }
  }
  if (quoted) throw const FormatException('علامات اقتباس غير مكتملة في CSV');
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows.where((r) => r.any((c) => c.isNotEmpty)).toList();
}

class ImportPlan {
  ImportPlan(this.tables);
  final Map<String, List<DbRow>> tables;
  int get count => tables.values.fold(0, (sum, rows) => sum + rows.length);
}

ImportPlan parseCsvImport(Uint8List bytes, String filename) {
  final files = filename.toLowerCase().endsWith('.zip')
      ? decodeZip(bytes)
      : {filename: bytes};
  final tables = <String, List<DbRow>>{};
  for (final entry in files.entries.where(
    (e) => e.key.toLowerCase().endsWith('.csv'),
  )) {
    final rows = csvDecode(utf8.decode(entry.value));
    if (rows.isEmpty) continue;
    final header = rows.first.map((s) => s.trim()).toList();
    final matches = (csvSpecs + legacyCsvSpecs).where(
      (s) =>
          s.columns.length == header.length &&
          List.generate(
            header.length,
            (i) => header[i] == s.columns[i],
          ).every((b) => b),
    );
    if (matches.isEmpty) {
      throw FormatException('أعمدة ${entry.key} لا تطابق قالب التصدير');
    }
    final spec = matches.single;
    if (tables.containsKey(spec.table)) {
      throw const FormatException('جدول CSV مكرر');
    }
    final values = <DbRow>[];
    final ids = <String>{};
    for (var n = 1; n < rows.length; n++) {
      final cells = rows[n];
      if (cells.length != header.length) {
        throw FormatException('عدد أعمدة غير صحيح في السطر ${n + 1}');
      }
      final row = <String, Object?>{};
      for (var i = 0; i < cells.length; i++) {
        final key = spec.keys[i];
        final value = cells[i].trim();
        row[key] = spec.moneyKeys.contains(key) ? money(value) : value;
      }
      final id = row['id'] as String;
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id) || !ids.add(id)) {
        throw FormatException('معرّف غير صالح أو مكرر في السطر ${n + 1}');
      }
      if (row.containsKey('name') && (row['name'] as String).isEmpty) {
        throw FormatException('الاسم مطلوب في السطر ${n + 1}');
      }
      if (spec.table == 'purchases') {
        if (row['price'] == null ||
            row['product_id'] == '' ||
            row['supplier_id'] == '') {
          throw FormatException('بيانات شراء ناقصة في السطر ${n + 1}');
        }
        if (row['date'] == '') {
          row['date'] = null;
        } else if (!validDate(row['date'] as String)) {
          throw FormatException('تاريخ غير صحيح في السطر ${n + 1}');
        }
      }
      values.add(row);
    }
    tables[spec.table] = values;
  }
  final plan = ImportPlan(tables);
  if (plan.count == 0) {
    throw const FormatException('لا توجد بيانات CSV قابلة للاستيراد');
  }
  if (plan.count > 20000) {
    throw const FormatException('الحد الأقصى للاستيراد 20 ألف صف');
  }
  return plan;
}
