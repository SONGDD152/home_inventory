// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/inventory_database.dart';
import 'package:home_inventory/data/reminder.dart';
import 'package:home_inventory/data/todo_state.dart';
import 'package:home_inventory/domain/overview_reader.dart';
import 'package:home_inventory/domain/reminder_editor.dart';
import 'package:home_inventory/domain/reminder_source.dart';
import 'package:home_inventory/domain/reminder_sources.dart';
import 'package:home_inventory/domain/repeat_rule.dart';
import 'package:home_inventory/domain/todo_agenda.dart';
import 'package:home_inventory/domain/todo_state_writer.dart';
import 'package:home_inventory/ui/overview_page.dart';

import 'fake_domain_repository.dart';

/// V4.1 批次 3：**日程签完整交互**专项测试。
///
/// ## 元宝裁定①修订（系统类提前量）
/// PM 最终裁定：系统类（借出到期）优先级 = 高，**提前 2 天**进催办区，
/// 不取 buddy 原定的 3 天；而裁定②的「提前量由 priority 推导」
/// （高 3 / 中 1 / 低 0）**不动**。
///
/// 两条裁定会打架 → 必须用**显式提前量覆盖**解耦，
/// 不能去改 priority 推导表（那会连带改掉日程类高优先级的 3 天）。
///
/// ## 元宝裁定④修订（延期只往后推）
/// 选了早于当前提示日的日子 → **忽略这次延期**并提示，
/// 状态行一个字不动（连延期次数都不加）。
/// 校验必须在**数据层**——只在 UI 拦的话，绕过 UI 的调用照样能回拉。
///
/// ## 批次 3 五项子功能
/// ① 月历缩略（可折叠）+ 时间轴列表
/// ② 跨域展示带域标识
/// ③ 创建/编辑/重复规则
/// ④ 工作域能力开关保留
/// ⑤ 日程签 ↔ 日报签 勾选双向同步
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;
  late List<InventoryDatabase> opened;

  InventoryDatabase newDb({String name = 'inventory.db'}) {
    final instance = InventoryDatabase(
      databaseFactory: databaseFactoryFfi,
      databasePath: p.join(tempDir.path, name),
      version: 13,
      domain:
          name.startsWith('work') ? InventoryDomain.work : InventoryDomain.life,
    );
    opened.add(instance);
    return instance;
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('v44_schedule');
    opened = <InventoryDatabase>[];
  });

  tearDown(() {
    for (final db in opened) {
      db.close();
    }
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  // ───────────────── 裁定①修订：系统类提前量 2 天 ─────────────────

  test('裁定①修订：系统类提前量 = 2 天（PM 最终裁定，不取原定 3 天）', () async {
    final db = newDb();
    final locationId = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', locationId, quantity: 1);
    final loan = await db.lendItem('梯子', '张三',
        quantity: 1, days: 5);
    expect(loan.id, isNotNull);

    final source = LoanDueReminderSource(db, InventoryDomain.life);
    final entries = await source.loadEntries();
    expect(entries, hasLength(1));
    final entry = entries.first;
    // 优先级 = 高（裁定①批准）。
    expect(entry.priority, ReminderPriority.high);
    // **提前量 = 2 天**（PM 最终裁定），不是 priority 推导的 3 天。
    expect(entry.leadDays, 2);
    // 关键：priority 推导表**一个字没动**——
    // 日程类的高优先级仍然是提前 3 天（裁定②不许改）。
    expect(ReminderPriority.leadDaysOf(ReminderPriority.high), 3);
  });

  test('裁定①修订：日程类高优先级仍是提前 3 天（裁定②不被牵连）', () async {
    final db = newDb();
    await db.addReminder('交电费',
        dueAt: DateTime.now().add(const Duration(days: 5)),
        priority: ReminderPriority.high);
    final source = ScheduleReminderSource(db, InventoryDomain.life);
    final entries = await source.loadEntries();
    expect(entries.first.leadDays, 3);
    expect(entries.first.leadDaysOverride, isNull);
  });

  test('裁定①修订：提前进区按 2 天算（3 天后的到期日不进，2 天后的进）',
      () async {
    final db = newDb();
    final locationId = await db.addLocation('阳台');
    await db.upsertItemLocation('梯子', locationId, quantity: 1);
    await db.lendItem('梯子', '张三', quantity: 1, days: 3);
    final source = LoanDueReminderSource(db, InventoryDomain.life);
    final entries = await source.loadEntries();
    // 提前 2 天 → 3 天后到期**不该**进区（提前量只够 2 天）。
    expect(TodoAgenda.isInAgenda(
      sourceDueAt: entries.first.dueAt,
      nextDueAt: null,
      doneAt: null,
      leadDays: entries.first.leadDays,
      date: DateTime.now(),
    ), isFalse);

    // 2 天后到期 → 进区。
    final db2 = newDb(name: 'inventory2.db');
    final loc2 = await db2.addLocation('阳台');
    await db2.upsertItemLocation('梯子', loc2, quantity: 1);
    await db2.lendItem('梯子', '张三', quantity: 1, days: 2);
    final e2 = await LoanDueReminderSource(db2, InventoryDomain.life).loadEntries();
    expect(TodoAgenda.isInAgenda(
      sourceDueAt: e2.first.dueAt,
      nextDueAt: null,
      doneAt: null,
      leadDays: e2.first.leadDays,
      date: DateTime.now(),
    ), isTrue);
  });

  // ───────────────── 裁定④修订：延期只往后推 ─────────────────

  test('裁定④：延期到早于当前提示日 → 报错且状态行一字不动', () async {
    final db = newDb();
    await db.addReminder('交电费', dueAt: DateTime.now());
    final state = await db.readState(TodoSourceType.scheduleReminder, 1);
    expect(state, isNull);

    // 往回拉（昨天）→ 必须被拒。
    var threw = false;
    try {
      await db.defer(
        TodoSourceType.scheduleReminder,
        1,
        reason: '往回拉',
        dueOn: DateTime.now().subtract(const Duration(days: 1)),
      );
    } on ArgumentError catch (_) {
      threw = true;
    }
    expect(threw, isTrue, reason: '回拉必须被数据层拦下');

    // **状态行一个字都没动**——这次延期压根没发生。
    final after = await db.readState(TodoSourceType.scheduleReminder, 1);
    expect(after, isNull, reason: '被拒绝的延期不该留下状态行');
  });

  test('裁定④：延期到等于当前提示日 → 允许（不构成回拉）', () async {
    final db = newDb();
    await db.addReminder('交电费', dueAt: DateTime.now());
    // 先延到明天。
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    await db.defer(
      TodoSourceType.scheduleReminder,
      1,
      dueOn: DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9),
    );
    final s1 = await db.readState(TodoSourceType.scheduleReminder, 1);
    expect(s1?.deferCount, 1);

    // 再延到同一个日子 → 不是「早于」→ 允许。
    await db.defer(
      TodoSourceType.scheduleReminder,
      1,
      dueOn: DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 9),
    );
    final s2 = await db.readState(TodoSourceType.scheduleReminder, 1);
    expect(s2?.deferCount, 2, reason: '同一天再延一次 = 第二次延期');
  });

  test('裁定④：往后推 → 正常写入 next_due_at 且次数 +1', () async {
    final db = newDb();
    await db.addReminder('交电费', dueAt: DateTime.now());
    final target = DateTime.now().add(const Duration(days: 5));
    await db.defer(
      TodoSourceType.scheduleReminder,
      1,
      reason: '这周没空',
      dueOn: DateTime(target.year, target.month, target.day, 9),
    );
    final s = await db.readState(TodoSourceType.scheduleReminder, 1);
    expect(s?.deferCount, 1);
    expect(s?.nextDueAt, isNotNull);
    expect(s?.handleNote, '这周没空');
  });

  test('裁定④：回拉判断用 next_due_at 作基准（不是原到期日）', () async {
    final db = newDb();
    await db.addReminder('交电费', dueAt: DateTime.now());
    // 先延到 10 天后。
    final far = DateTime.now().add(const Duration(days: 10));
    await db.defer(
      TodoSourceType.scheduleReminder,
      1,
      dueOn: DateTime(far.year, far.month, far.day, 9),
    );
    // 现在往回拉到 3 天后 → 相对 next_due_at 是回拉 → 必须被拒。
    var threw = false;
    try {
      final mid = DateTime.now().add(const Duration(days: 3));
      await db.defer(
        TodoSourceType.scheduleReminder,
        1,
        dueOn: DateTime(mid.year, mid.month, mid.day, 9),
      );
    } on ArgumentError catch (_) {
      threw = true;
    }
    expect(threw, isTrue, reason: '基准是 next_due_at，不是原到期日');
  });

  // ───────────────── 批次 3 ③：创建/编辑/重复规则 ─────────────────

  test('批次3③：ReminderEditor 能新建/编辑/删除，且只碰 reminders 表',
      () async {
    final db = newDb();
    final editor = db as ReminderEditor;

    final id = await editor.createReminder('交电费',
        detail: '电费单在抽屉',
        dueAt: DateTime.now().add(const Duration(days: 2)),
        repeatRule: RepeatRule.monthly,
        priority: ReminderPriority.high);
    expect(id, isNotNull);

    final items = await db.getReminders();
    expect(items, hasLength(1));
    expect(items.first.title, '交电费');
    expect(items.first.repeatRule, 'monthly');
    expect(items.first.priority, ReminderPriority.high);

    // 编辑：改标题 + 改优先级。
    await editor.editReminder(id,
        title: '交电费（改成新名字）', priority: ReminderPriority.low);
    final after = await db.getReminders();
    expect(after.first.title, '交电费（改成新名字）');
    expect(after.first.priority, ReminderPriority.low);
    expect(after.first.repeatRule, 'monthly', reason: '没传的字段不该被清掉');

    // 编辑：显式清空重复规则。
    await editor.editReminder(id, clearRepeatRule: true);
    final cleared = await db.getReminders();
    expect(cleared.first.repeatRule, isNull);

    // 删除（软删）。
    await editor.removeReminder(id);
    expect(await db.getReminders(), isEmpty);
  });

  test('批次3③：ReminderEditor 不含日报读写能力（窄写口）', () {
    // 编译期保证：ReminderEditor 里不该出现日报方法。
    //
    // **剥掉注释行**再查——与 v41 / v43 同一口径。
    // 这条锁要证明的是「接口的**方法集**里没有日报读写」，
    // 而不是「文档里不许提到那些词」：
    // 接口的注释里会解释「为什么不用那个更宽的接口」，
    // 那是**说明**，不是**能力**。
    final file = File('lib/domain/reminder_editor.dart');
    expect(file.existsSync(), isTrue);
    final out = <String>[];
    for (final line in file.readAsStringSync().split('\n')) {
      final t = line.trim();
      if (t.startsWith('///') || t.startsWith('//') || t.startsWith('*')) {
        continue;
      }
      out.add(line);
    }
    final src = out.join('\n');
    for (final bad in const <String>[
      'saveDailyReport',
      'getDailyReport',
      'getDailyReports',
      'getReminders',
    ]) {
      expect(src.contains(bad), isFalse,
          reason: 'ReminderEditor 不该有日报读写能力 $bad');
    }
  });

  test('批次3③：重复规则取值与文案定死一份', () {
    expect(RepeatRule.labelOf(RepeatRule.daily), '每天');
    expect(RepeatRule.labelOf(RepeatRule.weekly), '每周');
    expect(RepeatRule.labelOf(RepeatRule.monthly), '每月');
    expect(RepeatRule.labelOf(RepeatRule.yearly), '每年');
    expect(RepeatRule.labelOf(null), '不重复');
    expect(RepeatRule.labelOf('乱写'), '不重复');
    expect(RepeatRule.normalize('乱写'), isNull);
  });

  // ───────────────── 批次 3 ②：跨域带域标识 ─────────────────

  test('批次3②：跨域日程条目各带归属域，写口按域走', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await life.addReminder('交电费', dueAt: DateTime.now());
    await work.addReminder('交周报', dueAt: DateTime.now());

    final lifeSource = ScheduleReminderSource(life, InventoryDomain.life);
    final workSource = ScheduleReminderSource(work, InventoryDomain.work);
    expect(lifeSource.id, 'schedule_reminders_life');
    expect(workSource.id, 'schedule_reminders_work');
    expect(lifeSource.displayName, isNot(workSource.displayName));

    final lifeEntries = await lifeSource.loadEntries();
    final workEntries = await workSource.loadEntries();
    expect(lifeEntries.first.domain, InventoryDomain.life);
    expect(workEntries.first.domain, InventoryDomain.work);
  });

  test('批次3④：工作域能力开关 —— 表建齐但本轮不开放写口', () {
    // 能力开关在 domain.dart 里，不是「表不存在」。
    expect(domainSupports(InventoryDomain.life, DomainCapability.reminders),
        isTrue);
    expect(domainSupports(InventoryDomain.work, DomainCapability.reminders),
        isFalse);
  });

  // ───────────────── 批次 3 ⑤：双签勾选同步 ─────────────────

  testWidgets('批次3⑤：日程签勾选 → 日报签读到同一份状态', (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    await life.addReminder('交电费', dueAt: DateTime.now());

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
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 切到日程签 → 勾选那条日程。
    await tester.tap(find.byKey(const Key('overview_tab_schedule')));
    await tester.pumpAndSettle();

    final check = tester.widget<Checkbox>(
      find.byKey(const Key('overview_check_reminder_life_1')),
    );
    expect(check.value, isFalse);

    await tester.tap(find.byKey(const Key('overview_check_reminder_life_1')));
    await tester.pumpAndSettle();

    // 状态写进 todo_states 了（生活库那张表）。
    final states = await life.loadStates();
    expect(states, hasLength(1));
    expect(states.first.isDone, isTrue);

    // 切回日报签 → 同一条目显示已处理（划线灰化）。
    await tester.tap(find.byKey(const Key('overview_tab_report')));
    await tester.pumpAndSettle();
    final reportCheck = tester.widget<Checkbox>(
      find.byKey(const Key('overview_check_reminder_life_1')),
    );
    expect(reportCheck.value, isTrue, reason: '两个签共用同一份待办状态');
  });

  // ───────────────── 批次 3 ①：月历 + 时间轴 ─────────────────

  testWidgets('批次3①：月历缩略可折叠，展开后有日程的日子打点',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    final now = DateTime.now();
    await life.addReminder('交电费',
        dueAt: DateTime(now.year, now.month, now.day + 1, 9));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OverviewPage(
          reader: InventoryOverviewReader(life: life, work: work),
          sources: <ReminderSource>[
            ScheduleReminderSource(life, InventoryDomain.life),
          ],
          todoWriters: <InventoryDomain, TodoStateWriter>{
            InventoryDomain.life: life,
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('overview_tab_schedule')));
    await tester.pumpAndSettle();

    // 月历卡存在，网格默认收起。
    expect(find.byKey(const Key('schedule_calendar_card')), findsOneWidget);
    expect(find.byKey(const Key('schedule_cal_day_1')), findsNothing);

    // 点标题展开。
    await tester.tap(find.byKey(const Key('schedule_calendar_header')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule_cal_day_1')), findsOneWidget);

    // 时间轴上有那条日程。
    expect(find.byKey(const Key('schedule_entry_reminder_life_1')),
        findsOneWidget);
  });

  testWidgets('批次3①：时间轴按到期日分组，跨域条目各带域标识',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    await life.addReminder('交电费', dueAt: DateTime.now());
    await work.addReminder('交周报', dueAt: DateTime.now());

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OverviewPage(
          reader: InventoryOverviewReader(life: life, work: work),
          sources: <ReminderSource>[
            ScheduleReminderSource(life, InventoryDomain.life),
            ScheduleReminderSource(work, InventoryDomain.work),
          ],
          todoWriters: <InventoryDomain, TodoStateWriter>{
            InventoryDomain.life: life,
            InventoryDomain.work: work,
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('overview_tab_schedule')));
    await tester.pumpAndSettle();

    // 两条都在时间轴上。
    expect(find.byKey(const Key('schedule_entry_reminder_life_1')),
        findsOneWidget);
    expect(find.byKey(const Key('schedule_entry_reminder_work_1')),
        findsOneWidget);
    // 各带域标识。
    expect(find.byKey(const Key('schedule_domain_tag_reminder_life_1')),
        findsOneWidget);
    expect(find.byKey(const Key('schedule_domain_tag_reminder_work_1')),
        findsOneWidget);
  });

  // ───────────────── 写边界 ─────────────────

  test('写边界：概览区不持写口（源码级）', () {
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

    for (final path in const <String>[
      'lib/ui/overview_page.dart',
      'lib/ui/schedule_tab_view.dart',
    ]) {
      final src = codeOnly(path);
      for (final bad in const <String>[
        'InventoryRepository',
        'InventoryDatabase',
        'ReminderRepository',
        'ReminderEditor',
      ]) {
        expect(src.contains(bad), isFalse,
            reason: '概览区不该持有写口 $bad（$path）——写操作归组合根');
      }
    }
  });

  test('写边界：概览区用回调表达写意图（源码级）', () {
    final src = File('lib/ui/overview_page.dart').readAsStringSync();
    for (final cb in const <String>[
      'onCreateReminder',
      'onEditReminder',
      'onDeleteReminder',
    ]) {
      expect(src.contains(cb), isTrue,
          reason: '概览页该用回调 $cb 表达写意图');
    }
  });

  test('写边界：组合根才是持写口的地方', () {
    final src = File('lib/ui/home_page.dart').readAsStringSync();
    expect(src.contains('ReminderEditor'), isTrue,
        reason: '组合根该持有提醒写口并执行写操作');
  });
}
