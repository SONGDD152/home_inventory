import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/home_inventory.dart';
import 'package:home_inventory/data/phrase_parser.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;
  late String dbPath;
  late InventoryDatabase db;
  late List<InventoryDatabase> opened;

  // 默认 version=4，与生产对齐；全新装库走 onCreate，显式低版本的迁移测试另行指定。
  InventoryDatabase newDb({int version = 4, String? path}) {
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

  test('精确名称：查「梯」找不到「梯子」，「梯子」也匹配不到「梯子架」', () async {
    await put('梯子', '阳台');
    await put('梯子架', '储物间');
    expect(await db.findByName('梯'), isNull);
    final found = await db.findByName('梯子');
    expect(found, isNotNull);
    expect(found!.item.name, '梯子');
    expect(found.locations.single.name, '阳台'); // 不能混进「梯子架」的位置
  });

  test('归一化后仍精确：「  梯子 」命中「梯子」，不误命中「梯子架」', () async {
    await put('梯子', '阳台');
    await put('梯子架', '储物间');
    final bySpaced = await db.findByName('  梯子  ');
    expect(bySpaced, isNotNull);
    expect(bySpaced!.item.name, '梯子');
    expect(bySpaced.locations, hasLength(1));
    expect(bySpaced.locations.single.name, '阳台');
    expect(await db.findByName('梯 子'), isNull); // 中间插空格不为同源
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

  // ---- 归一化同源（V1 规则：仓储边界单一入口）----

  test('跨路径同源：直录带空格与解析结果落库只一条，双向查询都命中', () async {
    // 路径 A：UI 文本框原文直录（带尾空格）
    final uiLocationId = await db.addLocation('阳台');
    final uiResult = await db.upsertItemLocation('梯子 ', uiLocationId);

    // 路径 B：句式解析输出（parsePhrase 只收字符串、不改库）
    final parsed = parsePhrase('梯子放阳台');
    expect(parsed, isA<ParseUpsert>());
    final p = parsed as ParseUpsert;
    final parsedLocationId = await db.addLocation(p.location);
    final parsedResult = await db.upsertItemLocation(p.item, parsedLocationId);

    // 两条路径归一化为同一物品、同一位置、同一关联
    expect(parsedResult.created, isFalse);
    expect(parsedResult.itemId, uiResult.itemId);
    expect(parsedResult.locationId, uiResult.locationId);
    expect(await db.getAllItems(), hasLength(1));
    expect(await db.getAllLocations(), hasLength(1));
    expect(await db.countActiveAssociations(), 1);

    // findByName 两个方向都查得回来，归一化值完全相等
    final bySpaced = await db.findByName('梯子 ');
    final byPlain = await db.findByName('梯子');
    expect(bySpaced, isNotNull);
    expect(byPlain, isNotNull);
    expect(bySpaced!.item.name, byPlain!.item.name);
    expect(byPlain.item.name, '梯子');
  });

  test('全角与大小写变体落库同源，归一化后按标准名查询命中', () async {
    final locationId = await db.addLocation('　阳台　'); // 全角空格包裹
    await db.upsertItemLocation('ＬＡＤＤＥＲ', locationId); // 全角大写

    expect(await db.getAllItems(), hasLength(1));
    final found = await db.findByName('ladder'); // 半角小写查询
    expect(found, isNotNull);
    expect(found!.item.name, 'ladder');
    expect(found.locations.single.name, '阳台');
  });

  // ---- 升级迁移：v3 脏数据 → v4 归一化清洗 ----

  test('v3 历史非归一化数据升级到 v4 后归一化并合并同名', () async {
    final v3Path = p.join(tempDir.path, 'v3_dirty.db');
    final v3db = await databaseFactoryFfi.openDatabase(
      v3Path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE items (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              is_deleted INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE locations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              is_deleted INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE item_locations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              item_id INTEGER NOT NULL,
              location_id INTEGER NOT NULL,
              is_deleted INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          // 历史脏数据：物品名带尾空格、全角；位置名全角空格包裹
          await database.execute(
            "INSERT INTO items(name, created_at, updated_at) VALUES('梯子 ', 1, 1)",
          );
          await database.execute(
            "INSERT INTO items(name, created_at, updated_at) VALUES('梯子', 1, 1)",
          );
          await database.execute(
            "INSERT INTO locations(name, created_at, updated_at) VALUES('　阳台　', 1, 1)",
          );
          await database.execute(
            'INSERT INTO item_locations(item_id, location_id, created_at, updated_at) '
            'VALUES(1, 1, 1, 1)',
          );
          await database.execute(
            'INSERT INTO item_locations(item_id, location_id, created_at, updated_at) '
            'VALUES(2, 1, 1, 1)',
          );
        },
      ),
    );
    await v3db.close(); // 关闭旧连接，否则 v4 打开会卡在旧连接上。

    final upgraded = newDb(version: 4, path: v3Path);
    final found = await upgraded.findByName('梯子');
    expect(found, isNotNull);
    expect(found!.item.name, '梯子');
    expect(found.locations.single.name, '阳台');
    // 两个「梯子」合并为一条物品；两条关联合并为一条
    expect(await upgraded.getAllItems(), hasLength(1));
    expect(await upgraded.getAllLocations(), hasLength(1));
    expect(await upgraded.countActiveAssociations(), 1);
  });

  test('v3 撞名合并不丢关联：两条「梯子」指向不同位置，重指后两处都保留', () async {
    final v3Path = p.join(tempDir.path, 'v3_merge.db');
    final v3db = await databaseFactoryFfi.openDatabase(
      v3Path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE items (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              is_deleted INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE locations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              is_deleted INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE item_locations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              item_id INTEGER NOT NULL,
              location_id INTEGER NOT NULL,
              is_deleted INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          // 两个「梯子」（id 1 带尾空格、id 2 标准），两个不同位置
          await database.execute(
            "INSERT INTO items(name, created_at, updated_at) VALUES('梯子 ', 1, 1)",
          );
          await database.execute(
            "INSERT INTO items(name, created_at, updated_at) VALUES('梯子', 1, 1)",
          );
          await database.execute(
            "INSERT INTO locations(name, created_at, updated_at) VALUES('阳台', 1, 1)",
          );
          await database.execute(
            "INSERT INTO locations(name, created_at, updated_at) VALUES('厨房', 1, 1)",
          );
          // id=1 的「梯子 」→阳台；id=2 的「梯子」→厨房（不同位置）
          await database.execute(
            'INSERT INTO item_locations(item_id, location_id, created_at, updated_at) '
            'VALUES(1, 1, 1, 1)',
          );
          await database.execute(
            'INSERT INTO item_locations(item_id, location_id, created_at, updated_at) '
            'VALUES(2, 2, 1, 1)',
          );
        },
      ),
    );
    await v3db.close();

    final upgraded = newDb(version: 4, path: v3Path);
    final found = await upgraded.findByName('梯子');
    expect(found, isNotNull);
    // 物品合并成一条，但两处位置的关联都必须保留（重指到同一物品 id）
    expect(await upgraded.getAllItems(), hasLength(1));
    expect(await upgraded.countActiveAssociations(), 2);
    expect(found!.locations.map((e) => e.name), containsAll(<String>['阳台', '厨房']));
  });

  test('迁移失败整体回滚：清表后抛异常，库退回 v3 且旧数据不丢', () async {
    final v3Path = p.join(tempDir.path, 'v3_rollback.db');
    final v3db = await databaseFactoryFfi.openDatabase(
      v3Path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE items (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              is_deleted INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE locations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              is_deleted INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE item_locations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              item_id INTEGER NOT NULL,
              location_id INTEGER NOT NULL,
              is_deleted INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await database.execute(
            "INSERT INTO items(name, created_at, updated_at) VALUES('梯子 ', 1, 1)",
          );
          await database.execute(
            "INSERT INTO locations(name, created_at, updated_at) VALUES('阳台', 1, 1)",
          );
          await database.execute(
            'INSERT INTO item_locations(item_id, location_id, created_at, updated_at) '
            'VALUES(1, 1, 1, 1)',
          );
        },
      ),
    );
    await v3db.close();

    // 带失败钩子打开 v4：清表后抛异常，onUpgrade 事务应整体回滚
    final failing = InventoryDatabase(
      databaseFactory: databaseFactoryFfi,
      databasePath: v3Path,
      version: 4,
      migrationFailureHook: () => throw StateError('injected migration failure'),
    );
    opened.add(failing);
    await expectLater(failing.open(), throwsA(isA<StateError>()));

    // 直接裸开库文件校验（不指定 version，不触发任何回调）：版本与旧数据都应原样
    final raw = await databaseFactoryFfi.openDatabase(v3Path);
    try {
      expect(await raw.getVersion(), 3); // setVersion 也回滚了
      final itemRows = await raw.query('items');
      expect(itemRows, hasLength(1));
      expect(itemRows.first['name'], '梯子 '); // 旧的非归一化数据完整保留
      expect(await raw.query('item_locations'), hasLength(1));
    } finally {
      await raw.close();
    }

    // 不带钩子的正常 v4 仍能成功迁移，库未被搞坏
    final recovered = newDb(version: 4, path: v3Path);
    final found = await recovered.findByName('梯子');
    expect(found, isNotNull);
    expect(found!.item.name, '梯子');
    expect(await recovered.countActiveAssociations(), 1);
  });

  // ---- 全新装库：onCreate 路径（不触发迁移）----

  test('全新装库走 onCreate：建表正常、归一化照常生效、不触发迁移', () async {
    // newDb 默认 version=4，全新路径 -> onCreate，不经过 _onUpgrade
    expect(db.isOpen, isFalse);
    final locationId = await db.addLocation('　阳台　');
    await db.upsertItemLocation('ＬＡＤＤＥＲ ', locationId);
    expect(db.isOpen, isTrue);

    // onCreate 建的库与迁移库结构一致，归一化入口在两条路径都生效
    final found = await db.findByName('ladder');
    expect(found, isNotNull);
    expect(found!.item.name, 'ladder');
    expect(found.locations.single.name, '阳台');

    // 重开仍可读，证明是真正落盘的全新库
    await db.close();
    final reopened = newDb(); // version=4
    expect((await reopened.findByName('ladder')), isNotNull);
  });
}
