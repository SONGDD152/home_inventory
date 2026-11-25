// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/home_inventory.dart';

/// V3.11「按位置记数量」专项测试（元宝技术审核九条必做项的 1/2/4/5/6/7/8）。
/// 用真实 sqlite 覆盖数据层，假仓储不算数——地基语义出错必须由真实库兜住。
void main() {
  setUpAll(() => sqfliteFfiInit());

  late Directory tempDir;
  late InventoryDatabase db;
  late List<InventoryDatabase> opened;

  InventoryDatabase newDb({String name = 'inventory.db'}) {
    final instance = InventoryDatabase(
      databaseFactory: databaseFactoryFfi,
      databasePath: p.join(tempDir.path, name),
    );
    opened.add(instance);
    return instance;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('home_inventory_v311_');
    opened = <InventoryDatabase>[];
    db = newDb();
    await db.open();
  });

  tearDown(() async {
    for (final instance in opened) {
      try {
        await instance.close();
      } catch (_) {
        // 迁移失败用例可能已自行关库。
      }
    }
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 全局不变式（元宝第 6 条）：items.quantity == SUM(活跃位置数量)。
  Future<void> expectInvariant() async {
    final database = await db.open();
    final items = await database.query(
      'items',
      columns: <String>['id', 'name', 'quantity'],
      where: 'is_deleted = 0',
    );
    for (final row in items) {
      final sums = await database.rawQuery(
        'SELECT COALESCE(SUM(quantity), 0) AS total FROM item_locations '
        'WHERE item_id = ? AND is_deleted = 0',
        <Object?>[row['id']],
      );
      expect(
        (sums.first['total'] as num?)?.toInt(),
        (row['quantity'] as num?)?.toInt(),
        reason: '「${row['name']}」在库数必须等于各位置数量之和',
      );
    }
  }

  Future<ItemWithLocations> find(String name) async {
    final found = await db.findByName(name);
    expect(found, isNotNull, reason: '「$name」应当已录入');
    return found!;
  }

  /// 造一件两位置物品：阳台 2、客厅 1（PM 真机现象的场景底稿）。
  Future<(int, int)> seedTwoLocations() async {
    final balcony = await db.addLocation('阳台');
    final living = await db.addLocation('客厅');
    await db.upsertItemLocation('梯子', balcony, quantity: 2);
    await db.upsertItemLocation('梯子', living, quantity: 1);
    return (balcony, living);
  }

  test('按位置记数量：覆盖/累加只动目标位置，总数守恒', () async {
    final (balcony, living) = await seedTwoLocations();
    var found = await find('梯子');
    expect(found.quantityAt(balcony), 2);
    expect(found.quantityAt(living), 1);
    expect(found.item.quantity, 3);

    await db.upsertItemLocation('梯子', balcony, quantity: 1, additive: true);
    found = await find('梯子');
    expect(found.quantityAt(balcony), 3, reason: '累加只加目标位置');
    expect(found.quantityAt(living), 1, reason: '没说的位置不许被动');
    expect(found.item.quantity, 4);
    await expectInvariant();
  });

  test('整体挪 moveItemWhole：旧位置软删、目标拿全部、总数不变', () async {
    final (_, living) = await seedTwoLocations();
    final result = await db.moveItemWhole('梯子', living);
    expect(result.previousLocations, <String>['阳台']);
    expect(result.quantity, 3);

    final found = await find('梯子');
    expect(found.locations.map((l) => l.name), <String>['客厅']);
    expect(found.quantityAt(living), 3);
    expect(found.item.quantity, 3, reason: '整体挪不覆盖总数');
    await expectInvariant();
  });

  test('部分挪 moveItemPartial：源减目标加、总数不变（PM 现象②正解）', () async {
    final (balcony, living) = await seedTwoLocations();
    final result = await db.moveItemPartial('梯子', balcony, living, quantity: 2);
    expect(result.quantity, 3);
    expect(result.quantityChanged, isFalse);

    final found = await find('梯子');
    expect(found.quantityAt(balcony), 0);
    expect(found.quantityAt(living), 3);
    expect(found.item.quantity, 3, reason: '挪 2 个不能把总数从 3 改成 1');
    await expectInvariant();
  });

  test('部分挪源位不足：抛中文提示，且不改任何数量', () async {
    final (balcony, living) = await seedTwoLocations();
    late String message;
    try {
      await db.moveItemPartial('梯子', balcony, living, quantity: 9);
      fail('源位只有 2 个，不该静默挪走');
    } on ArgumentError catch (e) {
      message = e.message.toString();
    }
    expect(message, contains('阳台只有 2 个'));
    expect(message, contains('不够挪 9 个'));

    final found = await find('梯子');
    expect(found.quantityAt(balcony), 2);
    expect(found.quantityAt(living), 1);
    expect(found.item.quantity, 3);
    await expectInvariant();
  });

  test('借出按来源位扣、归还加指定位：阳台不再被整体搬走（PM 现象①）', () async {
    final (balcony, living) = await seedTwoLocations();
    final loan = await db.lendItem('梯子', '张三',
        quantity: 1, fromLocationId: balcony);
    var found = await find('梯子');
    expect(found.quantityAt(balcony), 1, reason: '从阳台借走 1 个');
    expect(found.quantityAt(living), 1, reason: '客厅不能被动');
    expect(found.item.quantity, 2);

    await db.returnLoan(loan.id!, quantity: 1, toLocationId: living);
    found = await find('梯子');
    expect(found.quantityAt(balcony), 1, reason: '还到客厅不该删阳台');
    expect(found.quantityAt(living), 2, reason: '归还的 1 个加在客厅');
    expect(found.item.quantity, 3);
    await expectInvariant();
  });

  test('废弃再恢复：每个位置的数量原样还原（元宝第 5 条）', () async {
    final (balcony, living) = await seedTwoLocations();
    final id = (await find('梯子')).item.id!;
    await db.deleteItem(id);
    await db.restoreItem(id);

    final found = await find('梯子');
    expect(found.quantityAt(balcony), 2);
    expect(found.quantityAt(living), 1);
    expect(found.item.quantity, 3);
    await expectInvariant();
  });

  test('合并恢复：同位置数量相加，不同位置各自保留', () async {
    final balcony = await db.addLocation('阳台');
    final living = await db.addLocation('客厅');
    await db.upsertItemLocation('梯子', balcony, quantity: 2);
    await db.upsertItemLocation('梯子', living, quantity: 1);
    final deletedId = (await find('梯子')).item.id!;
    await db.deleteItem(deletedId);

    // 明细里又录了一件同名梯子，只有阳台 1 个。
    await db.upsertItemLocation('梯子', balcony, quantity: 1);
    final outcome = await db.restoreItem(deletedId);
    expect(outcome.merged, isTrue);

    final found = await find('梯子');
    expect(found.quantityAt(balcony), 3, reason: '阳台 1 + 阳台 2 = 3');
    expect(found.quantityAt(living), 1, reason: '客厅只剩恢复带来的那 1 个');
    expect(found.item.quantity, 4);
    await expectInvariant();
  });

  test('校准页按位置分别清点，支持新增位置行（元宝第 7 条）', () async {
    final (balcony, living) = await seedTwoLocations();
    final itemId = (await find('梯子')).item.id!;
    final garage = await db.addLocation('车库');
    await db.calibrateQuantities(locationTotals: <int, Map<int, int>>{
      itemId: <int, int>{balcony: 4, living: 2, garage: 1},
    });

    final found = await find('梯子');
    expect(found.quantityAt(balcony), 4);
    expect(found.quantityAt(living), 2);
    expect(found.quantityAt(garage), 1);
    expect(found.item.quantity, 7);
    await expectInvariant();
  });

  test('备份恢复：v9 位置数量原样、v8 老备份按迁移口径收口', () async {
    final (balcony, living) = await seedTwoLocations();
    final backup = await db.exportBackup();
    final fresh = newDb(name: 'restore.db');
    await fresh.restoreBackup(backup);
    final restored = await fresh.findByName('梯子');
    expect(restored, isNotNull);
    expect(restored!.quantityAt(balcony), 2);
    expect(restored.quantityAt(living), 1);

    // v8 备份没有位置数量列，总数 4 按平均+余数给主位置分配。
    final v8 = Map<String, Object?>.from(backup);
    v8['schemaVersion'] = 8;
    v8['item_locations'] = (backup['item_locations'] as List<Object?>)
        .map((raw) => Map<String, Object?>.from(raw as Map<String, Object?>)
          ..remove('quantity'))
        .toList();
    final itemRows = (v8['items'] as List<Object?>)
        .map((raw) => Map<String, Object?>.from(raw as Map<String, Object?>))
        .toList();
    itemRows.first['quantity'] = 4;
    v8['items'] = itemRows;

    await db.restoreBackup(v8);
    final legacyRestored = await find('梯子');
    // 4 个平分到 2 个位置，余数 0 → 2/2（不是 3/1）。
    expect(legacyRestored.quantityAt(balcony), 2);
    expect(legacyRestored.quantityAt(living), 2);
    expect(legacyRestored.item.quantity, 4);
    await expectInvariant();
  });

  test('v8→v9 迁移：逐物品双向对账（元宝第 2 条）', () async {
    final legacyPath = p.join(tempDir.path, 'legacy_v8.db');
    final now = DateTime.now().millisecondsSinceEpoch;
    final raw = await databaseFactoryFfi.openDatabase(
      legacyPath,
      options: OpenDatabaseOptions(
        version: 8,
        onCreate: (database, version) async {
          await database.execute(
            'CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, '
            'is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, '
            'updated_at INTEGER NOT NULL, deleted_at INTEGER, quantity INTEGER NOT NULL DEFAULT 1)',
          );
          await database.execute(
            'CREATE TABLE locations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, '
            'is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, '
            'updated_at INTEGER NOT NULL, remark TEXT)',
          );
          await database.execute(
            'CREATE TABLE item_locations (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, '
            'location_id INTEGER NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, '
            'created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, raw_text TEXT, tags TEXT)',
          );
          for (final name in <String>['阳台', '客厅', '车库']) {
            await database.insert('locations', <String, Object?>{
              'name': name,
              'is_deleted': 0,
              'created_at': now,
              'updated_at': now,
            });
          }
          for (final entry in <Map<String, Object?>>[
            <String, Object?>{'name': '梯子', 'quantity': 5},
            <String, Object?>{'name': '螺丝', 'quantity': 2},
            <String, Object?>{'name': '充电线', 'quantity': 3},
          ]) {
            await database.insert('items', <String, Object?>{
              'name': entry['name'],
              'quantity': entry['quantity'],
              'is_deleted': 0,
              'created_at': now,
              'updated_at': now,
            });
          }
          // 梯子两处、螺丝一处、充电线三处。
          for (final link in <Map<String, Object?>>[
            <String, Object?>{'item_id': 1, 'location_id': 1},
            <String, Object?>{'item_id': 1, 'location_id': 2},
            <String, Object?>{'item_id': 2, 'location_id': 1},
            <String, Object?>{'item_id': 3, 'location_id': 1},
            <String, Object?>{'item_id': 3, 'location_id': 2},
            <String, Object?>{'item_id': 3, 'location_id': 3},
          ]) {
            await database.insert('item_locations', <String, Object?>{
              ...link,
              'is_deleted': 0,
              'created_at': now,
              'updated_at': now,
            });
          }
        },
      ),
    );
    await raw.close();

    final migrating = newDb(name: 'legacy_v8.db');
    await migrating.open();

    // 逐件双向对账：迁移前 items.quantity == 迁移后 SUM(位置数量)，
    // 且 items.quantity 自身未被改动。按位置 id 断言，不依赖查询排序。
    final locs = await migrating.getAllLocations();
    int locId(String name) => locs.firstWhere((l) => l.name == name).id!;
    for (final entry in <Map<String, Object>>[
      <String, Object>{
        'name': '梯子',
        'total': 5,
        'expected': <int>[3, 2],
        'locations': <String>['阳台', '客厅'],
      },
      <String, Object>{
        'name': '螺丝',
        'total': 2,
        'expected': <int>[2],
        'locations': <String>['阳台'],
      },
      <String, Object>{
        'name': '充电线',
        'total': 3,
        'expected': <int>[1, 1, 1],
        'locations': <String>['阳台', '客厅', '车库'],
      },
    ]) {
      final name = entry['name'] as String;
      final found = await migrating.findByName(name);
      expect(found, isNotNull, reason: '$name 迁移后不能丢');
      final names = entry['locations'] as List<String>;
      final expected = entry['expected'] as List<int>;
      for (var i = 0; i < names.length; i++) {
        expect(found!.quantityAt(locId(names[i])), expected[i],
            reason: '$name 在${names[i]}按平均+余数给主位置分配');
      }
      final quantities = found!.locationQuantities.values;
      expect(quantities.fold<int>(0, (a, b) => a + b), entry['total'],
          reason: '$name 位置数量之和必须等于迁移前在库数');
      expect(found.item.quantity, entry['total'],
          reason: '$name 迁移不得改动 items.quantity');
    }
  });

  test('全操作序列后逐件校验全局不变式（元宝第 6 条）', () async {
    final balcony = await db.addLocation('阳台');
    final living = await db.addLocation('客厅');
    await db.upsertItemLocation('梯子', balcony, quantity: 3);
    await db.upsertItemLocation('梯子', living, quantity: 1);
    await db.upsertItemLocation('螺丝', balcony, quantity: 2);
    await db.moveItemPartial('梯子', balcony, living, quantity: 1);
    final loan = await db.lendItem('梯子', '张三',
        quantity: 1, fromLocationId: living);
    await db.returnLoan(loan.id!, quantity: 1, toLocationId: balcony);
    await db.setItemQuantity('螺丝', 4);
    final ladderId = (await find('梯子')).item.id!;
    await db.deleteItem(ladderId);
    await db.restoreItem(ladderId);
    await db.calibrateQuantities(locationTotals: <int, Map<int, int>>{
      ladderId: <int, int>{balcony: 3, living: 1},
    });
    await expectInvariant();
  });
}
