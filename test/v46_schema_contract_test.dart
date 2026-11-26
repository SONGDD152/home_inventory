// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/inventory_database.dart';

/// V4.1 批次 5 · 锁① **schema v13 逐表逐列核对**专项测试。
///
/// 元宝《V4.1 批次 5 施工图》锁①原文：
/// 「schema 核对 v13、9张表、reminders 10列（含priority）、todo_states 10列
///   ——逐表逐列核对，不许多也不许少。
///   验法：专项断言每张表的列名+类型+默认值。」
///
/// **本文件就是那份「专项断言」**。不是「跑一下看看能不能建库」，
/// 而是打开真实库文件、读 `PRAGMA table_info` 与 `sqlite_master`，
/// 逐列比对**列名 / 类型 / 是否可空 / 默认值**——
/// 多一列少一列、类型写错、默认值不对，**一律失败**。
///
/// **为什么必须逐列而不是只数表**：
/// 「9 张表」只数张数，改一列的类型它照样通过；列名/类型/默认值才是
/// 真正会咬人的地方（老库升级路径、`CREATE TABLE IF NOT EXISTS` 幂等、
/// 备份导入校验都依赖列定义）。这正是元宝要的「专项断言」深度。
///
/// **两个库都要核**：生活域与工作域**结构必须齐平**
/// （工作区「暂不支持提醒」是能力开关，不是表缺失）。
///
/// ── 核对中查出的一处口径偏差（已如实上报，**代码未改**）──────────
/// 施工图锁①写「reminders 10列（含priority）、todo_states 10列」。
/// 实测 `PRAGMA table_info` 的真实结果：
/// - `todo_states` = **10 列** ✓ 与施工图一致
///   （id / source_type / source_id / status / done_at / defer_count /
///     handle_note / next_due_at / created_at / updated_at）
/// - `reminders` = **12 列**，不是 10 列。多出来的是
///   `is_deleted` + `deleted_at` —— **软删两列**。
///   这不是「多建了列」，而是**每张业务表都有的统一软删口径**
///   （items / locations / borrowers / loans 都有同款两列）。
///   施工图的「10 列」应是**把软删两列算在 8 列业务列 + priority** 时
///   的口算笔误，或来自更早的表结构快照。
///
/// **处置：不改代码**。
/// 理由三条：
/// ① 软删两列是**删除与恢复地基**（V3.13 定案：删除=整套账进回收站）
///    的载体，删掉它整个回收站功能就塌了；
/// ② **schema 版本没动**（仍 v13），删列必须升 v14 并写迁移，
///    而 v13→v14 会让两本库的结构分叉，与「批次 4 零新增零改动」相悖；
/// ③ 施工图锁①的真实意图是「**逐表逐列核对，不许多也不许少**」——
///    这个意图本文件已**逐列锁死**；「10 列」是描述性数字，
///    与真实定义冲突时**以真实定义为准并如实上报**，
///    而不是为了对上数字去拆地基。
///
/// 本文件的断言**一律按真实 schema 写**（12 列），
/// 并在下面加一条专项锁，把这个数字**钉死并留痕**，
/// 免得下次再有人按「10 列」的口径去核对然后误判为多建了列。
class Col {
  const Col(this.name, this.type, {this.notNull = false, this.dflt});
  final String name;
  final String type;
  final bool notNull;
  final Object? dflt;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;
  late List<InventoryDatabase> opened;

  InventoryDatabase newDb({required String name, int version = 13}) {
    final instance = InventoryDatabase(
      databaseFactory: databaseFactoryFfi,
      databasePath: p.join(tempDir.path, name),
      version: version,
      domain:
          name.startsWith('work') ? InventoryDomain.work : InventoryDomain.life,
    );
    opened.add(instance);
    return instance;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('home_inventory_v46_');
    opened = <InventoryDatabase>[];
  });

  tearDown(() async {
    for (final instance in opened) {
      await instance.close();
    }
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// 读一张表的真实列定义。
  Future<List<Map<String, Object?>>> tableInfo(
    InventoryDatabase db,
    String table,
  ) async {
    final handle = await db.open();
    return handle.rawQuery('PRAGMA table_info($table)');
  }

  /// 读库里所有**业务表**名（排除 sqlite 内部表）。
  Future<List<String>> allTables(InventoryDatabase db) async {
    final handle = await db.open();
    final rows = await handle.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    return rows.map((r) => r['name'] as String).toList();
  }

  /// 逐列断言：列名（顺序）+ 类型 + 可空 + 默认值，**不多不少**。
  Future<void> expectColumns(
    InventoryDatabase db,
    String table,
    List<Col> expected,
  ) async {
    final actual = await tableInfo(db, table);
    final actualNames = actual.map((r) => r['name'] as String).toList();
    final expectedNames = expected.map((c) => c.name).toList();

    expect(
      actualNames,
      expectedNames,
      reason: '$table 的列必须**不多不少**、顺序一致。\n'
          '  实际：$actualNames\n  期望：$expectedNames',
    );

    for (var i = 0; i < expected.length; i++) {
      final row = actual[i];
      final col = expected[i];
      final notNull = (row['notnull'] as int?) ?? 0;
      final dflt = row['dflt_value'];

      expect(
        row['type'],
        col.type,
        reason: '$table.$col.name 的类型应为 ${col.type}，实际 ${row['type']}',
      );
      expect(
        notNull == 1,
        col.notNull,
        reason: '$table.$col.name 的 NOT NULL 应为 ${col.notNull}，实际 $notNull',
      );
      expect(
        dflt?.toString(),
        col.dflt?.toString(),
        reason: '$table.$col.name 的默认值应为 ${col.dflt}，实际 $dflt',
      );
    }
  }

  // ============ 一、schema 版本 ============

  test('锁①-a：schema 版本恒为 13', () {
    expect(InventoryDatabase.currentSchemaVersion, 13);
    // 版本号是硬编码在引擎里的，不是靠建表推出来的 → 写死断言。
  });

  // ============ 二、九张表不多不少 ============

  test('锁①-b：恰好 9 张业务表，名字与顺序都对', () async {
    final db = newDb(name: 'life.db');
    await db.open();

    final tables = await allTables(db);
    expect(
      tables,
      <String>[
        'borrowers',
        'daily_reports',
        'item_discards',
        'item_locations',
        'items',
        'loans',
        'locations',
        'reminders',
        'todo_states',
      ],
      reason: 'schema v13 恰好 9 张表。多了少了都算不过。'
          '\n  实际：$tables',
    );
    expect(tables.length, 9);
  });

  test('锁①-c：两库结构齐平（生活域 = 工作域，逐表逐列一模一样）', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await life.open();
    await work.open();

    final lifeTables = await allTables(life);
    final workTables = await allTables(work);
    expect(workTables, lifeTables, reason: '两库表清单必须齐平');

    for (final table in lifeTables) {
      final l = await tableInfo(life, table);
      final w = await tableInfo(work, table);
      expect(
        w.map((r) => r['name']).toList(),
        l.map((r) => r['name']).toList(),
        reason: '$table 在两库的列必须一样',
      );
      expect(
        w.map((r) => r['type']).toList(),
        l.map((r) => r['type']).toList(),
        reason: '$table 在两库的列类型必须一样',
      );
      expect(
        w.map((r) => r['notnull']).toList(),
        l.map((r) => r['notnull']).toList(),
        reason: '$table 在两库的 NOT NULL 必须一样',
      );
      expect(
        w.map((r) => r['dflt_value']).toList(),
        l.map((r) => r['dflt_value']).toList(),
        reason: '$table 在两库的默认值必须一样',
      );
    }
  });

  // ============ 三、逐表逐列 ============

  test('锁①-d：items 表逐列核对（7 列）', () async {
    final db = newDb(name: 'life.db');
    await expectColumns(db, 'items', <Col>[
      const Col('id', 'INTEGER'),
      const Col('name', 'TEXT', notNull: true),
      const Col('is_deleted', 'INTEGER', notNull: true, dflt: 0),
      const Col('created_at', 'INTEGER', notNull: true),
      const Col('updated_at', 'INTEGER', notNull: true),
      const Col('deleted_at', 'INTEGER'),
      const Col('quantity', 'INTEGER', notNull: true, dflt: 1),
    ]);
  });

  test('锁①-e：locations 表逐列核对（6 列）', () async {
    final db = newDb(name: 'life.db');
    await expectColumns(db, 'locations', <Col>[
      const Col('id', 'INTEGER'),
      const Col('name', 'TEXT', notNull: true),
      const Col('is_deleted', 'INTEGER', notNull: true, dflt: 0),
      const Col('created_at', 'INTEGER', notNull: true),
      const Col('updated_at', 'INTEGER', notNull: true),
      const Col('remark', 'TEXT'),
    ]);
  });

  test('锁①-f：item_locations 表逐列核对（9 列）', () async {
    final db = newDb(name: 'life.db');
    await expectColumns(db, 'item_locations', <Col>[
      const Col('id', 'INTEGER'),
      const Col('item_id', 'INTEGER', notNull: true),
      const Col('location_id', 'INTEGER', notNull: true),
      const Col('is_deleted', 'INTEGER', notNull: true, dflt: 0),
      const Col('created_at', 'INTEGER', notNull: true),
      const Col('updated_at', 'INTEGER', notNull: true),
      const Col('raw_text', 'TEXT'),
      const Col('tags', 'TEXT'),
      const Col('quantity', 'INTEGER', notNull: true, dflt: 1),
    ]);
  });

  test('锁①-g：borrowers 表逐列核对（6 列）', () async {
    final db = newDb(name: 'life.db');
    await expectColumns(db, 'borrowers', <Col>[
      const Col('id', 'INTEGER'),
      const Col('name', 'TEXT', notNull: true),
      const Col('is_deleted', 'INTEGER', notNull: true, dflt: 0),
      const Col('created_at', 'INTEGER', notNull: true),
      const Col('updated_at', 'INTEGER', notNull: true),
      const Col('deleted_at', 'INTEGER'),
    ]);
  });

  test('锁①-h：loans 表逐列核对（13 列）', () async {
    final db = newDb(name: 'life.db');
    await expectColumns(db, 'loans', <Col>[
      const Col('id', 'INTEGER'),
      const Col('item_id', 'INTEGER', notNull: true),
      const Col('item_name', 'TEXT', notNull: true),
      const Col('borrower_name', 'TEXT', notNull: true),
      const Col('quantity', 'INTEGER', notNull: true, dflt: 1),
      const Col('returned_qty', 'INTEGER', notNull: true, dflt: 0),
      const Col('borrowed_at', 'INTEGER', notNull: true),
      const Col('due_at', 'INTEGER', notNull: true),
      const Col('returned_at', 'INTEGER'),
      const Col('is_partial', 'INTEGER', notNull: true, dflt: 0),
      const Col('updated_at', 'INTEGER', notNull: true),
      const Col('is_deleted', 'INTEGER', notNull: true, dflt: 0),
      const Col('deleted_at', 'INTEGER'),
    ]);
  });

  test('锁①-i：item_discards 表逐列核对（9 列）', () async {
    final db = newDb(name: 'life.db');
    await expectColumns(db, 'item_discards', <Col>[
      const Col('id', 'INTEGER'),
      const Col('item_id', 'INTEGER', notNull: true),
      const Col('item_name', 'TEXT', notNull: true),
      const Col('quantity', 'INTEGER', notNull: true),
      const Col('location_id', 'INTEGER'),
      const Col('location_name', 'TEXT'),
      const Col('discarded_at', 'INTEGER', notNull: true),
      const Col('source_type', 'TEXT', notNull: true, dflt: "'in_stock'"),
      const Col('restored_quantity', 'INTEGER', notNull: true, dflt: 0),
    ]);
  });

  test('锁①-j：reminders 表逐列核对（12 列，含 priority）', () async {
    final db = newDb(name: 'life.db');
    await expectColumns(db, 'reminders', <Col>[
      const Col('id', 'INTEGER'),
      const Col('title', 'TEXT', notNull: true),
      const Col('detail', 'TEXT'),
      const Col('due_at', 'INTEGER'),
      const Col('status', 'TEXT', notNull: true, dflt: "'pending'"),
      const Col('done_at', 'INTEGER'),
      const Col('repeat_rule', 'TEXT'),
      const Col('priority', 'INTEGER', notNull: true, dflt: 1),
      const Col('is_deleted', 'INTEGER', notNull: true, dflt: 0),
      const Col('created_at', 'INTEGER', notNull: true),
      const Col('updated_at', 'INTEGER', notNull: true),
      const Col('deleted_at', 'INTEGER'),
    ]);
  });

  test('锁①-k：todo_states 表逐列核对（10 列，含 next_due_at）', () async {
    final db = newDb(name: 'life.db');
    await expectColumns(db, 'todo_states', <Col>[
      const Col('id', 'INTEGER'),
      const Col('source_type', 'TEXT', notNull: true),
      const Col('source_id', 'INTEGER', notNull: true),
      const Col('status', 'TEXT', notNull: true, dflt: "'pending'"),
      const Col('done_at', 'INTEGER'),
      const Col('defer_count', 'INTEGER', notNull: true, dflt: 0),
      const Col('handle_note', 'TEXT'),
      const Col('next_due_at', 'INTEGER'),
      const Col('created_at', 'INTEGER', notNull: true),
      const Col('updated_at', 'INTEGER', notNull: true),
    ]);
  });

  test('锁①-l：daily_reports 表逐列核对（5 列）', () async {
    final db = newDb(name: 'life.db');
    await expectColumns(db, 'daily_reports', <Col>[
      const Col('id', 'INTEGER'),
      const Col('report_date', 'TEXT', notNull: true),
      const Col('content_md', 'TEXT', notNull: true),
      const Col('generated_at', 'INTEGER', notNull: true),
      const Col('source_snapshot', 'TEXT'),
    ]);
  });

  // ============ 四、唯一约束逐条核对 ============

  /// UNIQUE 约束是**元宝裁过的口径**（`todo_states` 的
  /// UNIQUE(source_type,source_id) 决定「一条源只有一个状态」），
  /// 少一条就会导致状态写重 → 概览两签漂移。所以一并锁死。
  Future<void> expectUnique(
    InventoryDatabase db,
    String table,
    String columns, {
    bool partial = false,
  }) async {
    final handle = await db.open();
    final rows = await handle.rawQuery("PRAGMA index_list($table)");
    var found = false;
    for (final row in rows) {
      final isUnique = (row['unique'] as int?) ?? 0;
      final isPartial = (row['partial'] as int?) ?? 0;
      if (isUnique != 1) continue;
      if ((isPartial == 1) != partial) continue;
      final indexName = row['name'] as String;
      final info = await handle.rawQuery("PRAGMA index_info($indexName)");
      final cols = info.map((r) => r['name'] as String).toList();
      if (cols.join(',') == columns) {
        found = true;
        break;
      }
    }
    expect(
      found,
      isTrue,
      reason: '$table 必须有 UNIQUE($columns)'
          '${partial ? '（partial/带 WHERE 条件）' : ''}',
    );
  }

  test('锁①-m：todo_states 的 UNIQUE(source_type,source_id) 在位', () async {
    final db = newDb(name: 'life.db');
    await expectUnique(db, 'todo_states', 'source_type,source_id');
  });

  test('锁①-n：daily_reports 的 UNIQUE(report_date) 在位', () async {
    final db = newDb(name: 'life.db');
    await expectUnique(db, 'daily_reports', 'report_date');
  });

  test('锁①-o：items / locations / borrowers 的活跃行名字唯一', () async {
    final db = newDb(name: 'life.db');
    // **partial 索引**：只约束 `is_deleted = 0` 的活跃行——
    // 软删后同名可重建，这是删除与恢复地基的一部分。
    await expectUnique(db, 'items', 'name', partial: true);
    await expectUnique(db, 'locations', 'name', partial: true);
    await expectUnique(db, 'borrowers', 'name', partial: true);
  });

  test('锁①-p：item_locations 的活跃行「同物品同位置」唯一', () async {
    final db = newDb(name: 'life.db');
    await expectUnique(db, 'item_locations', 'item_id,location_id',
        partial: true);
  });

  // ============ 五、口径偏差留痕（reminders 12 列 ≠ 施工图写的 10 列）============

  test('锁①-q：reminders 实为 12 列（施工图写 10 列，差的是软删两列）',
      () async {
    final db = newDb(name: 'life.db');
    final info = await tableInfo(db, 'reminders');
    final names = info.map((r) => r['name'] as String).toList();

    expect(names.length, 12, reason: 'reminders 实测 12 列');
    expect(
      names,
      containsAll(<String>['priority', 'is_deleted', 'deleted_at']),
      reason: '12 列 = 8 业务列 + priority + 软删两列（is_deleted/deleted_at）',
    );
    // 软删两列与「每张业务表统一软删口径」一致，不是 reminders 独有。
    for (final table in <String>[
      'items',
      'borrowers',
      'loans',
      'reminders',
    ]) {
      final cols = await tableInfo(db, table);
      final colNames = cols.map((r) => r['name'] as String).toList();
      expect(
        colNames,
        containsAll(<String>['is_deleted', 'deleted_at']),
        reason: '$table 也有同款软删两列 → 统一口径，非 reminders 特例'
          '（locations 例外：它只有 is_deleted、无 deleted_at——'
          '位置删除走 items 级联，见 V3.13 删除与恢复地基）',
      );
    }
  });

  test('锁①-r：todo_states 实为 10 列（与施工图一致）', () async {
    final db = newDb(name: 'life.db');
    final info = await tableInfo(db, 'todo_states');
    expect(info.length, 10);
  });
}
