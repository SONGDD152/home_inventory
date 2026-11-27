// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/data/daily_report_service.dart';
import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/inventory_database.dart';
import 'package:home_inventory/data/reminder.dart';
import 'package:home_inventory/data/todo_state.dart';
import 'package:home_inventory/domain/overview_reader.dart';
import 'package:home_inventory/domain/reminder_source.dart';
import 'package:home_inventory/domain/reminder_sources.dart';
import 'package:home_inventory/domain/todo_agenda.dart';
import 'package:home_inventory/domain/todo_state_writer.dart';
import 'package:home_inventory/ui/overview_page.dart';

import 'fake_domain_repository.dart';

/// V4.1 批次 2：**日报签提醒层裁定**专项测试。
///
/// 元宝「V4.1 日报签提醒层裁定」五条逐条对应：
/// - ① 优先级：`reminders` 加 `priority` 列（0低/1中/2高，默认1），
///   日程签创建/编辑时可设，催办区按优先级排序（高→中→低）；
/// - ② 多级提醒：到期前**提前**进催办区，不卡到期时刻；
/// - ③ 延期交互：点延期让用户选「延到明天 / 具体日期」，写 `next_due_at`；
/// - ④ 催办区分组：系统类与日程类图标区分，**可折叠**；
/// - ⑤ 三态视觉：未处理 / 已处理·划线灰化 / 已延期·独立视觉
///   （⑤ 的样式由 v42 专项覆盖，本文件补「日程签只管纵览 + 状态展示」这半句）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;
  late List<InventoryDatabase> opened;

  InventoryDatabase newDb({String name = 'inventory.db', int version = 13}) {
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

  // 供「跨域状态不撞车」那条用例用：造一条借出（系统类催办源）。
  Future<int> seedLoan(
    InventoryDatabase db,
    String item, {
    String borrower = '张三',
    int dueInDays = 0,
  }) async {
    await seed(db, item, 1);
    final loan = await db.lendItem(item, borrower, quantity: 1);
    final loans = await db.getAllLoans();
    final target = loans.firstWhere((l) => l.id == loan.id);
    await db.updateLoanDue(target.id!, dueInDays < 1 ? 1 : dueInDays);
    return target.id!;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('home_inventory_v43_');
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

  // ============ 裁定① 优先级 ============

  test('裁定① reminders 表加 priority 列（0低/1中/2高，默认1）', () async {
    final db = newDb();
    await db.open();
    final cols = await columnsOf(db, 'reminders');
    final byName = <String, Map<String, Object?>>{
      for (final c in cols) c['name'] as String: c,
    };
    expect(byName.containsKey('priority'), isTrue,
        reason: '裁定①要求 reminders 表有 priority 列');
    expect(byName['priority']!['type'], 'INTEGER');
    expect(byName['priority']!['notnull'], 1);
    expect(byName['priority']!['dflt_value'], '1',
        reason: '默认 1（中）——旧提醒不该因升级被判成低优先级');
  });

  test('裁定① 优先级可写可改，越界归中', () async {
    final db = newDb();
    final id = await db.addReminder('交电费',
        dueAt: DateTime.now(), priority: ReminderPriority.high);
    var item = (await db.getReminders()).firstWhere((r) => r.id == id);
    expect(item.priority, 2, reason: '高优先级写进去是 2');

    await db.updateReminder(id, priority: ReminderPriority.low);
    item = (await db.getReminders()).firstWhere((r) => r.id == id);
    expect(item.priority, 0, reason: '编辑时改成低优先级');

    await db.updateReminder(id, priority: 9);
    item = (await db.getReminders()).firstWhere((r) => r.id == id);
    expect(item.priority, ReminderPriority.normal,
        reason: '越界值归中，不该把脏值写进库');
  });

  test('裁定① 提前量由优先级推导：高3天 / 中1天 / 低0天', () {
    expect(ReminderPriority.leadDaysOf(ReminderPriority.high), 3);
    expect(ReminderPriority.leadDaysOf(ReminderPriority.normal), 1);
    expect(ReminderPriority.leadDaysOf(ReminderPriority.low), 0);
    expect(ReminderPriority.labelOf(ReminderPriority.high), '高');
    expect(ReminderPriority.labelOf(ReminderPriority.normal), '中');
    expect(ReminderPriority.labelOf(ReminderPriority.low), '低');
  });

  test('裁定① 催办区按优先级排序：高 → 中 → 低', () {
    OverviewEntry entry(String id, int priority, {int? dueAt}) => OverviewEntry(
          id: id,
          title: id,
          dueAt: dueAt,
          priority: priority,
          sourceType: TodoSourceType.scheduleReminder,
          sourceId: 1,
        );

    final items = <TodoAgendaItem>[
      TodoAgendaItem(
        entry: entry('低', ReminderPriority.low, dueAt: 100),
        state: null,
        sourceDisplayName: 'x',
        isSystemHint: false,
      ),
      TodoAgendaItem(
        entry: entry('中', ReminderPriority.normal, dueAt: 100),
        state: null,
        sourceDisplayName: 'x',
        isSystemHint: false,
      ),
      TodoAgendaItem(
        entry: entry('高', ReminderPriority.high, dueAt: 100),
        state: null,
        sourceDisplayName: 'x',
        isSystemHint: false,
      ),
    ];
    TodoAgenda.sortByPriority(items);
    expect(items.map((i) => i.entry.title).toList(), <String>['高', '中', '低']);
  });

  test('裁定① 同优先级按到期日近的在前（排序稳定可预期）', () {
    OverviewEntry entry(String id, int dueAt) => OverviewEntry(
          id: id,
          title: id,
          dueAt: dueAt,
          priority: ReminderPriority.normal,
          sourceType: TodoSourceType.scheduleReminder,
          sourceId: 1,
        );

    final items = <TodoAgendaItem>[
      TodoAgendaItem(
        entry: entry('远', 300),
        state: null,
        sourceDisplayName: 'x',
        isSystemHint: false,
      ),
      TodoAgendaItem(
        entry: entry('近', 100),
        state: null,
        sourceDisplayName: 'x',
        isSystemHint: false,
      ),
    ];
    TodoAgenda.sortByPriority(items);
    expect(items.map((i) => i.entry.title).toList(), <String>['近', '远']);
  });

  test('裁定① 迁移：v12→v13 补出 priority 列，旧数据零丢失、幂等', () async {
    // 造一个「真的没有 priority 列」的 v12 库（模拟升级前的旧库）。
    final legacy = newDb(name: 'life.db', version: 12);
    await legacy.open();
    final handle = await legacy.open();
    await handle.execute('ALTER TABLE reminders DROP COLUMN priority');
    expect(
      (await columnsOf(legacy, 'reminders')).any((c) => c['name'] == 'priority'),
      isFalse,
      reason: '前置条件：这张表此刻确实没有 priority 列',
    );
    final locationId = await legacy.addLocation('主位置');
    await legacy.upsertItemLocation('梯子', locationId, quantity: 2);
    await legacy.close();

    // 升到 v13。
    final upgraded = newDb(name: 'life.db', version: 13);
    await upgraded.open();
    final cols = await columnsOf(upgraded, 'reminders');
    final byName = <String, Map<String, Object?>>{
      for (final c in cols) c['name'] as String: c,
    };
    expect(byName.containsKey('priority'), isTrue, reason: '迁移补出 priority 列');
    expect(byName['priority']!['dflt_value'], '1');
    // 数据零丢失。
    expect((await upgraded.getQuantityInfo('梯子')).stock, 2);
    // 旧提醒默认拿到中优先级。
    final oldReminderId =
        await upgraded.addReminder('旧提醒', dueAt: DateTime.now());
    expect((await upgraded.getReminders())
        .firstWhere((r) => r.id == oldReminderId)
        .priority,
        ReminderPriority.normal);

    // 幂等：再开一次不再改动。
    await upgraded.close();
    final again = newDb(name: 'life.db', version: 13);
    await again.open();
    expect((await again.getQuantityInfo('梯子')).stock, 2);
  });

  test('裁定① 两库结构齐平（priority 列两库都在、都默认1）', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await life.open();
    await work.open();
    final lifeCols = await columnsOf(life, 'reminders');
    final workCols = await columnsOf(work, 'reminders');
    expect(lifeCols.length, workCols.length);
    for (var i = 0; i < lifeCols.length; i++) {
      expect(workCols[i]['name'], lifeCols[i]['name']);
      expect(workCols[i]['dflt_value'], lifeCols[i]['dflt_value']);
    }
  });

  // ============ 裁定② 多级提醒（到期前提前进催办区）============

  test('裁定② 高优先级：3 天后到期今天就进区，4 天后不进', () {
    final today = DateTime.now();
    final in3 = DateTime(today.year, today.month, today.day + 3, 9);
    final in4 = DateTime(today.year, today.month, today.day + 4, 9);

    expect(
      TodoAgenda.isInAgenda(
        sourceDueAt: in3.millisecondsSinceEpoch,
        nextDueAt: null,
        doneAt: null,
        leadDays: ReminderPriority.leadDaysOf(ReminderPriority.high),
        date: today,
      ),
      isTrue,
      reason: '高优先级提前 3 天进区——不卡到期时刻',
    );
    expect(
      TodoAgenda.isInAgenda(
        sourceDueAt: in4.millisecondsSinceEpoch,
        nextDueAt: null,
        doneAt: null,
        leadDays: ReminderPriority.leadDaysOf(ReminderPriority.high),
        date: today,
      ),
      isFalse,
      reason: '提前量是 3 天，第 4 天到期的不该今天就冒出来',
    );
  });

  test('裁定② 中优先级：1 天后到期进区，2 天后不进；低优先级不提前', () {
    final today = DateTime.now();
    final in1 = DateTime(today.year, today.month, today.day + 1, 9);
    final in2 = DateTime(today.year, today.month, today.day + 2, 9);

    expect(
      TodoAgenda.isInAgenda(
        sourceDueAt: in1.millisecondsSinceEpoch,
        nextDueAt: null,
        doneAt: null,
        leadDays: ReminderPriority.leadDaysOf(ReminderPriority.normal),
        date: today,
      ),
      isTrue,
    );
    expect(
      TodoAgenda.isInAgenda(
        sourceDueAt: in2.millisecondsSinceEpoch,
        nextDueAt: null,
        doneAt: null,
        leadDays: ReminderPriority.leadDaysOf(ReminderPriority.normal),
        date: today,
      ),
      isFalse,
    );
    expect(
      TodoAgenda.isInAgenda(
        sourceDueAt: in1.millisecondsSinceEpoch,
        nextDueAt: null,
        doneAt: null,
        leadDays: ReminderPriority.leadDaysOf(ReminderPriority.low),
        date: today,
      ),
      isFalse,
      reason: '低优先级不提前，到期当天才进区',
    );
  });

  test('裁定② 提前进区是「不卡到期时刻」，不是「跳过到期当天」', () {
    // 到期当天必须仍在催办区（这是 B4「到期当天再次提示」的前提）。
    final today = DateTime.now();
    final today9 = DateTime(today.year, today.month, today.day, 9);
    expect(
      TodoAgenda.isInAgenda(
        sourceDueAt: today9.millisecondsSinceEpoch,
        nextDueAt: null,
        doneAt: null,
        leadDays: 0,
        date: today,
      ),
      isTrue,
    );
  });

  // ============ 裁定③ 延期交互：延到明天 / 具体日期 ============

  test('裁定③ defer(dueOn:) 写绝对日期 next_due_at，延期次数 +1', () async {
    final db = newDb();
    final id = await db.addReminder('交电费', dueAt: DateTime.now());
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final target = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9);

    await db.defer(TodoSourceType.scheduleReminder, id,
        reason: '等物业回电', dueOn: target);

    final state = await db.readState(TodoSourceType.scheduleReminder, id);
    expect(state!.deferCount, 1, reason: '按次累计');
    expect(state.isDeferred, isTrue);
    expect(state.nextDueAt, target.millisecondsSinceEpoch,
        reason: 'next_due_at 写的就是用户选的那一天');
    expect(state.handleNote, '等物业回电');
  });

  test('裁定③ 相对推进口径仍在（days），两条口径互不打架', () async {
    final db = newDb();
    final id = await db.addReminder('交电费', dueAt: DateTime.now());
    await db.defer(TodoSourceType.scheduleReminder, id, days: 3);
    final state = await db.readState(TodoSourceType.scheduleReminder, id);
    expect(state!.deferCount, 1);
    expect(state.nextDueAt, isNotNull);
  });

  test('裁定③ 延期只动 todo_states，不碰源表 reminders', () async {
    final db = newDb();
    final id = await db.addReminder('交电费', dueAt: DateTime.now());
    final before = (await db.getReminders()).firstWhere((r) => r.id == id);
    await db.defer(TodoSourceType.scheduleReminder, id,
        dueOn: DateTime.now().add(const Duration(days: 2)));
    final after = (await db.getReminders()).firstWhere((r) => r.id == id);
    expect(after.dueAt, before.dueAt, reason: '源表到期日一列不动');
    expect(after.priority, before.priority);
  });

  test('裁定③ 待办写口签名支持绝对日期（源码级）', () {
    final src = File('lib/domain/todo_state_writer.dart').readAsStringSync();
    expect(src, contains('dueOn'),
        reason: '延期写口必须能收绝对日期，否则「延到具体日期」无处落地');
  });

  test('裁定③ 延期弹窗提供「延到明天 / 具体日期」两个选项（源码级）', () {
    final src = File('lib/ui/overview_page.dart').readAsStringSync();
    for (final key in <String>[
      'overview_defer_dialog',
      'overview_defer_opt_tomorrow',
      'overview_defer_opt_date',
      'overview_defer_pick_date',
      'overview_defer_confirm',
    ]) {
      expect(src, contains(key), reason: '延期弹窗必须有稳定 key：$key');
    }
  });

  // ============ 裁定④ 催办区分组：图标区分 + 可折叠 ============

  test('裁定④ 催办区按源分组且分组可折叠（源码级）', () {
    // **V4.1.1 整改 4：分组依据从「源」改成「区域」。**
    //
    // PM 2026-11-27 拍板：催办列表**只按区域分成两块**
    // （生活区 / 工作区），不拆成四块，也不要三级分类/子标签/额外筛选。
    //
    // 所以这条锁的**分组 key** 跟着改：`overview_group_<源id>` →
    // `overview_block_<区域id>`。折叠能力（ExpansionTile）与
    // 系统类/日程类的**图标区分**都保留——图标区分是「条目级」的，
    // 不是「分组级」的，与整改 4 不冲突。
    final src = File('lib/ui/overview_page.dart').readAsStringSync();
    expect(src, contains('ExpansionTile'), reason: '分组必须可折叠');
    expect(src, contains('overview_block_'), reason: '分组要有稳定 key');
    expect(src, contains('inventory_2_outlined'),
        reason: '系统类与日程类必须图标区分');
    expect(src, contains('event_note'));
  });

  test('裁定④ 系统类与日程类的来源标识可区分', () {
    final life = FakeDomainRepository();
    final loanSource = LoanDueReminderSource(life, InventoryDomain.life);
    final scheduleSource = ScheduleReminderSource(life, InventoryDomain.life);
    expect(loanSource.id, 'loan_due_life');
    expect(scheduleSource.id, 'schedule_reminders_life');
    expect(loanSource.displayName, isNot(scheduleSource.displayName));
  });

  // ============ 裁定⑤ 日程签只管纵览 + 状态展示 ============

  test('裁定⑤ 日程签不挂提醒交互（源码级：日程签组件无延期/备注按钮）', () {
    // V4.1 批次 3：日程签从概览页里**拆成了独立组件**
    // （`lib/ui/schedule_tab_view.dart`），因为它要带月历 + 时间轴
    // + 跨域标识 + 增删改，留在概览页里会把这个文件撑爆。
    //
    // 所以这条锁从「概览页传 showActions: false」**升级**为
    // 「日程签组件自己就不含延期/备注交互」——锁的是**行为口径**，
    // 不是某个实现细节。批次 3 之后日程签勾选写 `todo_states`
    // （待办状态本身，元宝 B8 双向同步的落点），
    // 但**不出现**延期 / 备注这两个提醒交互按钮。
    final src =
        File('lib/ui/schedule_tab_view.dart').readAsStringSync();
    expect(src, isNot(contains('overview_defer_')),
        reason: '日程签不该有延期交互按钮');
    expect(src, isNot(contains('overview_note_')),
        reason: '日程签不该有备注交互按钮');
    expect(src, contains('markDone'),
        reason: '日程签的勾选写 todo_states——这是待办状态，不是提醒交互');
  });

  test('裁定⑤ 日程签仍只读纵览（源码级：概览页不持有仓储类型）', () {
    // **剥掉注释行**再查——与 v41 的同类锁同一口径。
    //
    // 为什么必须剥：这条锁要证明的是「概览页的**代码**里不持有仓储类型」，
    // 而不是「注释里不许提到这些词」。批次 3 的注释里会说明
    // 「数据层怎么校验的」，提到实现类名是正常叙述——
    // 那是**文档**，不是**持有**。
    //
    // 不剥注释的话，这条锁测的是「文档用词」而不是「能力边界」，
    // 逼着写注释的人绕着某个词说话——那是**假边界**，
    // 真正的边界（代码里能不能拿到写口）反而没人管。
    final src = _codeOnly('lib/ui/overview_page.dart');
    for (final bad in <String>[
      'InventoryRepository',
      'InventoryDatabase',
      'ReminderRepository',
    ]) {
      expect(src.contains(bad), isFalse,
          reason: '概览页不该持有仓储类型 $bad');
    }
  });

  test('裁定⑤ 概览区不持写口（源码级：概览区任一文件都不许有写接口）',
      () {
    // V4.1 批次 3 新增的锁。
    //
    // 批次 3 要让日程签能新建/编辑/删除提醒，如果图省事，
    // 概览区（`lib/ui/overview_page.dart` + `lib/ui/schedule_tab_view.dart`）
    // 就会直接持一个提醒写接口——那等于**概览区拿到了写能力**，
    // 元宝批过的四锁之一就破了。
    //
    // 所以本批的做法是：概览区只持**回调**，
    // 写操作由组合根（`home_page.dart`）执行。
    //
    // 这条锁把「概览区不许出现写接口类型」**锁死**——
    // 将来谁想在概览区直接塞一个写口，测试立刻红。
    const writePorts = <String>[
      'InventoryRepository',
      'InventoryDatabase',
      'ReminderRepository',
      'ReminderEditor',
    ];
    for (final path in const <String>[
      'lib/ui/overview_page.dart',
      'lib/ui/schedule_tab_view.dart',
    ]) {
      final src = _codeOnly(path);
      for (final bad in writePorts) {
        expect(src.contains(bad), isFalse,
            reason: '概览区不该持有写口 $bad（$path）——写操作归组合根');
      }
    }
  });

  // ============ 跨域一致性（E1 在状态层的翻版）============

  test('跨域：两库各自的 loan_1 状态不互相覆盖（配对键带域）', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    final lifeLoan = await seedLoan(life, '梯子', dueInDays: 0);
    final workLoan = await seedLoan(work, '扳手', dueInDays: 0);
    expect(lifeLoan, workLoan,
        reason: '前置条件：两库的 loan id 相同（各自从 1 开始）——'
            '这正是会撞车的那种情况');

    // 只处理生活库那笔。
    await life.markDone(TodoSourceType.loanDue, lifeLoan);

    final lifeEntry = (await LoanDueReminderSource(life, InventoryDomain.life)
            .loadEntries())
        .first;
    final workEntry = (await LoanDueReminderSource(work, InventoryDomain.work)
            .loadEntries())
        .first;
    expect(lifeEntry.stateKey, workEntry.stateKey,
        reason: '存储层的 entryKey 确实相同（每库一张表，单库内唯一）');

    // 合并两库状态（带域前缀配对）。
    final states = <String, TodoState>{};
    for (final domain in InventoryDomain.values) {
      final writer = domain == InventoryDomain.life ? life : work;
      for (final state in await writer.loadStates()) {
        states[TodoAgenda.stateKeyOf(domain, state.entryKey)] = state;
      }
    }
    expect(
      states[TodoAgenda.stateKeyOf(InventoryDomain.life, lifeEntry.stateKey)]!
          .isDone,
      isTrue,
      reason: '生活库那笔确实处理过',
    );
    expect(
      states[TodoAgenda.stateKeyOf(InventoryDomain.work, workEntry.stateKey)],
      isNull,
      reason: '工作库那笔没处理过 —— 不该被生活库的状态覆盖',
    );
  });

  test('跨域：工作域借出到期条目也进日报导出的未完成清单（元宝 B6 同源）',
      () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seedLoan(work, '扳手', dueInDays: 0);

    final service = DailyReportService(
      storage: life,
      reminders: life,
      overview: InventoryOverviewReader(life: life, work: work),
      todoReaders: <InventoryDomain, TodoStateReader>{
        InventoryDomain.life: life,
        InventoryDomain.work: work,
      },
      todoSources: <ReminderSource>[
        LoanDueReminderSource(life, InventoryDomain.life),
        LoanDueReminderSource(work, InventoryDomain.work),
        ScheduleReminderSource(life, InventoryDomain.life),
      ],
    );
    final content = await service.buildContent(DateTime.now());
    expect(content, contains('扳手'),
        reason: '工作域条目也得进导出——否则界面上红着、导出里没有，'
            '违反元宝 B6「未完成 = 提示框内未处理的条目」');
  });

  test('跨域：概览页读得到两个域各自的待办状态', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    final lifeLoan = await seedLoan(life, '梯子', dueInDays: 0);
    final workLoan = await seedLoan(work, '扳手', dueInDays: 0);
    await life.markDone(TodoSourceType.loanDue, lifeLoan);

    final states = <String, TodoState>{};
    for (final domain in InventoryDomain.values) {
      final writer = domain == InventoryDomain.life ? life : work;
      for (final state in await writer.loadStates()) {
        states[TodoAgenda.stateKeyOf(domain, state.entryKey)] = state;
      }
    }
    expect(states.length, 1, reason: '只处理了一笔');
    expect(
      states.values.first.sourceId,
      lifeLoan,
      reason: '工作库的 loan_1 状态不该把生活库那条盖掉',
    );
    expect(workLoan, lifeLoan);
  });

  // ============ widget 层：真点一次延期 / 真折一次分组 ============

  /// 造一套概览页的内存依赖并把页面 pump 出来。
  ///
  /// 视口调大：概览页上半屏是两张账目快照卡，催办分组在下面。
  /// 默认 800×600 的视口下，ListView 懒加载**根本不会构建**下面的条目
  /// （`find.byKey` 只找已构建的节点）——那测的就不是「界面上有没有」，
  /// 而是「视口里有没有」，白测。所以这里把视口拉高到一屏装得下。
  Future<({FakeDomainRepository life, int reminderId})> pumpOverview(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    final reminderId = await life.addReminder('交电费', dueAt: DateTime.now());

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OverviewPage(
          reader: InventoryOverviewReader(life: life, work: work),
          sources: <ReminderSource>[
            LoanDueReminderSource(life, InventoryDomain.life),
            ScheduleReminderSource(life, InventoryDomain.life),
          ],
          todoWriters: <InventoryDomain, TodoStateWriter>{
            InventoryDomain.life: life,
            InventoryDomain.work: work,
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (life: life, reminderId: reminderId);
  }

  testWidgets('widget 回归锁：概览页首帧后必须加载数据（不再停在「加载中…」）',
      (tester) async {
    await pumpOverview(tester);
    expect(find.text('加载中…'), findsNothing,
        reason: '概览页必须真的去读数据——'
            '批次 1 交付时漏了 initState 触发加载，页面永远停在「加载中…」');
    // **V4.1.1 整改 1：概览统计卡整块撤掉**（PM 真机红框指定）。
    // 原断言是「两张统计卡都在」；现在改成「统计卡不在了」，
    // 并且**催办区必须顶上来**（不能撤了卡却留下一片空白）。
    expect(find.byKey(const Key('overview_domain_life')), findsNothing,
        reason: '整改1：日报签不再展示生活区统计卡');
    expect(find.byKey(const Key('overview_domain_work')), findsNothing,
        reason: '整改1：日报签不再展示工作区统计卡');
    expect(find.byKey(const Key('overview_block_life')), findsOneWidget,
        reason: '整改1：撤掉统计卡后，催办区要顶上来');
  });

  testWidgets('widget 裁定③：点延期 → 选「延到明天」→ 写入 next_due_at',
      (tester) async {
    final env = await pumpOverview(tester);
    final deferKey = Key('overview_defer_reminder_life_${env.reminderId}');
    expect(find.byKey(deferKey), findsOneWidget, reason: '日报签条目有延期按钮');

    await tester.tap(find.byKey(deferKey));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('overview_defer_dialog')), findsOneWidget);
    expect(find.byKey(const Key('overview_defer_opt_tomorrow')), findsOneWidget);
    expect(find.byKey(const Key('overview_defer_opt_date')), findsOneWidget);

    // 默认就是「延到明天」→ 直接确认。
    await tester.tap(find.byKey(const Key('overview_defer_confirm')));
    await tester.pumpAndSettle();

    final state = await env.life
        .readState(TodoSourceType.scheduleReminder, env.reminderId);
    expect(state, isNotNull);
    expect(state!.deferCount, 1, reason: '点一次延期 = 1 次');
    expect(state.isDeferred, isTrue);
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    expect(
      state.nextDueAt,
      DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9)
          .millisecondsSinceEpoch,
      reason: '延到明天 = 明天 09:00',
    );
  });

  testWidgets('widget 裁定③：选「延到具体日期」→ 日期选择器出现并写进 next_due_at',
      (tester) async {
    final env = await pumpOverview(tester);
    await tester.tap(find.byKey(const Key('overview_defer_reminder_life_1')));
    await tester.pumpAndSettle();

    // 切到「延到具体日期」→ 出现日期选择按钮。
    await tester.tap(find.byKey(const Key('overview_defer_opt_date')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('overview_defer_pick_date')), findsOneWidget);

    // 点开日期选择器 → 确认。
    await tester.tap(find.byKey(const Key('overview_defer_pick_date')));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    // 确认按钮的文案随语言变，用 MaterialLocalizations 取（不写死「确定」）。
    final l10n =
        MaterialLocalizations.of(tester.element(find.byType(DatePickerDialog)));
    await tester.tap(find.descendant(
      of: find.byType(DatePickerDialog),
      matching: find.text(l10n.okButtonLabel),
    ));
    await tester.pumpAndSettle();

    // 按钮上的目标日期已经写在标签里（「延期到 YYYY-MM-DD」）。
    expect(find.textContaining('延期到'), findsOneWidget,
        reason: '选了具体日期后，按钮要显示目标日期');

    // 确认延期 → 写进 next_due_at。
    await tester.tap(find.byKey(const Key('overview_defer_confirm')));
    await tester.pumpAndSettle();
    final state = await env.life
        .readState(TodoSourceType.scheduleReminder, env.reminderId);
    expect(state!.deferCount, 1);
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    expect(
      state.nextDueAt,
      DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9)
          .millisecondsSinceEpoch,
      reason: '默认选中的就是明天 → next_due_at = 明天 09:00',
    );
  });

  testWidgets('widget 裁定④：催办分组可折叠（折起来条目就不在了）',
      (tester) async {
    await pumpOverview(tester);

    // **V4.1.1 整改 4：分组改成「按区域」，恒为两块**
    // （生活区 / 工作区）——不再按源拆成四块。
    expect(find.byKey(const Key('overview_block_life')), findsOneWidget);
    expect(find.byKey(const Key('overview_block_work')), findsOneWidget);
    // 默认展开：条目可见。
    expect(find.byKey(const Key('overview_entry_reminder_life_1')),
        findsOneWidget);

    // 点分组标题折起来。
    await tester.tap(find.text('生活区'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('overview_entry_reminder_life_1')),
        findsNothing,
        reason: '折叠后这一组的条目不该再渲染');
    // 另一个块不受影响。
    expect(find.byKey(const Key('overview_block_work')), findsOneWidget);

    // 再点开。
    await tester.tap(find.text('生活区'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('overview_entry_reminder_life_1')),
        findsOneWidget);
  });

  testWidgets('widget 裁定⑤：日报签有延期/备注按钮，日程签没有',
      (tester) async {
    await pumpOverview(tester);

    // 日报签（默认选中）：条目上有延期与备注按钮。
    final reportRow =
        find.byKey(const Key('overview_entry_reminder_life_1'));
    expect(reportRow, findsOneWidget);
    expect(
      find.descendant(
        of: reportRow,
        matching: find.byKey(const Key('overview_defer_reminder_life_1')),
      ),
      findsOneWidget,
      reason: '日报签是催办区，延期按钮必须在',
    );
    expect(
      find.descendant(
        of: reportRow,
        matching: find.byKey(const Key('overview_note_reminder_life_1')),
      ),
      findsOneWidget,
      reason: '日报签要有备注入口',
    );

    // 切到日程签：只有纵览与状态展示，没有提醒交互按钮。
    await tester.tap(find.byKey(const Key('overview_tab_schedule')));
    await tester.pumpAndSettle();
    final scheduleRow =
        find.byKey(const Key('schedule_entry_reminder_life_1'));
    expect(scheduleRow, findsOneWidget, reason: '日程签是纵览，条目要列出来');
    expect(
      find.descendant(
        of: scheduleRow,
        matching: find.byKey(const Key('overview_defer_reminder_life_1')),
      ),
      findsNothing,
      reason: '裁定⑤：日程签不碰提醒交互 → 不该有延期按钮',
    );
    expect(
      find.descendant(
        of: scheduleRow,
        matching: find.byKey(const Key('overview_note_reminder_life_1')),
      ),
      findsNothing,
      reason: '裁定⑤：日程签不碰提醒交互 → 不该有备注按钮',
    );
    // 状态展示仍在（三态的划线灰化靠它）。
    expect(
      find.descendant(
        of: scheduleRow,
        matching: find.byKey(const Key('overview_check_reminder_life_1')),
      ),
      findsOneWidget,
      reason: '状态展示保留（日程签只读纵览，但状态要看得见）',
    );
  });

  testWidgets('widget 裁定⑤：日程签勾选与日报签同步（元宝 B8 双向同步）',
      (tester) async {
    final env = await pumpOverview(tester);

    // V4.1.4 三态：在日报签点两次（空→半→满）到完成态。
    await tester.tap(
        find.byKey(const Key('overview_check_reminder_life_1')));
    await tester.pumpAndSettle();
    await tester.tap(
        find.byKey(const Key('overview_check_reminder_life_1')));
    await tester.pumpAndSettle();
    final state = await env.life
        .readState(TodoSourceType.scheduleReminder, env.reminderId);
    expect(state!.isDone, isTrue);

    // 切到日程签，同一条目应显示为「已处理」（勾选框选中）。
    await tester.tap(find.byKey(const Key('overview_tab_schedule')));
    await tester.pumpAndSettle();
    // V4.1.3：已完成默认隐藏（纯视图），先点开「显示已完成」再看状态。
    await tester.tap(find.byKey(const Key('schedule_toggle_done')));
    await tester.pumpAndSettle();
    final check = tester.widget<Checkbox>(
      find.descendant(
        of: find.byKey(const Key('schedule_entry_reminder_life_1')),
        matching: find.byKey(const Key('overview_check_reminder_life_1')),
      ),
    );
    expect(check.value, isTrue, reason: '日程签读到的是同一份状态');
  });
}

/// 去掉注释行，只留代码——用来做「不持仓储类型」的源码级断言。
///
/// 与 v41 的同名辅助**同一实现**（口径一致，不搞两套）。
String _codeOnly(String path) {
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
