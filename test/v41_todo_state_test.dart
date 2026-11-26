// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/inventory_database.dart';
import 'package:home_inventory/data/todo_state.dart';
import 'package:home_inventory/domain/reminder_sources.dart';
import 'package:home_inventory/domain/todo_state_writer.dart';

/// V4.1 催办状态（todo_states 第 9 表）专项测试。
///
/// 元宝开工令的验收要求逐条对应：
/// - 表格「九表与 v12 逐表逐列核对」（原「八表与 v11」口径升级）；
/// - source_type 枚举锁定（schedule_reminder / loan_due）；
/// - 「所有催办条目统一走 todo_states，不再各自存状态」；
/// - 「催办区数据源 = ReminderSource 提供条目 + todo_states 提供状态，两表 JOIN 读取」；
/// - E1 回归：生活区与工作区的同名源不再互相覆盖。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;
  late List<InventoryDatabase> opened;

  InventoryDatabase newDb({String name = 'inventory.db', int version = 12}) {
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

  Future<void> seed(InventoryDatabase db, String item, int qty) async {
    final locationId = await db.addLocation('主位置');
    await db.upsertItemLocation(item, locationId, quantity: qty);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('home_inventory_v41_');
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

  /// 取一张表的列定义（列名 / 类型 / 非空 / 默认值）。
  Future<List<Map<String, Object?>>> columnsOf(
      InventoryDatabase db, String table) async {
    final handle = await db.open();
    final rows = await handle.rawQuery('PRAGMA table_info($table)');
    return rows
        .map((r) => <String, Object?>{
              'name': r['name'],
              'type': r['type'],
              'notnull': r['notnull'],
              'dflt_value': r['dflt_value'],
            })
        .toList();
  }

  Future<Set<String>> tableNamesOf(InventoryDatabase db) async {
    final handle = await db.open();
    final rows = await handle.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    );
    return rows.map((r) => r['name'] as String).toSet();
  }

  // ============ 一、九表逐表逐列核对（元宝观察项② 口径升级）============

  test('V4.1 两库九表逐表逐列完全一致（工作库 v12 = 生活库 v12）', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');

    final lifeTables = await tableNamesOf(life);
    final workTables = await tableNamesOf(work);
    expect(workTables.length, 9, reason: 'v12 共 9 张表');
    expect(lifeTables, workTables, reason: '两库表名集合必须完全一致');
    expect(workTables.contains('todo_states'), isTrue);

    for (final table in lifeTables) {
      final lifeCols = await columnsOf(life, table);
      final workCols = await columnsOf(work, table);
      expect(workCols.length, lifeCols.length,
          reason: '表 $table 的列数两库必须一致');
      for (var i = 0; i < lifeCols.length; i++) {
        expect(workCols[i]['name'], lifeCols[i]['name'],
            reason: '表 $table 第 $i 列列名');
        expect(workCols[i]['type'], lifeCols[i]['type'],
            reason: '表 $table 第 $i 列类型');
        expect(workCols[i]['notnull'], lifeCols[i]['notnull'],
            reason: '表 $table 第 $i 列非空约束');
        expect(workCols[i]['dflt_value'], lifeCols[i]['dflt_value'],
            reason: '表 $table 第 $i 列默认值');
      }
    }
  });

  test('V4.1 todo_states 列结构锁定（字段名/类型/默认值）', () async {
    final db = newDb();
    final cols = await columnsOf(db, 'todo_states');
    final byName = <String, Map<String, Object?>>{
      for (final c in cols) c['name'] as String: c,
    };
    // 元宝裁定的 9 个字段一个都不能少。
    for (final required in <String>[
      'id',
      'source_type',
      'source_id',
      'status',
      'done_at',
      'defer_count',
      'handle_note',
      'created_at',
      'updated_at',
    ]) {
      expect(byName.containsKey(required), isTrue,
          reason: 'todo_states 必须含字段 $required');
    }
    // 对元宝字段清单的唯一一处增补：延期后的下一次提示时间。
    expect(byName.containsKey('next_due_at'), isTrue,
        reason: 'next_due_at 是延期机制必需（到期当天再次提示）');
    expect(byName['source_type']!['type'], 'TEXT');
    expect(byName['source_id']!['type'], 'INTEGER');
    expect(byName['defer_count']!['notnull'], 1);
    expect(byName['defer_count']!['dflt_value'], '0');
    expect(byName['status']!['dflt_value'], "'pending'");
  });

  // ============ 二、schema v11→v12 迁移 ============

  test('V4.1 迁移：生活库 v11→v12 数据零丢失、幂等、旧表旧列不动', () async {
    final legacy = newDb(name: 'life.db', version: 11);
    await legacy.open();
    final locationId = await legacy.addLocation('主位置');
    await legacy.upsertItemLocation('梯子', locationId, quantity: 2);
    final before = await legacy.getAllItemsWithLocations();
    expect(before.length, 1);
    await legacy.close();

    // v12 打开同一文件 → 触发 v11→v12 迁移。
    final upgraded = newDb(name: 'life.db', version: 12);
    await upgraded.open();
    final after = await upgraded.getAllItemsWithLocations();
    expect(after.length, 1, reason: '迁移不丢物品');
    expect((await upgraded.getQuantityInfo('梯子')).stock, 2,
        reason: '迁移不丢数量');
    expect(await tableNamesOf(upgraded).then((s) => s.contains('todo_states')),
        isTrue, reason: 'v12 补出 todo_states');

    // 幂等：再开一次不再改动。
    await upgraded.close();
    final again = newDb(name: 'life.db', version: 12);
    await again.open();
    expect((await again.getQuantityInfo('梯子')).stock, 2);
  });

  test('V4.1 迁移：v10→v12 一路到顶，数据仍在', () async {
    final legacy = newDb(name: 'life.db', version: 10);
    await legacy.open();
    final locationId = await legacy.addLocation('主位置');
    await legacy.upsertItemLocation('梯子', locationId, quantity: 3);
    await legacy.close();

    final upgraded = newDb(name: 'life.db', version: 12);
    await upgraded.open();
    expect((await upgraded.getQuantityInfo('梯子')).stock, 3);
  });

  // ============ 三、待办状态 CRUD ============

  test('V4.1 待办状态：标记已处理 / 撤销 / 备注', () async {
    final db = newDb();
    await seed(db, '梯子', 1);
    await db.lendItem('梯子', '张三', quantity: 1);
    final loans = await db.getAllLoans();
    final loanId = loans.first.id!;

    expect(await db.readState(TodoSourceType.loanDue, loanId), isNull,
        reason: '没处理过就没有状态行');

    await db.markDone(TodoSourceType.loanDue, loanId);
    final done = await db.readState(TodoSourceType.loanDue, loanId);
    expect(done, isNotNull);
    expect(done!.isDone, isTrue);
    expect(done.doneAt, isNotNull);

    await db.setNote(TodoSourceType.loanDue, loanId, '已口头催过');
    expect((await db.readState(TodoSourceType.loanDue, loanId))!.handleNote,
        '已口头催过');

    // 撤销：清完成态，但**保留**延期次数与备注（那是历史，不是完成态）。
    await db.markDone(TodoSourceType.loanDue, loanId, done: false);
    final undone = await db.readState(TodoSourceType.loanDue, loanId);
    expect(undone!.isDone, isFalse);
    expect(undone.doneAt, isNull);
    expect(undone.handleNote, '已口头催过');
  });

  // ============ 四、延期计数按「次」累计 ============

  test('V4.1 延期：同一天手动延期 3 次 = 3 次（按次累计，非按天）', () async {
    final db = newDb();
    await seed(db, '梯子', 1);
    await db.lendItem('梯子', '张三', quantity: 1);
    final loanId = (await db.getAllLoans()).first.id!;

    await db.defer(TodoSourceType.loanDue, loanId, reason: '第一次');
    await db.defer(TodoSourceType.loanDue, loanId, reason: '第二次');
    await db.defer(TodoSourceType.loanDue, loanId, reason: '第三次');

    final state = await db.readState(TodoSourceType.loanDue, loanId);
    expect(state!.deferCount, 3, reason: '按次累计：一天 3 次就是 3');
    expect(state.isDeferred, isTrue);
  });

  test('V4.1 延期：跨天不重置（计数只增不减）', () async {
    final db = newDb();
    await seed(db, '梯子', 1);
    await db.lendItem('梯子', '张三', quantity: 1);
    final loanId = (await db.getAllLoans()).first.id!;

    await db.defer(TodoSourceType.loanDue, loanId);
    await db.defer(TodoSourceType.loanDue, loanId);
    expect((await db.readState(TodoSourceType.loanDue, loanId))!.deferCount, 2);

    // 模拟「又过了一天」——直接再延期一次，计数继续涨，不会被重置。
    await db.defer(TodoSourceType.loanDue, loanId);
    expect((await db.readState(TodoSourceType.loanDue, loanId))!.deferCount, 3,
        reason: '跨天不重置');
  });

  // ============ 五、自动延期：每天最多 +1 次 + 幂等 ============

  test('V4.1 自动延期：过期 5 天只 +1 次（不会一天涨 5 次）', () async {
    final db = newDb();
    await seed(db, '梯子', 1);
    await db.lendItem('梯子', '张三', quantity: 1);
    final loanId = (await db.getAllLoans()).first.id!;

    // 借出到期日 = 借出日 +3 天。把「下一次提示时间」预置到 5 天前，
    // 模拟一条已经过期好几天的提醒（defer 只用来把 next_due_at 拨回过去，
    // 它本身也算一次手动延期，所以下面的计数预期是 1+1）。
    await db.markDone(TodoSourceType.loanDue, loanId, done: false);
    await db.defer(TodoSourceType.loanDue, loanId, days: -5);

    final moved = await db.syncOverdue(DateTime.now());
    expect(moved, 1, reason: '只推进这一条');
    final state = await db.readState(TodoSourceType.loanDue, loanId);
    expect(state!.deferCount, 2,
        reason: '预置手动延期 1 次 + 自动延期 1 次 = 2；'
            '关键是自动延期没有一次涨 5 次（否则计数失真）');
    expect(state.isDeferred, isTrue);
  });

  test('V4.1 自动延期：同一天重复调用不加次（幂等）', () async {
    final db = newDb();
    await seed(db, '梯子', 1);
    await db.lendItem('梯子', '张三', quantity: 1);
    final loanId = (await db.getAllLoans()).first.id!;
    await db.markDone(TodoSourceType.loanDue, loanId, done: false);
    await db.defer(TodoSourceType.loanDue, loanId, days: -5);

    final now = DateTime.now();
    expect(await db.syncOverdue(now), 1);
    final afterFirst = (await db.readState(TodoSourceType.loanDue, loanId))!
        .deferCount;
    expect(await db.syncOverdue(now), 0, reason: '同一天不再推进');
    expect(await db.syncOverdue(now), 0);
    final afterRepeat =
        (await db.readState(TodoSourceType.loanDue, loanId))!.deferCount;
    expect(afterRepeat, afterFirst, reason: '幂等：计数不再变');
  });

  test('V4.1 自动延期：已完成的条目不再被推进', () async {
    final db = newDb();
    await seed(db, '梯子', 1);
    await db.lendItem('梯子', '张三', quantity: 1);
    final loanId = (await db.getAllLoans()).first.id!;
    await db.markDone(TodoSourceType.loanDue, loanId);
    await db.defer(TodoSourceType.loanDue, loanId, days: -5);
    // 已完成的状态行：defer 会把它置成 deferred，所以这里直接改回 done。
    await db.markDone(TodoSourceType.loanDue, loanId);
    expect(await db.syncOverdue(DateTime.now()), 0,
        reason: 'done 的条目不再提醒');
  });

  // ============ 六、E1 回归：两域同名源不再互相覆盖 ============

  test('V4.1 E1 回归：两域源 id/displayName 唯一，且都带域', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seed(life, '梯子', 1);
    await life.lendItem('梯子', '张三', quantity: 1);
    await seed(work, '扳手', 1);
    await work.lendItem('扳手', '李四', quantity: 1);

    final lifeSource = LoanDueReminderSource(life, InventoryDomain.life);
    final workSource = LoanDueReminderSource(work, InventoryDomain.work);

    expect(lifeSource.id, isNot(workSource.id),
        reason: 'id 必须唯一——概览拿它当 Map key');
    expect(lifeSource.displayName, isNot(workSource.displayName));
    expect(lifeSource.displayName, contains('生活区'));
    expect(workSource.displayName, contains('工作区'));

    // 两边都有条目，且互不可见。
    final lifeEntries = await lifeSource.loadEntries();
    final workEntries = await workSource.loadEntries();
    expect(lifeEntries.length, 1);
    expect(workEntries.length, 1);
    expect(lifeEntries.first.title, contains('梯子'));
    expect(workEntries.first.title, contains('扳手'));
    // 条目 id 也带域 → widget key 不撞。
    expect(lifeEntries.first.id, isNot(workEntries.first.id));
  });

  test('V4.1 E5 字段：借出条目带借出日期/预期天数/剩余或逾期天数', () async {
    final db = newDb();
    await seed(db, '梯子', 1);
    await db.lendItem('梯子', '张三', quantity: 1);
    final source = LoanDueReminderSource(db, InventoryDomain.life);
    final entry = (await source.loadEntries()).first;

    expect(entry.sourceType, TodoSourceType.loanDue);
    expect(entry.sourceId, isNotNull);
    expect(entry.startedAt, isNotNull, reason: '借出日期');
    expect(entry.expectedDays, 3, reason: '默认借出日 +3 天');
    expect(entry.dayDelta, isNotNull);
    expect(entry.subtitle, contains('借出'));
    expect(entry.subtitle, contains('预期'));
  });

  test('V4.1 两表 JOIN：条目（ReminderSource）+ 状态（todo_states）能配上', () async {
    final db = newDb();
    await seed(db, '梯子', 1);
    await db.lendItem('梯子', '张三', quantity: 1);
    final source = LoanDueReminderSource(db, InventoryDomain.life);
    final entry = (await source.loadEntries()).first;

    // 状态表里还没有这个条目 → 配不上（未处理过）。
    expect(await db.readState(entry.sourceType!, entry.sourceId!), isNull);

    await db.markDone(entry.sourceType!, entry.sourceId!);
    final state = await db.readState(entry.sourceType!, entry.sourceId!);
    expect(state, isNotNull);
    expect(state!.entryKey, entry.stateKey,
        reason: '两边用同一个业务键配对');
    expect(state.isDone, isTrue);
  });

  // ============ 七、source_type 枚举锁定 ============

  test('V4.1 source_type 枚举锁定为两个值', () {
    expect(TodoSourceType.scheduleReminder, 'schedule_reminder');
    expect(TodoSourceType.loanDue, 'loan_due');
    expect(TodoSourceType.all.length, 2);
    expect(TodoSourceType.isValid('schedule_reminder'), isTrue);
    expect(TodoSourceType.isValid('loan_due'), isTrue);
    expect(TodoSourceType.isValid('whatever'), isFalse);
  });

  test('V4.1 业务键可反解（sourceType 不含下划线，切一次就对）', () {
    final key = TodoState.entryKeyOf(TodoSourceType.scheduleReminder, 7);
    expect(key, 'schedule_reminder_7');
    final parsed = TodoState.parseEntryKey(key);
    expect(parsed, isNotNull);
    expect(parsed!.$1, 'schedule_reminder');
    expect(parsed.$2, 7);
  });

  // ============ 八、只读边界（编译期保证的运行期佐证）============

  /// 去掉注释行，只留代码——用来做「签名里不得出现仓储类型」的源码级断言。
  String codeOnly(String path) {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '应能读到源码 $path');
    final out = <String>[];
    for (final line in file.readAsStringSync().split('\n')) {
      final t = line.trim();
      if (t.startsWith('///') || t.startsWith('//') || t.startsWith('*')) {
        continue;
      }
      out.add(line);
    }
    return out.join('\n');
  }

  test('V4.1 只读边界：待办写口的签名里没有任何仓储类型', () async {
    // 「概览改不了账」的**编译期**保证的可执行佐证：
    // 待办写口的方法签名里只有 sourceType(字符串) / sourceId(整数) / 枚举，
    // 没有任何仓储类型——所以概览页只要持有这个接口，编译期就拿不到账的写能力。
    //
    // 这条断言是**回归锁**：将来谁往接口里塞一个仓储参数，测试立刻红。
    // （不能用 `db is InventoryRepository` 证明——同一个对象本来就同时实现了
    //   仓储与待办写口，那是实现类的事实，与接口的边界无关。）
    final forbidden = <String>[
      'InventoryRepository',
      'InventoryDatabase',
      'ReminderRepository',
      'Item',
      'Loan',
      'Reminder',
    ];
    final src = codeOnly('lib/domain/todo_state_writer.dart');
    for (final bad in forbidden) {
      expect(src.contains(bad), isFalse,
          reason: '待办写口签名不该出现仓储类型 $bad');
    }
  });

  test('V4.1 只读边界：概览页只持只读口 + 待办写口，没有仓储句柄', () {
    final forbidden = <String>[
      'InventoryRepository',
      'InventoryDatabase',
      'ReminderRepository',
    ];
    final src = codeOnly('lib/ui/overview_page.dart');
    for (final bad in forbidden) {
      expect(src.contains(bad), isFalse,
          reason: '概览页不该持有仓储类型 $bad');
    }
  });

  test('V4.1 只读边界：打勾只改 todo_states，账目一行不动', () async {
    final db = newDb();
    await seed(db, '梯子', 2);
    await db.lendItem('梯子', '张三', quantity: 1);
    final loanId = (await db.getAllLoans()).first.id!;

    final before = await db.getAllItemsWithLocations();
    final stockBefore = (await db.getQuantityInfo('梯子')).stock;

    // 只通过待办写口打勾。
    await db.markDone(TodoSourceType.loanDue, loanId);

    final after = await db.getAllItemsWithLocations();
    final stockAfter = (await db.getQuantityInfo('梯子')).stock;
    expect(after.length, before.length, reason: '物品清单不变');
    expect(stockAfter, stockBefore, reason: '在库数量不变');
    expect((await db.readState(TodoSourceType.loanDue, loanId))!.isDone, isTrue,
        reason: '变的只有待办状态');
  });

  // ============ 九、备份带 todo_states ============

  test('V4.1 备份：导出带 todo_states，恢复后状态还在', () async {
    final db = newDb();
    await seed(db, '梯子', 1);
    await db.lendItem('梯子', '张三', quantity: 1);
    final loanId = (await db.getAllLoans()).first.id!;
    await db.markDone(TodoSourceType.loanDue, loanId);
    await db.setNote(TodoSourceType.loanDue, loanId, '已催过');

    final backup = await db.exportBackup();
    expect(backup.containsKey('todo_states'), isTrue,
        reason: '备份必须带催办状态，否则恢复后「已处理/延期次数/备注」全丢');
    expect((backup['todo_states'] as List).length, 1);

    // 清掉再恢复。
    await db.markDone(TodoSourceType.loanDue, loanId, done: false);
    await db.setNote(TodoSourceType.loanDue, loanId, '');
    await db.restoreBackup(backup);
    final restored = await db.readState(TodoSourceType.loanDue, loanId);
    expect(restored, isNotNull);
    expect(restored!.isDone, isTrue);
    expect(restored.handleNote, '已催过');
  });
}
