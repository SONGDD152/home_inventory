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

  // 默认 version=8，与生产对齐（V3.8）；全新装库走 onCreate，显式低版本的迁移测试另行指定。
  InventoryDatabase newDb({int version = 8, String? path}) {
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
    final failing = InventoryDatabase.forTesting(
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
    // newDb 默认 version=5，全新路径 -> onCreate，不经过 _onUpgrade
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
    final reopened = newDb(); // version=5
    expect((await reopened.findByName('ladder')), isNotNull);
  });

  // ---- V3 交互说明：位置备注 / 记录原文 / 标签 ----

  test('V3 位置备注 remark 存取与重开保留', () async {
    final id = await db.addLocation('阳台', remark: '朝南，晾衣架');
    final locs = await db.getAllLocations();
    expect(locs.single.id, id);
    expect(locs.single.remark, '朝南，晾衣架');

    await db.close();
    final reopened = newDb();
    expect((await reopened.getAllLocations()).single.remark, '朝南，晾衣架');
  });

  test('V3 记录原文 rawText 落库（新建关联时写入）', () async {
    final id = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', id, rawText: '梯子放阳台');
    // 通过 findByName 拿到的位置不含 raw_text，直查关联表验证落库。
    final dbHandle = await db.open();
    final rows = await dbHandle.query('item_locations');
    expect(rows.single['raw_text'], '梯子放阳台');
  });

  test('V3 编辑位置名称与备注不丢关联', () async {
    final id = await db.addLocation('阳台', remark: '旧备注');
    await db.upsertItemLocation('梯子', id);
    await db.updateLocation(id, name: '南阳台', remark: '新备注');

    final loc = (await db.getAllLocations()).single;
    expect(loc.name, '南阳台');
    expect(loc.remark, '新备注');
    expect((await db.findByName('梯子'))!.locations.single.name, '南阳台');
  });

  test('V3 软删除位置后不出现在列表与查询关联', () async {
    final id = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', id);
    await db.deleteLocation(id);

    expect(await db.getAllLocations(), isEmpty);
    expect((await db.findByName('梯子'))!.locations, isEmpty);
  });

  test('v4 旧库升级到 v5：ALTER 补三列且不丢历史数据', () async {
    // 造一个 v4 库（旧表结构，无 remark/raw_text/tags）。
    final legacyPath = p.join(tempDir.path, 'v4_legacy.db');
    final factory = databaseFactoryFfi;
    final legacy = await factory.openDatabase(
      legacyPath,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (d, v) async {
          await d.execute('CREATE TABLE locations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');
          await d.execute('CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');
          await d.execute('CREATE TABLE item_locations (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, location_id INTEGER NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');
          final now = DateTime.now().millisecondsSinceEpoch;
          await d.insert('locations', {'name': '阳台', 'is_deleted': 0, 'created_at': now, 'updated_at': now});
          await d.insert('items', {'name': '梯子', 'is_deleted': 0, 'created_at': now, 'updated_at': now});
          await d.insert('item_locations', {'item_id': 1, 'location_id': 1, 'is_deleted': 0, 'created_at': now, 'updated_at': now});
        },
      ),
    );
    await legacy.close();

    // 用 v5 打开，触发 ALTER 补列。
    final upgraded = InventoryDatabase(
      databaseFactory: factory,
      databasePath: legacyPath,
      version: 5,
    );
    opened.add(upgraded);
    final found = await upgraded.findByName('梯子');
    expect(found, isNotNull);
    expect(found!.locations.single.name, '阳台');
    // 新列可读（值为 null），且可继续写入备注。
    expect((await upgraded.getAllLocations()).single.remark, isNull);
    final id = found.locations.single.id!;
    await upgraded.updateLocation(id, remark: '迁移后补录');
    expect((await upgraded.getAllLocations()).single.remark, '迁移后补录');
  });

  test('v5 加列失败整体回滚：版本退回4、已加列撤销、旧数据不丢（技术审核条件③）',
      () async {
    // 造一个带数据的 v4 库（无 remark/raw_text/tags）。
    final legacyPath = p.join(tempDir.path, 'v4_v5_rollback.db');
    final factory = databaseFactoryFfi;
    final legacy = await factory.openDatabase(
      legacyPath,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (d, v) async {
          await d.execute('CREATE TABLE locations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');
          await d.execute('CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');
          await d.execute('CREATE TABLE item_locations (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, location_id INTEGER NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');
          final now = DateTime.now().millisecondsSinceEpoch;
          await d.insert('locations', {'name': '阳台', 'is_deleted': 0, 'created_at': now, 'updated_at': now});
          await d.insert('items', {'name': '梯子', 'is_deleted': 0, 'created_at': now, 'updated_at': now});
          await d.insert('item_locations', {'item_id': 1, 'location_id': 1, 'is_deleted': 0, 'created_at': now, 'updated_at': now});
        },
      ),
    );
    await legacy.close();

    // remark 加完、另两列未加时注入失败 → onUpgrade 事务应整体回滚。
    final failing = InventoryDatabase.forTesting(
      databaseFactory: factory,
      databasePath: legacyPath,
      version: 5,
      migrationV5FailureHook: () =>
          throw StateError('injected v5 migration failure'),
    );
    opened.add(failing);
    await expectLater(failing.open(), throwsA(isA<StateError>()));

    // 裸开库校验：版本、列、数据三者都回到迁移前。
    final raw = await factory.openDatabase(legacyPath);
    try {
      expect(await raw.getVersion(), 4); // setVersion 也回滚
      final locCols = await raw.rawQuery('PRAGMA table_info(locations)');
      expect(locCols.any((c) => c['name'] == 'remark'), isFalse,
          reason: 'remark 已加过也必须随事务回滚，不留半迁移态');
      final assocCols = await raw.rawQuery('PRAGMA table_info(item_locations)');
      expect(assocCols.any((c) => c['name'] == 'raw_text'), isFalse);
      expect(assocCols.any((c) => c['name'] == 'tags'), isFalse);
      expect(await raw.query('items'), hasLength(1));
      expect((await raw.query('items')).first['name'], '梯子');
    } finally {
      await raw.close();
    }

    // 不带钩子的正常 v5 仍能成功补列，库未被搞坏。
    final recovered = InventoryDatabase(
      databaseFactory: factory,
      databasePath: legacyPath,
      version: 5,
    );
    opened.add(recovered);
    expect((await recovered.getAllLocations()).single.name, '阳台');
    final id = (await recovered.getAllLocations()).single.id!;
    await recovered.updateLocation(id, remark: '恢复后补录');
    expect((await recovered.getAllLocations()).single.remark, '恢复后补录');
  });

  // ---- 备份与恢复 ----

  test('exportBackup：三表全量（含软删行）+ 元数据，纯读取不改库', () async {
    await put('梯子', '阳台');
    await put('充电器', '书房');
    // 软删一个位置（"书房"→先找到 id），制造软删行。
    final locations = await db.getAllLocations();
    final studyId = locations.firstWhere((l) => l.name == '书房').id!;
    await db.deleteLocation(studyId);

    final before = await db.getAllItems();
    final backup = await db.exportBackup();

    expect(backup['app'], 'home_inventory');
    expect((backup['schemaVersion'] as num).toInt(), 8);
    expect(backup['exportedAt'], isNotNull);
    expect(backup['items'] as List, hasLength(2), reason: '两件物品（无软删物品入口）');
    expect(backup['locations'] as List, hasLength(2), reason: '阳台+书房（书房已软删，仍导出）');
    expect(backup['item_locations'] as List, hasLength(2));

    // 纯读取：导出后库内活动数据不变。
    final after = await db.getAllItems();
    expect(after.map((i) => i.name), before.map((i) => i.name));
  });

  test('恢复往返：导出 → 新库恢复 → 数据与多位置关系一致', () async {
    await put('梯子', '阳台');
    await put('梯子', '车库');
    await put('充电器', '书房');
    final backup = await db.exportBackup();

    // 另一个全新库文件。
    final otherPath = p.join(tempDir.path, 'restored.db');
    final restoredDb = newDb(path: otherPath);

    await restoredDb.restoreBackup(backup);

    final rows = await restoredDb.getAllItemsWithLocations();
    expect(rows, hasLength(2), reason: '两个物品：梯子（2 位置）与充电器（1 位置）');
    final ladder = rows.firstWhere((r) => r.item.name == '梯子');
    expect(ladder.locations.map((l) => l.name), containsAll(<String>['阳台', '车库']));
    final charger = rows.firstWhere((r) => r.item.name == '充电器');
    expect(charger.locations.map((l) => l.name), <String>['书房']);

    // 恢复后查询链路可用。
    final found = await restoredDb.findByName('梯子');
    expect(found, isNotNull);
    expect(found!.locations, hasLength(2));
  });

  test('恢复覆盖：目标库旧数据被清空，不留残留', () async {
    await put('梯子', '阳台');
    final backup = await db.exportBackup();

    // 目标库已有完全不同的数据（注意 put 固定写外层 db，这里直接操作目标库）。
    final otherPath = p.join(tempDir.path, 'target.db');
    final target = newDb(path: otherPath);
    final oldLocId = await target.addLocation('旧位置');
    await target.upsertItemLocation('旧物', oldLocId);
    expect(await target.getAllItems(), hasLength(1));

    await target.restoreBackup(backup);

    final rows = await target.getAllItemsWithLocations();
    expect(rows, hasLength(1));
    expect(rows.single.item.name, '梯子', reason: '旧数据应被清空替换');
    expect(rows.single.locations.single.name, '阳台');
  });

  test('恢复软删保真：软删位置还原后仍不在活动列表，且位置 id 保留', () async {
    final locationId = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', locationId);
    await db.deleteLocation(locationId);
    final backup = await db.exportBackup();

    final otherPath = p.join(tempDir.path, 'softdel.db');
    final restoredDb = newDb(path: otherPath);
    await restoredDb.restoreBackup(backup);

    // 软删位置不在活动列表。
    expect((await restoredDb.getAllLocations()), isEmpty);
    // 但行还在（按 id 定位后可见 is_deleted=1），保证再次还原/审计可行。
    final row = await restoredDb.getLocationById(locationId);
    expect(row, isNull, reason: 'getLocationById 只返回未删除位置');
    final assocCount = await restoredDb.countActiveAssociations();
    // V3.2 联动修正（审核决策点②）：位置软删时活跃关联一并联动软删，
    // 不再留「活跃关联指向已删位置」的脏状态——计数从旧行为的 1 变为 0。
    expect(assocCount, 0, reason: 'V3.2 起关联随位置删除联动软删');
    // 联动软删的关联行留底：导出里按 is_deleted=1 可见，复活同一行时可回显。
    final assocRows = (backup['item_locations'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .where((m) => m['location_id'] == locationId)
        .toList();
    expect(assocRows, hasLength(1));
    expect(assocRows.single['is_deleted'], 1);
    expect((await restoredDb.getAllItems()), isNotEmpty, reason: '物品本身未删');
  });

  test('恢复校验：非本应用备份 / 缺表 / 版本过高 → ArgumentError 且不改库', () async {
    await put('梯子', '阳台');
    final backup = await db.exportBackup();

    final otherPath = p.join(tempDir.path, 'guard.db');
    final target = newDb(path: otherPath);
    final oldLocId = await target.addLocation('旧位置');
    await target.upsertItemLocation('旧物', oldLocId);

    Future<void> expectRejected(Object? bad, String reason) async {
      await expectLater(
        target.restoreBackup(bad as Map<String, Object?>),
        throwsArgumentError,
        reason: reason,
      );
    }

    await expectRejected(<String, Object?>{'app': '别的应用'}, '归属校验');
    await expectRejected(<String, Object?>{
      'app': 'home_inventory',
      'schemaVersion': 5,
      'items': <Object?>[<String, Object?>{'name': 'x', 'created_at': 1, 'updated_at': 1}],
    }, '缺 locations/item_locations 表');
    await expectRejected(<String, Object?>{
      'app': 'home_inventory',
      'schemaVersion': 9,
      'items': <Object?>[],
      'locations': <Object?>[],
      'item_locations': <Object?>[],
    }, '版本过高');

    // 校验失败不改库。
    final rows = await target.getAllItemsWithLocations();
    expect(rows.single.item.name, '旧物');
    // 正确备份仍可恢复（库未被前面失败破坏）。
    await target.restoreBackup(backup);
    expect((await target.getAllItemsWithLocations()).single.item.name, '梯子');
  });

  // ---- V3.6 回收站 ----

  /// 造一个 v5 结构旧库（items 无 deleted_at），含活跃与历史软删行。
  Future<String> createV5LegacyDb(String fileName) async {
    final legacyPath = p.join(tempDir.path, fileName);
    final factory = databaseFactoryFfi;
    final legacy = await factory.openDatabase(
      legacyPath,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: (d, v) async {
          await d.execute(
              'CREATE TABLE locations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, remark TEXT)');
          await d.execute(
              'CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');
          await d.execute(
              'CREATE TABLE item_locations (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, location_id INTEGER NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, raw_text TEXT, tags TEXT)');
          final now = DateTime.now().millisecondsSinceEpoch;
          await d.insert('locations',
              {'name': '阳台', 'is_deleted': 0, 'created_at': now, 'updated_at': now});
          // 梯子：活跃行。
          await d.insert('items',
              {'name': '梯子', 'is_deleted': 0, 'created_at': now, 'updated_at': now});
          // 旧物：历史软删行（deleted_at 尚不存在，模拟 v3.2 时代软删）。
          await d.insert('items',
              {'name': '旧物', 'is_deleted': 1, 'created_at': now, 'updated_at': now});
          await d.insert('item_locations',
              {'item_id': 1, 'location_id': 1, 'is_deleted': 0, 'created_at': now, 'updated_at': now});
        },
      ),
    );
    await legacy.close();
    return legacyPath;
  }

  test('v5 旧库升级到 v6：ALTER 补 deleted_at，老数据零丢失', () async {
    final factory = databaseFactoryFfi;
    final legacyPath = await createV5LegacyDb('v5_legacy.db');

    final upgraded = InventoryDatabase(
      databaseFactory: factory,
      databasePath: legacyPath,
      version: 6,
    );
    opened.add(upgraded);

    // 老数据：活跃行正常显示，软删历史行进回收站（deleted_at 为 NULL）。
    final active = await upgraded.getAllItemsWithLocations();
    expect(active.single.item.name, '梯子');
    final deleted = await upgraded.getDeletedItems();
    expect(deleted.single.item.name, '旧物');
    expect(deleted.single.item.deletedAt, isNull, reason: '历史软删行无删除时间');
    // v6 能力可用：删除真实物品后 deleted_at 写入。
    await upgraded.deleteItem(active.single.item.id!);
    final after = await upgraded.getDeletedItems();
    expect(after.where((r) => r.item.name == '梯子').single.item.deletedAt,
        isNotNull);
  });

  test('v6 加列失败整体回滚：版本退回5、列撤销、旧数据不丢', () async {
    final factory = databaseFactoryFfi;
    final legacyPath = await createV5LegacyDb('v6_rollback.db');

    final failing = InventoryDatabase.forTesting(
      databaseFactory: factory,
      databasePath: legacyPath,
      version: 6,
      migrationV6FailureHook: () =>
          throw StateError('injected v6 migration failure'),
    );
    opened.add(failing);
    await expectLater(failing.open(), throwsA(isA<StateError>()));

    final raw = await factory.openDatabase(legacyPath);
    try {
      expect(await raw.getVersion(), 5, reason: 'setVersion 随事务回滚');
      final itemCols = await raw.rawQuery('PRAGMA table_info(items)');
      expect(itemCols.any((c) => c['name'] == 'deleted_at'), isFalse,
          reason: '不留半迁移态');
      expect(await raw.query('items'), hasLength(2), reason: '旧数据不丢');
    } finally {
      await raw.close();
    }

    // 不带钩子的正常 v6 仍能成功升级。
    final recovered = InventoryDatabase(
      databaseFactory: factory,
      databasePath: legacyPath,
      version: 6,
    );
    opened.add(recovered);
    expect((await recovered.getAllItemsWithLocations()).single.item.name, '梯子');
  });

  test('V3.6 软删→恢复：位置关系还原、挪位历史行不复活', () async {
    final balconyId = await db.addLocation('阳台');
    final garageId = await db.addLocation('车库');
    final up = await db.upsertItemLocation('梯子', balconyId,
        rawText: '梯子放阳台');
    await db.moveItem('梯子', garageId); // 阳台变挪位软删历史行

    await db.deleteItem(up.itemId);

    // 回收站：物品可见，原位置展示含历史（阳台+车库均有效位置）。
    final deleted = await db.getDeletedItems();
    expect(deleted.single.item.name, '梯子');
    expect(deleted.single.locations.map((l) => l.name),
        containsAll(<String>['阳台', '车库']));

    await db.restoreItem(up.itemId);

    // 恢复后正常列表只回到车库（删除时活跃行复活，挪位历史行保持留底）。
    final found = await db.findByName('梯子');
    expect(found!.locations.map((l) => l.name), <String>['车库']);
    expect(found.item.deletedAt, isNull);
    // 挪位历史行未复活：原文「梯子放阳台」在阳台历史行上，不随恢复出现。
    expect(found.rawTexts, isEmpty);
  });

  test('V3.6 恢复撞名：提示失败不自动改名（决策点④A）', () async {
    final balconyId = await db.addLocation('阳台');
    final up = await db.upsertItemLocation('梯子', balconyId);
    await db.deleteItem(up.itemId);
    // 同名新物品可正常新建（唯一索引不拦已删名）。
    final reborn = await db.upsertItemLocation('梯子', balconyId);
    expect(reborn.itemId, isNot(up.itemId));

    await expectLater(
      db.restoreItem(up.itemId),
      throwsA(isA<ArgumentError>().having(
        (e) => e.message, 'message', contains('已存在同名物品'),
      )),
    );
    // 恢复失败 → 旧物品仍在回收站、新物品不受影响。
    expect((await db.getDeletedItems()).single.item.id, up.itemId);
    expect((await db.getAllItemsWithLocations()).single.item.id, reborn.itemId);
  });

  test('V3.6 purgeItem：物品行+全部关联行物理清除、回收站消失', () async {
    final balconyId = await db.addLocation('阳台');
    final up = await db.upsertItemLocation('梯子', balconyId);
    await db.moveItem('梯子', await db.addLocation('车库'));
    await db.deleteItem(up.itemId);

    await db.purgeItem(up.itemId);

    final backup = await db.exportBackup();
    expect(
      (backup['items'] as List<Object?>)
          .cast<Map<String, Object?>>()
          .where((m) => m['name'] == '梯子'),
      isEmpty,
      reason: '物品行物理清除',
    );
    expect(
      (backup['item_locations'] as List<Object?>)
          .cast<Map<String, Object?>>()
          .where((m) => m['item_id'] == up.itemId),
      isEmpty,
      reason: '关联行（含挪位历史）物理清除',
    );
    expect(await db.getDeletedItems(), isEmpty);
    // 幂等：重复 purge 不抛错。
    await db.purgeItem(up.itemId);
  });

  test('V3.6 purgeAll：清空回收站，活跃物品不受影响', () async {
    final up1 = await put('梯子', '阳台');
    final up2 = await put('充电器', '书房');
    await db.deleteItem(up1.itemId);
    await db.deleteItem(up2.itemId);
    expect(await db.getDeletedItems(), hasLength(2));

    await db.purgeAll();

    expect(await db.getDeletedItems(), isEmpty);
    final backup = await db.exportBackup();
    expect((backup['items'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .every((m) => m['is_deleted'] == 0), isTrue);
  });

  test('V3.6 getDeletedItems：deleted_at 倒序，NULL 历史行排末尾', () async {
    await put('书', '书房');
    final backup = await db.exportBackup();
    // 构造历史软删行：把「书」行改为 is_deleted=1 且无 deleted_at（v3.2 口径），恢复。
    final items = List<Map<String, Object?>>.of(
      (backup['items'] as List<Object?>).cast<Map<String, Object?>>(),
    )..removeWhere((m) => m['name'] == '书');
    items.add(<String, Object?>{
      'id': 1,
      'name': '书',
      'is_deleted': 1,
      'created_at': 1,
      'updated_at': 1,
    });
    final restored = <String, Object?>{
      'app': 'home_inventory',
      'schemaVersion': backup['schemaVersion'],
      'items': items,
      'locations': backup['locations'],
      'item_locations': backup['item_locations'],
    };
    await db.restoreBackup(restored);

    final up2 = await put('梯子', '阳台');
    await db.deleteItem(up2.itemId);

    final rows = await db.getDeletedItems();
    expect(rows, hasLength(2));
    expect(rows.first.item.name, '梯子', reason: '有 deleted_at 的排前');
    expect(rows.first.item.deletedAt, isNotNull);
    expect(rows.last.item.name, '书', reason: 'NULL 历史行排末尾');
    expect(rows.last.item.deletedAt, isNull);
  });

  test('V3.6 备份往返：导出含已删行，恢复后正常/回收站各自归位', () async {
    await put('梯子', '阳台');
    await put('充电器', '书房');
    await db.deleteItem(1); // 梯子进回收站

    final backup = await db.exportBackup();
    final exportedItems = (backup['items'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .where((m) => m['name'] == '梯子')
        .toList();
    expect(exportedItems, hasLength(1), reason: '已删行随备份导出');
    expect(exportedItems.single['deleted_at'], isNotNull);

    // 恢复到另一空库 → 状态一致。
    final otherPath = p.join(tempDir.path, 'restore_v36.db');
    final target = newDb(path: otherPath);
    await target.restoreBackup(backup);
    expect((await target.getAllItemsWithLocations()).single.item.name, '充电器');
    final deleted = await target.getDeletedItems();
    expect(deleted.single.item.name, '梯子');
    expect(deleted.single.item.deletedAt, isNotNull, reason: '回收站归位');
  });

  // ---- 挪位语义（V3.2） ----

  test('moveItem：旧位置关联软删、只留新位置、返回原位置名', () async {
    final balconyId = await db.addLocation('阳台');
    final garageId = await db.addLocation('车库');
    final livingId = await db.addLocation('客厅');
    await db.upsertItemLocation('梯子', balconyId, rawText: '梯子放阳台');

    final result = await db.moveItem('梯子', livingId, rawText: '梯子挪到客厅');

    expect(result.created, isTrue);
    expect(result.previousLocations, <String>['阳台'], reason: '挪位前原位置');
    // 查询只剩新位置。
    final found = await db.findByName('梯子');
    expect(found!.locations.map((l) => l.name), <String>['客厅']);
    // 旧关联软删留底（导出仍能看见该行）。
    final backup = await db.exportBackup();
    final assoc = (backup['item_locations'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .where((m) => m['location_id'] == balconyId)
        .toList();
    expect(assoc, hasLength(1));
    expect(assoc.single['is_deleted'], 1);
    // 车库从未关联过梯子。
    expect(
      (backup['item_locations'] as List<Object?>)
          .cast<Map<String, Object?>>()
          .where((m) => m['location_id'] == garageId),
      isEmpty,
    );
  });

  test('moveItem：多个旧位置全部替换且按记录顺序返回', () async {
    final a = await db.addLocation('阳台');
    final b = await db.addLocation('车库');
    final c = await db.addLocation('客厅');
    await db.upsertItemLocation('梯子', a);
    await db.upsertItemLocation('梯子', b);

    final result = await db.moveItem('梯子', c);
    expect(result.previousLocations, <String>['阳台', '车库']);
    expect((await db.findByName('梯子'))!.locations.single.name, '客厅');
  });

  test('moveItem：目标位已是当前位置 → created=false 且原位置不含目标', () async {
    final balconyId = await db.addLocation('阳台');
    final livingId = await db.addLocation('客厅');
    await db.upsertItemLocation('梯子', balconyId);
    await db.moveItem('梯子', livingId);

    final again = await db.moveItem('梯子', livingId);
    expect(again.created, isFalse);
    expect(again.previousLocations, isEmpty, reason: '目标位本身不算原位置');
    expect((await db.findByName('梯子'))!.locations.single.name, '客厅');
  });

  test('moveItem：挪到已删除位置 → ArgumentError', () async {
    final balconyId = await db.addLocation('阳台');
    final goneId = await db.addLocation('车库');
    await db.upsertItemLocation('梯子', balconyId);
    await db.deleteLocation(goneId);

    await expectLater(
      db.moveItem('梯子', goneId),
      throwsArgumentError,
    );
    // 原数据不受影响。
    expect((await db.findByName('梯子'))!.locations.single.name, '阳台');
  });

  // ---- V3.2：updateItem / deleteItem / deleteLocation 联动 ----

  test('V3.2 updateItem：改名生效，关联跟随不丢', () async {
    final balconyId = await db.addLocation('阳台');
    final up = await db.upsertItemLocation('梯子', balconyId);

    await db.updateItem(up.itemId, '折叠梯');

    final found = await db.findByName('折叠梯');
    expect(found, isNotNull, reason: '改名后按新名可查');
    expect(found!.locations.single.name, '阳台', reason: '关联跟随 item_id');
    expect(await db.findByName('梯子'), isNull, reason: '旧名不再命中');
  });

  test('V3.2 updateItem：归一化同源（全角/空白/大小写）', () async {
    final balconyId = await db.addLocation('阳台');
    final up = await db.upsertItemLocation('梯子', balconyId);

    await db.updateItem(up.itemId, '　ＬＡＤＤＥＲ　');

    expect((await db.findByName('ladder'))!.item.name, 'ladder');
  });

  test('V3.2 updateItem：空名与超名被拒绝', () async {
    final balconyId = await db.addLocation('阳台');
    final up = await db.upsertItemLocation('梯子', balconyId);

    await expectLater(db.updateItem(up.itemId, '   '), throwsArgumentError);
    await expectLater(
      db.updateItem(up.itemId, '长' * 101),
      throwsArgumentError,
      reason: '超过 maxNameLength=100 拒绝',
    );
    expect((await db.findByName('梯子'))!.item.name, '梯子',
        reason: '拒绝后名称不变');
  });

  test('V3.2 updateItem：撞活跃同名拒绝、改名回自身不误伤、已删同名允许', () async {
    final balconyId = await db.addLocation('阳台');
    final up = await db.upsertItemLocation('梯子', balconyId);
    final chargerId = await db.addLocation('书房');
    final charger = await db.upsertItemLocation('充电器', chargerId);

    // 撞另一个活跃物品名 → ArgumentError。
    await expectLater(
      db.updateItem(up.itemId, '充电器'),
      throwsArgumentError,
    );
    // 改回自己的名字（排除自身）不报错。
    await db.updateItem(up.itemId, '梯子');
    // 先删充电器，再让梯子复用其名 → 允许（已删物品不算撞名）。
    await db.deleteItem(charger.itemId);
    await db.updateItem(up.itemId, '充电器');
    expect((await db.findByName('充电器'))!.item.name, '充电器');
  });

  test('V3.6 deleteItem：物品行软删+deleted_at、关联行软删留底、幂等', () async {
    final balconyId = await db.addLocation('阳台');
    final livingId = await db.addLocation('客厅');
    final up = await db.upsertItemLocation('梯子', balconyId);
    // 挪位产生阳台软删历史行。
    await db.moveItem('梯子', livingId);

    await db.deleteItem(up.itemId);

    // 查询与明细都不再出现。
    expect(await db.findByName('梯子'), isNull);
    expect(
      (await db.getAllItemsWithLocations())
          .where((r) => r.item.name == '梯子'),
      isEmpty,
    );
    // 回收站可见该物品（V3.6）。
    final deleted = await db.getDeletedItems();
    expect(deleted.where((r) => r.item.name == '梯子'), hasLength(1));
    expect(deleted.single.item.isDeleted, isTrue);
    expect(deleted.single.item.deletedAt, isNotNull);
    // 物品行软删留底；关联行软删留底（V3.6 语义：不再物理清除）。
    final backup = await db.exportBackup();
    final items = (backup['items'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .where((m) => m['name'] == '梯子')
        .toList();
    expect(items, hasLength(1));
    expect(items.single['is_deleted'], 1, reason: '物品行软删留底');
    expect(items.single['deleted_at'], isNotNull, reason: '记录删除时间');
    final assocs = (backup['item_locations'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .where((m) => m['item_id'] == up.itemId)
        .toList();
    expect(assocs, hasLength(2), reason: '活跃行+挪位历史行均留底');
    expect(
      assocs.every((m) => m['is_deleted'] == 1),
      isTrue,
      reason: '活跃行被删除联动软删，挪位历史行本就软删',
    );
    // 幂等：重复删除不抛错。
    await db.deleteItem(up.itemId);
  });

  test('V3.2 deleteItem：删除后同名复活走新行，备份往返状态一致', () async {
    final balconyId = await db.addLocation('阳台');
    final livingId = await db.addLocation('客厅');
    final up = await db.upsertItemLocation('梯子', balconyId);
    await db.deleteItem(up.itemId);

    // 同名复活：插入新行（部分唯一索引只约束活跃行）。
    final revived = await db.upsertItemLocation('梯子', livingId);
    expect(revived.itemId, isNot(up.itemId), reason: '复活是新行新 id');
    expect((await db.findByName('梯子'))!.locations.single.name, '客厅');

    // 备份往返：导出 → 新库恢复 → 状态一致（无僵尸关联）。
    final backup = await db.exportBackup();
    final target = newDb(path: p.join(tempDir.path, 'restore_v32.db'));
    await target.restoreBackup(backup);
    final restored = await target.getAllItemsWithLocations();
    final ladder = restored.where((r) => r.item.name == '梯子').single;
    expect(ladder.locations.single.name, '客厅');
  });

  test('V3.2 deleteLocation：活跃关联联动软删、软删历史物理清、同名位置可重建', () async {
    final balconyId = await db.addLocation('阳台');
    final livingId = await db.addLocation('客厅');
    // 梯子活跃关联指向阳台。
    final ladderUp = await db.upsertItemLocation('梯子', balconyId);
    // 充电器先在阳台、挪去客厅 → 产生指向阳台的软删历史行。
    await db.upsertItemLocation('充电器', balconyId);
    await db.moveItem('充电器', livingId);

    await db.deleteLocation(balconyId);

    final backup = await db.exportBackup();
    final assocOnBalcony = (backup['item_locations'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .where((m) => m['location_id'] == balconyId)
        .toList();
    expect(assocOnBalcony, hasLength(1), reason: '软删历史行已物理清，只留 1 行');
    expect(assocOnBalcony.single['is_deleted'], 1,
        reason: '留底的是原活跃关联（梯子），复活同一行时可回显');
    expect(assocOnBalcony.single['item_id'], ladderUp.itemId,
        reason: '留底行属于梯子；充电器的软删历史行已被物理清除');
    // 梯子无有效位置，充电器仍在客厅。
    final details = await db.getAllItemsWithLocations();
    expect(
        details.where((r) => r.item.name == '梯子').single.locations, isEmpty);
    expect(
      details.where((r) => r.item.name == '充电器').single.locations.single.name,
      '客厅',
    );
    // 同名位置可重建（新行新 id），旧软删关联不跟随新 id 回显。
    final newBalconyId = await db.addLocation('阳台');
    expect(newBalconyId, isNot(balconyId));
    expect(
      (await db.getAllItemsWithLocations())
          .where((r) => r.item.name == '梯子')
          .single
          .locations,
      isEmpty,
      reason: '新建同名不复活旧关联（审核确认点②口径）',
    );
  });

  // =========== V3.7 借阅管理 ===========
  group('V3.7 借出/归还/迁移', () {
    test('v6 旧库升级到 v7：items 补 quantity、建借出两表、老数据零丢失', () async {
      final legacyPath = p.join(tempDir.path, 'v6_v7.db');
      final factory = databaseFactoryFfi;
      final legacy = await factory.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: 6,
          onCreate: (d, v) async {
            await d.execute('CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER)');
            await d.execute('CREATE TABLE locations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, remark TEXT)');
            await d.execute('CREATE TABLE item_locations (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, location_id INTEGER NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, raw_text TEXT, tags TEXT)');
            final now = DateTime.now().millisecondsSinceEpoch;
            await d.insert('items', {'name': '梯子', 'is_deleted': 0, 'created_at': now, 'updated_at': now, 'deleted_at': null});
          },
        ),
      );
      await legacy.close();

      final upgraded = InventoryDatabase(
          databaseFactory: factory, databasePath: legacyPath, version: 7);
      opened.add(upgraded);
      final rows = await upgraded.getAllItems();
      expect(rows, hasLength(1));
      expect(rows.single.name, '梯子');
      expect(rows.single.quantity, 1, reason: '老物品补默认数量 1');
      expect(await upgraded.getAllLoans(), isEmpty);
      expect(await upgraded.getActiveBorrowers(), isEmpty);
    });

    test('迁移失败整体回滚：v7 建表前抛错，版本退回 6 且数据不丢', () async {
      final legacyPath = p.join(tempDir.path, 'v7_rollback.db');
      final factory = databaseFactoryFfi;
      final legacy = await factory.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: 6,
          onCreate: (d, v) async {
            await d.execute('CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER)');
            await d.execute('CREATE TABLE locations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, remark TEXT)');
            await d.execute('CREATE TABLE item_locations (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, location_id INTEGER NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, raw_text TEXT, tags TEXT)');
            final now = DateTime.now().millisecondsSinceEpoch;
            await d.insert('items', {'name': '梯子', 'is_deleted': 0, 'created_at': now, 'updated_at': now, 'deleted_at': null});
          },
        ),
      );
      await legacy.close();

      final failing = InventoryDatabase.forTesting(
        databaseFactory: factory,
        databasePath: legacyPath,
        version: 7,
        migrationV7FailureHook: () => throw StateError('injected v7 failure'),
      );
      opened.add(failing);
      await expectLater(failing.open(), throwsA(isA<StateError>()));

      final raw = await factory.openDatabase(legacyPath);
      try {
        expect(await raw.getVersion(), 6);
        final cols = await raw.rawQuery('PRAGMA table_info(items)');
        expect(cols.any((c) => c['name'] == 'quantity'), isFalse,
            reason: '半迁移态回滚');
        expect(await raw.query('items'), hasLength(1));
      } finally {
        await raw.close();
      }
    });

    test('旧备份（无 quantity/借出表）恢复到 v8：自动补 quantity=1', () async {
      // 用 v6 结构手工造一份备份 map（模拟 V3.6 导出的 JSON）。
      final now = DateTime.now().millisecondsSinceEpoch;
      final oldBackup = <String, Object?>{
        'app': 'home_inventory',
        'schemaVersion': 6,
        'exportedAt': now,
        'items': <Map<String, Object?>>[
          {'id': 1, 'name': '梯子', 'is_deleted': 0, 'created_at': now, 'updated_at': now, 'deleted_at': null},
        ],
        'locations': <Map<String, Object?>>[
          {'id': 1, 'name': '阳台', 'is_deleted': 0, 'created_at': now, 'updated_at': now, 'remark': null},
        ],
        'item_locations': <Map<String, Object?>>[
          {'id': 1, 'item_id': 1, 'location_id': 1, 'is_deleted': 0, 'created_at': now, 'updated_at': now, 'raw_text': null, 'tags': null},
        ],
      };
      await db.restoreBackup(oldBackup);
      final rows = await db.getAllItemsWithLocations();
      expect(rows, hasLength(1));
      expect(rows.single.item.quantity, 1, reason: '旧备份恢复补数量 1（元宝硬约束）');
      expect(rows.single.locations.single.name, '阳台');
    });

    test('借出默认 3 天；全部归还后 isReturned=true', () async {
      final loan = await db.lendItem('梯子', '张三');
      expect(loan.quantity, 1);
      expect(loan.returnedQty, 0);
      expect(loan.isReturned, isFalse);
      expect(loan.dueAt - loan.borrowedAt, 3 * 86400000,
          reason: '默认借期 3 天（UTC 毫秒）');

      await db.returnLoan(loan.id!);
      final all = await db.getAllLoans();
      expect(all.single.isReturned, isTrue);
      expect(all.single.returnedAt, isNotNull);
    });

    test('部分归还：数量累加、isPartial=true、未还清不置 returnedAt', () async {
      final loan = await db.lendItem('梯子', '张三', quantity: 3);
      await db.returnLoan(loan.id!, quantity: 1);
      var current = (await db.getAllLoans()).single;
      expect(current.returnedQty, 1);
      expect(current.isPartial, isTrue);
      expect(current.returnedAt, isNull);
      expect(current.isReturned, isFalse);

      await db.returnLoan(loan.id!, quantity: 2);
      current = (await db.getAllLoans()).single;
      expect(current.returnedQty, 3);
      expect(current.isReturned, isTrue);
      expect(current.returnedAt, isNotNull);
    });

    test('归还数量超未还量 → ArgumentError；已还完再还幂等', () async {
      final loan = await db.lendItem('梯子', '张三', quantity: 2);
      await expectLater(db.returnLoan(loan.id!, quantity: 3),
          throwsA(isA<ArgumentError>()));
      await db.returnLoan(loan.id!);
      await db.returnLoan(loan.id!); // 幂等，不抛
      expect((await db.getAllLoans()).single.returnedQty, 2);
    });

    test('改借期从借出时刻起算；逾期判定 isOverdue(now)', () async {
      final loan = await db.lendItem('梯子', '张三', days: 1);
      await db.updateLoanDue(loan.id!, 5);
      final updated = (await db.getAllLoans()).single;
      expect(updated.dueAt - updated.borrowedAt, 5 * 86400000);
      expect(updated.isOverdue(updated.dueAt - 1), isFalse);
      expect(updated.isOverdue(updated.dueAt + 1), isTrue);
    });

    test('借阅人去重：同名借出复用一行；软删后历史 loan 名字快照仍在', () async {
      await db.lendItem('梯子', '张三');
      await db.lendItem('充电器', '张三');
      expect(await db.getActiveBorrowers(), hasLength(1));

      final borrowers = await db.getActiveBorrowers();
      await db.softDeleteBorrower(borrowers.single.id!);
      expect(await db.getActiveBorrowers(), isEmpty);
      final loans = await db.getAllLoans();
      expect(loans, hasLength(2));
      expect(loans.every((l) => l.borrowerName == '张三'), isTrue,
          reason: '快照不受软删影响');
    });

    test('借出备份往返：导出含借出两表，恢复后借还状态保真', () async {
      await put('梯子', '阳台');
      final loan = await db.lendItem('梯子', '张三', quantity: 2, days: 7);
      await db.returnLoan(loan.id!, quantity: 1);
      final backup = await db.exportBackup();
      expect(backup.containsKey('borrowers'), isTrue);
      expect(backup.containsKey('loans'), isTrue);

      final otherPath = p.join(tempDir.path, 'restore_v37.db');
      final other = newDb(path: otherPath);
      await other.restoreBackup(backup);
      final restored = await other.getAllLoans();
      expect(restored, hasLength(1));
      expect(restored.single.quantity, 2);
      expect(restored.single.returnedQty, 1);
      expect(restored.single.isPartial, isTrue);
      expect(await other.getActiveBorrowers(), hasLength(1));
    });

    test('借出数量/天数非法 → ArgumentError', () async {
      await expectLater(db.lendItem('梯子', '张三', quantity: 0),
          throwsA(isA<ArgumentError>()));
      await expectLater(db.lendItem('梯子', '张三', days: 0),
          throwsA(isA<ArgumentError>()));
    });
  });

  // =========== V3.8 借出记录软删（回收站） ===========
  group('V3.8 借出记录软删/迁移/备份兼容', () {
    /// 造一个 v7 老库（loans 无软删两列），含一条历史借出记录。
    Future<String> makeLegacyV7() async {
      final legacyPath = p.join(tempDir.path, 'v7_v8.db');
      final factory = databaseFactoryFfi;
      final legacy = await factory.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: 7,
          onCreate: (d, v) async {
            await d.execute('CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER, quantity INTEGER NOT NULL DEFAULT 1)');
            await d.execute('CREATE TABLE locations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, remark TEXT)');
            await d.execute('CREATE TABLE item_locations (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, location_id INTEGER NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, raw_text TEXT, tags TEXT)');
            await d.execute('CREATE TABLE borrowers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER)');
            await d.execute('CREATE TABLE loans (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, item_name TEXT NOT NULL, borrower_name TEXT NOT NULL, quantity INTEGER NOT NULL DEFAULT 1, returned_qty INTEGER NOT NULL DEFAULT 0, borrowed_at INTEGER NOT NULL, due_at INTEGER NOT NULL, returned_at INTEGER, is_partial INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL)');
            final now = DateTime.now().millisecondsSinceEpoch;
            await d.insert('items',
                {'name': '梯子', 'is_deleted': 0, 'created_at': now, 'updated_at': now, 'deleted_at': null, 'quantity': 2});
            await d.insert('locations',
                {'name': '阳台', 'is_deleted': 0, 'created_at': now, 'updated_at': now, 'remark': null});
            await d.insert('item_locations', {
              'item_id': 1,
              'location_id': 1,
              'is_deleted': 0,
              'created_at': now,
              'updated_at': now,
              'raw_text': null,
              'tags': null
            });
            await d.insert('borrowers',
                {'name': '张三', 'is_deleted': 0, 'created_at': now, 'updated_at': now, 'deleted_at': null});
            await d.insert('loans', {
              'item_id': 1,
              'item_name': '梯子',
              'borrower_name': '张三',
              'quantity': 2,
              'returned_qty': 0,
              'borrowed_at': now,
              'due_at': now + 3 * 86400000,
              'returned_at': null,
              'is_partial': 0,
              'updated_at': now
            });
          },
        ),
      );
      await legacy.close();
      return legacyPath;
    }

    test('v7 旧库升级到 v8：loans 补软删两列、历史借出记录一条不少', () async {
      final legacyPath = await makeLegacyV7();
      final upgraded = InventoryDatabase(
          databaseFactory: databaseFactoryFfi,
          databasePath: legacyPath,
          version: 8);
      opened.add(upgraded);

      final loans = await upgraded.getAllLoans();
      expect(loans, hasLength(1), reason: '升级不该让历史借出记录消失');
      expect(loans.single.itemName, '梯子');
      expect(loans.single.quantity, 2);
      expect(loans.single.isDeleted, isFalse);
      expect(await upgraded.getDeletedLoans(), isEmpty);

      final raw = await databaseFactoryFfi.openDatabase(legacyPath);
      try {
        final cols = await raw.rawQuery('PRAGMA table_info(loans)');
        expect(cols.any((c) => c['name'] == 'is_deleted'), isTrue);
        expect(cols.any((c) => c['name'] == 'deleted_at'), isTrue);
      } finally {
        await raw.close();
      }
    });

    test('迁移失败整体回滚：v8 加列前抛错，版本退回 7 且不留半迁移态', () async {
      final legacyPath = await makeLegacyV7();
      final failing = InventoryDatabase.forTesting(
        databaseFactory: databaseFactoryFfi,
        databasePath: legacyPath,
        version: 8,
        migrationV8FailureHook: () => throw StateError('injected v8 failure'),
      );
      opened.add(failing);
      await expectLater(failing.open(), throwsA(isA<StateError>()));

      final raw = await databaseFactoryFfi.openDatabase(legacyPath);
      try {
        expect(await raw.getVersion(), 7, reason: '版本退回 7');
        final cols = await raw.rawQuery('PRAGMA table_info(loans)');
        expect(cols.any((c) => c['name'] == 'is_deleted'), isFalse,
            reason: '半迁移态回滚');
        expect(await raw.query('loans'), hasLength(1), reason: '老数据不丢');
      } finally {
        await raw.close();
      }
    });

    test('删除→恢复→彻底删除：借出记录进出回收站，活跃列表不再挂它', () async {
      final loan = await db.lendItem('梯子', '张三', quantity: 2);
      final id = loan.id!;

      await db.deleteLoan(id);
      expect(await db.getAllLoans(), isEmpty, reason: '删除后不在活跃列表');
      final deleted = await db.getDeletedLoans();
      expect(deleted, hasLength(1));
      expect(deleted.single.isDeleted, isTrue);
      expect(deleted.single.deletedAt, isNotNull);

      await db.restoreLoan(id);
      expect(await db.getAllLoans(), hasLength(1));
      expect(await db.getDeletedLoans(), isEmpty);

      await db.deleteLoan(id);
      await db.purgeLoan(id);
      expect(await db.getDeletedLoans(), isEmpty);
      expect(await db.getAllLoans(), isEmpty);
    });

    test('删除不存在的记录 → ArgumentError（不静默）', () async {
      await expectLater(db.deleteLoan(999), throwsA(isA<ArgumentError>()));
      await expectLater(db.restoreLoan(999), throwsA(isA<ArgumentError>()));
      await expectLater(db.purgeLoan(999), throwsA(isA<ArgumentError>()));
    });

    test('V3.7 旧备份（loans 行无软删列）恢复到 v8：正常显示且视为未删', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final oldBackup = <String, Object?>{
        'app': 'home_inventory',
        'schemaVersion': 7,
        'exportedAt': now,
        'items': <Map<String, Object?>>[
          {'id': 1, 'name': '梯子', 'is_deleted': 0, 'created_at': now, 'updated_at': now, 'deleted_at': null, 'quantity': 2},
        ],
        'locations': <Map<String, Object?>>[
          {'id': 1, 'name': '阳台', 'is_deleted': 0, 'created_at': now, 'updated_at': now, 'remark': null},
        ],
        'item_locations': <Map<String, Object?>>[
          {'id': 1, 'item_id': 1, 'location_id': 1, 'is_deleted': 0, 'created_at': now, 'updated_at': now, 'raw_text': null, 'tags': null},
        ],
        'borrowers': <Map<String, Object?>>[
          {'id': 1, 'name': '张三', 'is_deleted': 0, 'created_at': now, 'updated_at': now, 'deleted_at': null},
        ],
        // 关键：没有 is_deleted / deleted_at 两列（V3.7 导出的原样）。
        'loans': <Map<String, Object?>>[
          {'id': 1, 'item_id': 1, 'item_name': '梯子', 'borrower_name': '张三', 'quantity': 2, 'returned_qty': 0, 'borrowed_at': now, 'due_at': now + 3 * 86400000, 'returned_at': null, 'is_partial': 0, 'updated_at': now},
        ],
      };
      await db.restoreBackup(oldBackup);
      final loans = await db.getAllLoans();
      expect(loans, hasLength(1), reason: '旧备份的借出记录要能恢复出来');
      expect(loans.single.isDeleted, isFalse, reason: '缺列按未删读');
      expect(await db.getDeletedLoans(), isEmpty);
    });

    test('备份往返：已软删的借出记录导出→恢复后仍在回收站', () async {
      final loan = await db.lendItem('梯子', '张三');
      await db.deleteLoan(loan.id!);
      final backup = await db.exportBackup();
      final loanRows = (backup['loans'] as List).cast<Map<String, Object?>>();
      expect(loanRows.single['is_deleted'], 1);

      final otherPath = p.join(tempDir.path, 'restore_v38.db');
      final other = newDb(path: otherPath);
      await other.restoreBackup(backup);
      expect(await other.getAllLoans(), isEmpty);
      final restored = await other.getDeletedLoans();
      expect(restored, hasLength(1));
      expect(restored.single.itemName, '梯子');
    });
  });

}
