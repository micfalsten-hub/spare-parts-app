import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spare_parts/data.dart';
import 'package:sqflite/sqflite.dart';

// Exercise the actual sqflite plugin factory, not desktop SQLite FFI. Android
// execSQL rejects statements that return rows, even though SQLite FFI accepts
// executing PRAGMA journal_mode=DELETE without reading its returned value.
const _channel = MethodChannel('com.tekartik.sqflite');

class _AndroidDatabaseChannel {
  int userVersion = 0;
  int opens = 0;
  bool failCatalogQuery = false;
  final calls = <MethodCall>[];
  final closedIds = <int>[];
  final productRows = <DbRow>[];
  final supplierRows = <DbRow>[];
  final purchaseRows = <DbRow>[];

  String sqlOf(MethodCall call) =>
      '${(call.arguments as Map?)?['sql'] ?? ''}'
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim()
          .toUpperCase();

  List<String> get createdTables => calls
      .where((call) => call.method == 'execute')
      .map(sqlOf)
      .where((sql) => sql.startsWith('CREATE TABLE '))
      .toList();

  Object rows(List<DbRow> values) {
    if (values.isEmpty) {
      return <String, Object?>{'columns': <String>[], 'rows': <Object?>[]};
    }
    final columns = values.first.keys.toList();
    return <String, Object?>{
      'columns': columns,
      'rows': values
          .map((row) => columns.map((column) => row[column]).toList())
          .toList(),
    };
  }

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final arguments = call.arguments as Map?;
    final sql = sqlOf(call);
    switch (call.method) {
      case 'openDatabase':
        opens += 1;
        return <String, Object?>{'id': opens};
      case 'closeDatabase':
        closedIds.add(arguments!['id'] as int);
        return null;
      case 'execute':
        if (sql.startsWith('PRAGMA JOURNAL_MODE')) {
          throw PlatformException(
            code: 'sqlite_error',
            message:
                'Queries can be performed using SQLiteDatabase query or rawQuery methods only.',
            details: <String, Object?>{'sql': arguments!['sql']},
          );
        }
        if (sql.startsWith('PRAGMA USER_VERSION = ')) {
          userVersion = int.parse(sql.split('=').last.trim());
        }
        if (sql.startsWith('BEGIN ')) {
          return <String, Object?>{'transactionId': opens};
        }
        return null;
      case 'query':
        if (sql == 'PRAGMA USER_VERSION') {
          return rows(<DbRow>[
            <String, Object?>{'user_version': userVersion},
          ]);
        }
        if (sql == 'PRAGMA JOURNAL_MODE=DELETE' ||
            sql == 'PRAGMA JOURNAL_MODE = DELETE') {
          return rows(<DbRow>[
            <String, Object?>{'journal_mode': 'delete'},
          ]);
        }
        if (sql.contains('FROM TRASH')) return rows(<DbRow>[]);
        if (sql.contains('FROM PRODUCTS P ')) {
          if (failCatalogQuery) {
            throw PlatformException(
              code: 'sqlite_error',
              message: 'Simulated failure while reading the initial catalog',
            );
          }
          return rows(productRows);
        }
        if (sql.contains('FROM SUPPLIERS S ')) return rows(supplierRows);
        if (sql.contains('FROM PURCHASES B ')) return rows(purchaseRows);
        throw StateError('Unexpected sqflite query: $sql');
      default:
        throw StateError('Unexpected sqflite method: ${call.method}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Store store;
  late _AndroidDatabaseChannel android;
  DatabaseFactory? originalFactory;

  setUp(() async {
    originalFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactorySqflitePlugin;
    android = _AndroidDatabaseChannel();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, android.handle);
    dir = await Directory.systemTemp.createTemp('daftar-android-startup-');
    store = Store(dir);
  });

  tearDown(() async {
    // The plugin closes failed opens. Allow cleanup after any regression
    // assertion fails, including failures before Store receives a handle.
    try {
      await store.close();
    } catch (_) {}
    store.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    databaseFactory = originalFactory;
    await dir.delete(recursive: true);
  });

  test('fresh Android open reads the journal result before creating tables', () async {
    await store.open();

    expect(store.factory, same(databaseFactorySqflitePlugin));
    expect(store.db.isOpen, isTrue);
    expect(android.userVersion, appDatabaseVersion);
    expect(android.createdTables, hasLength(4));
    expect(store.products, isEmpty);
    expect(store.suppliers, isEmpty);
    expect(store.purchases, isEmpty);

    final journalQueries = android.calls.where(
      (call) =>
          call.method == 'query' &&
          android.sqlOf(call).startsWith('PRAGMA JOURNAL_MODE'),
    );
    expect(journalQueries, hasLength(1));
    final journalPosition = android.calls.indexOf(journalQueries.single);
    final firstCreatePosition = android.calls.indexWhere(
      (call) => android.sqlOf(call).startsWith('CREATE TABLE '),
    );
    expect(journalPosition, lessThan(firstCreatePosition));
    expect(
      android.calls.any(
        (call) =>
            call.method == 'execute' &&
            android.sqlOf(call).startsWith('PRAGMA JOURNAL_MODE'),
      ),
      isFalse,
    );
  });

  test('existing Android version 1 opens without recreating or deleting data', () async {
    android.userVersion = 1;
    android.productRows.add(<String, Object?>{
      'id': 'existing-product',
      'name': 'قطعة محفوظة',
      'selling_price': 95000,
      'image': 'existing.png',
      'latest_date': null,
    });
    android.supplierRows.add(<String, Object?>{
      'id': 'existing-supplier',
      'name': 'مورد محفوظ',
    });
    android.purchaseRows.add(<String, Object?>{
      'id': 'existing-purchase',
      'product_id': 'existing-product',
      'supplier_id': 'existing-supplier',
      'date': null,
      'price': 72000,
    });
    await store.imageDir.create(recursive: true);
    final databaseFile = File(store.dbPath);
    final imageFile = File(store.imagePath('existing.png'));
    const databaseSentinel = <int>[83, 81, 76, 105, 116, 101];
    const imageSentinel = <int>[137, 80, 78, 71];
    await databaseFile.writeAsBytes(databaseSentinel);
    await imageFile.writeAsBytes(imageSentinel);

    await store.open();
    await store.close();
    await store.open();

    expect(android.opens, 2);
    expect(
      android.createdTables.where((sql) =>
          sql.startsWith('CREATE TABLE PRODUCTS') ||
          sql.startsWith('CREATE TABLE SUPPLIERS') ||
          sql.startsWith('CREATE TABLE PURCHASES')),
      isEmpty,
    );
    expect(android.createdTables, hasLength(1));
    expect(store.products.single['name'], 'قطعة محفوظة');
    expect(store.suppliers.single['name'], 'مورد محفوظ');
    expect(store.purchases.single['date'], isNull);
    expect(await databaseFile.readAsBytes(), databaseSentinel);
    expect(await imageFile.readAsBytes(), imageSentinel);
    expect(
      android.calls.any(
        (call) =>
            call.method == 'deleteDatabase' ||
            android.sqlOf(call).startsWith('DROP '),
      ),
      isFalse,
    );
  });

  test('failed initial refresh closes the Android handle and allows retry', () async {
    android.userVersion = 1;
    android.failCatalogQuery = true;

    await expectLater(store.open(), throwsA(isA<DatabaseException>()));
    expect(android.closedIds, <int>[1]);
    expect(() => store.db, throwsStateError);

    android.failCatalogQuery = false;
    await store.open();
    expect(android.opens, 2);
    expect(store.db.isOpen, isTrue);
    expect(android.createdTables, hasLength(1));
    expect(android.createdTables.single, startsWith('CREATE TABLE TRASH'));
    expect(store.products, isEmpty);
  });
}
