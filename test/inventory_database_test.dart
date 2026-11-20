import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/home_inventory.dart';

void main() {
  setUpAll(() {
    // 让纯 Dart VM 侧也能用 sqflite；生产代码仍走默认工厂。
    sqfliteFfiInit();
  });

  late Directory tempDir;
  late String dbPath;
  late InventoryDatabase db;
  late List<InventoryDatabase> opened;

  InventoryDatabase newDb({int version = 2, String? path}) {
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
    // 先关闭本测试打开的所有连接，再删目录：Windows 上文件被占用时删不掉。
    for (final instance in opened) {
      await instance.close();
    }
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Item sample(String name, String location) => Item(
        name: name,
        location: location,
        createdAt: 1700000000000,
        updatedAt: 1700000000000,
      );

  // ---- 第一阶段原有四个验收点 ----

  test('空库查询返回空列表', () async {
    expect(await db.getAll(), isEmpty);
  });

  test('重开临时文件库后仍能查到', () async {
    final id = await db.insert(sample('梯子', '阳台'));
    expect(id, greaterThan(0));
    expect(db.isOpen, isTrue);

    await db.close();
    // 证据 1：旧实例的底层连接确实被 dispose，而不是仍持有连接。
    expect(db.isOpen, isFalse);

    // 证据 2：重开拿到的是全新实例，不是复用旧对象。
    final reopened = newDb();
    expect(identical(reopened, db), isFalse);
    expect(reopened.isOpen, isFalse); // 尚未 open

    final items = await reopened.getAll();
    expect(reopened.isOpen, isTrue);
    expect(items, hasLength(1));
    expect(items.first.id, id);
    expect(items.first.name, '梯子');
    expect(items.first.location, '阳台');
  });

  test('软删除后默认查不到', () async {
    final id = await db.insert(sample('梯子', '阳台'));
    expect(await db.softDelete(id), 1);

    expect(await db.getAll(), isEmpty);

    final all = await db.getAll(includeDeleted: true);
    expect(all, hasLength(1));
    expect(all.first.id, id);
    expect(all.first.isDeleted, isTrue);
  });

  test('同名两条记录删一条，剩下那条 id 与位置都正确', () async {
    final idA = await db.insert(sample('梯子', '阳台'));
    final idB = await db.insert(sample('梯子', '储物间'));
    expect(idA, isNot(idB));

    expect(await db.softDelete(idA), 1);

    final items = await db.getAll();
    expect(items, hasLength(1));
    expect(items.single.id, idB);
    expect(items.single.name, '梯子');
    expect(items.single.location, '储物间');

    final all = await db.getAll(includeDeleted: true);
    expect(all, hasLength(2));
  });

  test('软删除后同名再插入，getAll 不混入已删旧记录', () async {
    final oldId = await db.insert(sample('梯子', '阳台'));
    expect(await db.softDelete(oldId), 1);
    final newId = await db.insert(sample('梯子', '储物间'));
    expect(newId, isNot(oldId));

    final items = await db.getAll();
    expect(items, hasLength(1));
    expect(items.single.id, newId);
    expect(items.single.location, '储物间');
    expect(items.single.isDeleted, isFalse);

    final all = await db.getAll(includeDeleted: true);
    expect(all, hasLength(2));
    expect(all.map((e) => e.id), containsAll(<int>[oldId, newId]));
    expect(all.firstWhere((e) => e.id == oldId).isDeleted, isTrue);
  });

  test('getById 默认过滤软删除，includeDeleted 可取回', () async {
    final id = await db.insert(sample('扳手', '工具箱'));
    expect((await db.getById(id))?.name, '扳手');

    expect(await db.softDelete(id), 1);
    expect(await db.getById(id), isNull);
    expect((await db.getById(id, includeDeleted: true))?.id, id);
    expect(await db.getById(99999), isNull);
  });

  // ---- 参数校验 ----

  test('insert 拒绝空名称与空位置', () async {
    expect(
      db.insert(sample('', '阳台')),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      db.insert(sample('梯子', '   ')),
      throwsA(isA<ArgumentError>()),
    );
    expect(await db.getAll(), isEmpty);
  });

  test('insert 裁剪首尾空白，规范化后再入库', () async {
    final id = await db.insert(sample('  梯子  ', '  阳台 '));
    final item = await db.getById(id);
    expect(item?.name, '梯子');
    expect(item?.location, '阳台');
  });

  // ---- 事务幂等：连点两下不出重复 ----

  test('upsert 连点两下只产生一条记录，第二次返回 created=false', () async {
    final first = await db.upsert(sample('梯子', '阳台'));
    expect(first.created, isTrue);

    final second = await db.upsert(sample('梯子', '阳台'));
    expect(second.created, isFalse);
    expect(second.id, first.id);

    final items = await db.getAll();
    expect(items, hasLength(1));
    expect(items.single.id, first.id);
    expect(items.single.location, '阳台');
  });

  test('upsert 同名不同位置是两条合法记录', () async {
    final a = await db.upsert(sample('梯子', '阳台'));
    final b = await db.upsert(sample('梯子', '储物间'));
    expect(b.id, isNot(a.id));
    expect(await db.getAll(), hasLength(2));
  });

  test('upsert 空白裁剪后视为同一条（绕过唯一约束的写法被堵住）', () async {
    final a = await db.upsert(sample('梯子', '阳台'));
    final b = await db.upsert(sample('  梯子  ', ' 阳台 '));
    expect(b.created, isFalse);
    expect(b.id, a.id);
    expect(await db.getAll(), hasLength(1));
  });

  test('软删除后同名同位置 upsert 生成新记录，不复活旧行', () async {
    final old = await db.upsert(sample('梯子', '阳台'));
    expect(await db.softDelete(old.id), 1);

    final fresh = await db.upsert(sample('梯子', '阳台'));
    expect(fresh.created, isTrue);
    expect(fresh.id, isNot(old.id));

    final items = await db.getAll();
    expect(items, hasLength(1));
    expect(items.single.id, fresh.id);
    expect(items.single.isDeleted, isFalse);

    final all = await db.getAll(includeDeleted: true);
    expect(all, hasLength(2));
    expect(all.firstWhere((e) => e.id == old.id).isDeleted, isTrue);
  });

  // ---- 数据库层兜底 ----

  test('部分唯一索引兜底：绕过 upsert 直接 insert 重复记录被拒', () async {
    await db.insert(sample('扳手', '工具箱'));
    expect(
      db.insert(sample('扳手', '工具箱')),
      throwsA(isA<DatabaseException>()),
    );

    // 已软删的旧行不占用唯一位，仍可插入同名同位置。
    final all = await db.getAll(includeDeleted: true);
    final first = all.single;
    expect(await db.softDelete(first.id!), 1);
    final newId = await db.insert(sample('扳手', '工具箱'));
    expect(newId, isNot(first.id));
  });

  // ---- 升级迁移：异常路径 ----

  test('v1 库升级到 v2 时补建唯一索引', () async {
    final v1Path = p.join(tempDir.path, 'v1.db');
    final v1db = await databaseFactoryFfi.openDatabase(
      v1Path,
      options: OpenDatabaseOptions(
        version: 1,
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
        },
      ),
    );
    await v1db.close(); // 必须关闭，否则 v2 打开会卡在旧连接上

    final upgraded = newDb(version: 2, path: v1Path);
    final id = await upgraded.insert(sample('螺丝刀', '工具箱'));
    expect(id, greaterThan(0));
    expect(
      upgraded.insert(sample('螺丝刀', '工具箱')),
      throwsA(isA<DatabaseException>()),
    );
  });
}
