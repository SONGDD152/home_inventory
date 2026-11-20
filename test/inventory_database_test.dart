import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/home_inventory.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;
  late String dbPath;
  late InventoryDatabase db;
  late List<InventoryDatabase> opened;

  InventoryDatabase newDb({int version = 3, String? path}) {
    final instance = InventoryDatabase(
      databaseFactory: databaseFactoryFfi,
      databasePath: path ?? dbPath,
      version: version,
    );
    opened.add(instance);
    return instance;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('home_inventory_test_');
    dbPath = p.join(tempDir.path, 'inventory.db');
    opened = <InventoryDatabase>[];
    db = newDb();
  });

  tearDown(() async {
    for (final instance in opened) {
      await instance.close();
    }
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// 录入一件物品到一个位置，返回关联结果。
  Future<UpsertResult> put(String item, String location) async {
    final locationId = await db.addLocation(location);
    return db.upsertItemLocation(item, locationId);
  }

  // ---- 基础：空库 / 重开 ----

  test('空库查询：无物品、无位置、无关联', () async {
    expect(await db.getAllItems(), isEmpty);
    expect(await db.getAllLocations(), isEmpty);
    expect(await db.countActiveAssociations(), 0);
    expect(await db.findByName('梯子'), isNull);
  });

  test('重开临时文件库后仍能查到（且确认 dispose 了连接）', () async {
    await put('梯子', '阳台');
    expect(db.isOpen, isTrue);

    await db.close();
    expect(db.isOpen, isFalse);

    final reopened = newDb();
    expect(identical(reopened, db), isFalse);
    expect(reopened.isOpen, isFalse);

    final found = await reopened.findByName('梯子');
    expect(reopened.isOpen, isTrue);
    expect(found, isNotNull);
    expect(found!.item.name, '梯子');
    expect(found.locations.map((e) => e.name), contains('阳台'));
  });

  // ---- 三张表：多对多 ----

  test('一物放多处：同一物品关联多个位置，全量列出', () async {
    final balcony = await db.addLocation('阳台');
    final storage = await db.addLocation('储物间');
    await db.upsertItemLocation('梯子', balcony);
    await db.upsertItemLocation('梯子', storage);

    final found = await db.findByName('梯子');
    expect(found, isNotNull);
    expect(found!.locations.map((e) => e.name), containsAll(<String>['阳台', '储物间']));
    expect(await db.countActiveAssociations(), 2);
    // 物品表只此一件，位置表两处。
    expect(await db.getAllItems(), hasLength(1));
    expect(await db.getAllLocations(), hasLength(2));
  });

  test('一处放多物：多个物品共享一个位置', () async {
    final balcony = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', balcony);
    await db.upsertItemLocation('园艺剪', balcony);

    expect((await db.findByName('梯子'))!.locations.single.name, '阳台');
    expect((await db.findByName('园艺剪'))!.locations.single.name, '阳台');
    expect(await db.getAllLocations(), hasLength(1));
  });

  // ---- 幂等 / 并发 ----

  test('连点两下只产生一条关联，第二次 created=false', () async {
    final first = await put('梯子', '阳台');
    expect(first.created, isTrue);

    final second = await put('梯子', '阳台');
    expect(second.created, isFalse);
    expect(second.itemId, first.itemId);
    expect(second.locationId, first.locationId);

    expect(await db.countActiveAssociations(), 1);
    expect(await db.getAllItems(), hasLength(1));
  });

  test('并发重复插入同一(物品,位置)只留一条', () async {
    final locationId = await db.addLocation('阳台');
    // 同时发起 8 个相同录入：三个表的唯一约束 + 事务串行化保证幂等。
    final results = await Future.wait<UpsertResult>(
      List<Future<UpsertResult>>.generate(
        8,
        (_) => db.upsertItemLocation('梯子', locationId),
      ),
    );
    expect(results.where((r) => r.created).length, 1);
    expect(await db.countActiveAssociations(), 1);
    expect(await db.getAllItems(), hasLength(1));
    expect(await db.getAllLocations(), hasLength(1));
  });

  // ---- 参数校验 ----

  test('空名称被拒绝', () async {
    final locationId = await db.addLocation('阳台');
    expect(
      db.upsertItemLocation('', locationId),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      db.upsertItemLocation('   ', locationId),
      throwsA(isA<ArgumentError>()),
    );
    expect(await db.countActiveAssociations(), 0);
  });

  test('超长位置被拒绝（阈值 100）', () async {
    final tooLong = '位' * (InventoryDatabase.maxNameLength + 1);
    expect(db.addLocation(tooLong), throwsA(isA<ArgumentError>()));
    expect(await db.getAllLocations(), isEmpty);
  });

  test('trim 首尾空白后入库与查询一致', () async {
    final locationId = await db.addLocation('  阳台  ');
    expect((await db.getLocationById(locationId))!.name, '阳台');
    await db.upsertItemLocation('  梯子  ', locationId);
    // 两边都带空白查询，trim 后命中。
    final found = await db.findByName('  梯子  ');
    expect(found, isNotNull);
    expect(found!.item.name, '梯子');
    expect((await db.getAllLocations()).single.name, '阳台');
  });

  // ---- 精确匹配 ----

  test('精确名称：查「梯」找不到「梯子」', () async {
    await put('梯子', '阳台');
    expect(await db.findByName('梯'), isNull);
    expect(await db.findByName('梯子'), isNotNull);
  });

  // ---- 软删除 ----

  test('位置软删除后不再出现在查询里', () async {
    final balconyId = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', balconyId);

    final db2 = db; // 通过原始 SQL 软删位置，验证查询侧过滤。
    final database = await db2.open();
    await database.update(
      InventoryDatabase.tableLocations,
      <String, Object?>{InventoryDatabase.columnIsDeleted: 1},
      where: '${InventoryDatabase.columnId} = ?',
      whereArgs: <Object?>[balconyId],
    );

    expect(await db.getAllLocations(), isEmpty);
    final found = await db.findByName('梯子');
    expect(found!.locations, isEmpty);
  });

  // ---- 数据库层兜底：唯一约束 ----

  test('绕过幂等方法直接插重复关联被唯一索引拒绝', () async {
    final locationId = await db.addLocation('阳台');
    final itemId = (await db.upsertItemLocation('梯子', locationId)).itemId;
    final database = await db.open();
    expect(
      database.insert(
        InventoryDatabase.tableItemLocations,
        ItemLocation(
          itemId: itemId,
          locationId: locationId,
          createdAt: 1,
          updatedAt: 1,
        ).toMap(),
      ),
      throwsA(isA<DatabaseException>()),
    );
  });

  // ---- 升级迁移：v2 单表 → v3 三张表 ----

  test('v2 单表库升级到 v3，旧数据迁成物品+位置+关联', () async {
    final v2Path = p.join(tempDir.path, 'v2.db');
    final v2db = await databaseFactoryFfi.openDatabase(
      v2Path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE items (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              location TEXT NOT NULL,
              is_deleted INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await database.execute(
            'INSERT INTO items(name, location, created_at, updated_at) '
            "VALUES('螺丝刀', '工具箱', 1, 1)",
          );
        },
      ),
    );
    await v2db.close(); // 必须关闭，否则 v3 打开会卡在旧连接上。

    final upgraded = newDb(version: 3, path: v2Path);
    final found = await upgraded.findByName('螺丝刀');
    expect(found, isNotNull);
    expect(found!.locations.single.name, '工具箱');
    expect(await upgraded.countActiveAssociations(), 1);
  });
}
