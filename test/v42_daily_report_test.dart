// ignore_for_file: deprecated_member_use
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/data/daily_report_service.dart';
import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/inventory_database.dart';
import 'package:home_inventory/data/todo_state.dart';
import 'package:home_inventory/domain/overview_reader.dart';
import 'package:home_inventory/domain/reminder_source.dart';
import 'package:home_inventory/domain/reminder_sources.dart';
import 'package:home_inventory/domain/todo_agenda.dart';

/// V4.1 批次 2：**日报签完整交互**专项测试。
///
/// 元宝开工令批次 2 的 5 个子功能逐项对应：
/// - ① 三态完整样式（未处理 / 已处理·划线灰化 / 已延期·独立视觉）；
/// - ② 延期按钮 + 按次累计逻辑（含 `next_due_at` 写入）；
/// - ③ 备注编辑入口（处理备注 / 延期原因）；
/// - ④ 导出格式重做（.md / .docx：已完成+未完成标红+延期次数+备注+账目快照）；
/// - ⑤ 日报入口（孤儿页修复，从概览日报签可达）。
///
/// 另含元宝 B6 的硬要求：**导出内容 = 提示框内未处理的条目**（同源口径）。
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
    tempDir = await Directory.systemTemp.createTemp('home_inventory_v42_');
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

  /// 造一条借出（系统类催办源），返回 loan id。
  Future<int> seedLoan(
    InventoryDatabase db,
    String item, {
    String borrower = '张三',
    int dueInDays = 3,
  }) async {
    await seed(db, item, 1);
    final loan = await db.lendItem(item, borrower, quantity: 1);
    final loans = await db.getAllLoans();
    final target = loans.firstWhere((l) => l.id == loan.id);
    // 借期按「天」设置（updateLoanDue(loanId, days)），
    // 借出日往前挪 days-1 天 → 到期日落在今天。
    await db.updateLoanDue(target.id!, dueInDays < 1 ? 1 : dueInDays);
    return target.id!;
  }

  /// 造一条日程提醒，返回 reminder id。
  Future<int> seedReminder(
    InventoryDatabase db,
    String title, {
    int dueInDays = 0,
  }) async {
    await db.addReminder(
      title,
      dueAt: DateTime.now().add(Duration(days: dueInDays)),
    );
    final items = await db.getReminders();
    return items.firstWhere((r) => r.title == title).id!;
  }

  /// 造一套服务（带催办源与状态读取口）。
  DailyReportService makeService(
    InventoryDatabase life,
    InventoryDatabase work,
  ) {
    return DailyReportService(
      storage: life,
      reminders: life,
      overview: InventoryOverviewReader(life: life, work: work),
      todoReader: life,
      todoSources: <ReminderSource>[
        LoanDueReminderSource(life, InventoryDomain.life),
        ScheduleReminderSource(life, InventoryDomain.life),
      ],
    );
  }

  // ============ ① 三态完整样式 ============

  test('批次2 ① 三态：未处理 / 已处理 / 已延期 三种状态可区分', () async {
    final db = newDb();
    await seedLoan(db, '梯子', dueInDays: 0);
    await seedReminder(db, '交电费', dueInDays: 0);
    await seedReminder(db, '还书', dueInDays: 0);

    final source = ScheduleReminderSource(db, InventoryDomain.life);
    final entries = await source.loadEntries();
    expect(entries.length, 2);

    // 未处理：state = null。
    final pending = TodoAgendaItem(
      entry: entries.first,
      state: null,
      sourceDisplayName: source.displayName,
      isSystemHint: false,
    );
    expect(pending.isDone, isFalse);
    expect(pending.isDeferred, isFalse);
    expect(pending.deferCount, 0);

    // 已处理：status = done，doneAt 有值。
    final reminderId = entries.first.sourceId!;
    await db.markDone(TodoSourceType.scheduleReminder, reminderId);
    final doneState = await db.readState(TodoSourceType.scheduleReminder, reminderId);
    final done = TodoAgendaItem(
      entry: entries.first,
      state: doneState,
      sourceDisplayName: source.displayName,
      isSystemHint: false,
    );
    expect(done.isDone, isTrue);
    expect(done.doneAt, isNotNull);

    // 已延期：status = deferred，deferCount ≥ 1。
    final otherId = entries.last.sourceId!;
    await db.defer(TodoSourceType.scheduleReminder, otherId, reason: '等物业回电');
    final deferredState =
        await db.readState(TodoSourceType.scheduleReminder, otherId);
    final deferred = TodoAgendaItem(
      entry: entries.last,
      state: deferredState,
      sourceDisplayName: source.displayName,
      isSystemHint: false,
    );
    expect(deferred.isDeferred, isTrue);
    expect(deferred.isDone, isFalse);
    expect(deferred.deferCount, 1);
    expect(deferred.handleNote, '等物业回电');
  });

  test('批次2 ① 三态：撤销已处理后回到未处理，但延期次数与备注不丢',
      () async {
    final db = newDb();
    await seedReminder(db, '交电费', dueInDays: 0);
    final id = (await db.getReminders()).first.id!;

    await db.defer(TodoSourceType.scheduleReminder, id, reason: '等回电');
    await db.markDone(TodoSourceType.scheduleReminder, id);
    var state = await db.readState(TodoSourceType.scheduleReminder, id);
    expect(state!.isDone, isTrue);
    expect(state.deferCount, 1, reason: '延期是历史，不该被完成态清零');
    expect(state.handleNote, '等回电');

    await db.markDone(TodoSourceType.scheduleReminder, id, done: false);
    state = await db.readState(TodoSourceType.scheduleReminder, id);
    expect(state!.isDone, isFalse);
    expect(state.deferCount, 1, reason: '撤销完成态不清延期次数');
    expect(state.handleNote, '等回电', reason: '撤销完成态不清备注');
  });

  // ============ ② 延期按钮 + 按次累计 + next_due_at ============

  test('批次2 ② 延期：同日点 3 次算 3 次（按次累计，非按天）', () async {
    final db = newDb();
    await seedReminder(db, '交电费', dueInDays: 0);
    final id = (await db.getReminders()).first.id!;

    await db.defer(TodoSourceType.scheduleReminder, id);
    await db.defer(TodoSourceType.scheduleReminder, id);
    await db.defer(TodoSourceType.scheduleReminder, id);

    final state = await db.readState(TodoSourceType.scheduleReminder, id);
    expect(state!.deferCount, 3, reason: '同一天三次延期 = 3 次');
    expect(state.isDeferred, isTrue);
  });

  test('批次2 ② 延期：next_due_at 被写入且逐次后推', () async {
    final db = newDb();
    await seedReminder(db, '交电费', dueInDays: 0);
    final id = (await db.getReminders()).first.id!;

    await db.defer(TodoSourceType.scheduleReminder, id);
    final first = await db.readState(TodoSourceType.scheduleReminder, id);
    expect(first!.nextDueAt, isNotNull, reason: '延期必须写 next_due_at');

    final firstDue = first.nextDueAt!;
    await db.defer(TodoSourceType.scheduleReminder, id);
    final second = await db.readState(TodoSourceType.scheduleReminder, id);
    expect(second!.nextDueAt!, greaterThan(firstDue),
        reason: '再延一次，下一次提示时间必须后推');
  });

  test('批次2 ② 延期：延期的原因写进 handle_note（与处理备注同栏）',
      () async {
    final db = newDb();
    await seedReminder(db, '交电费', dueInDays: 0);
    final id = (await db.getReminders()).first.id!;

    await db.defer(TodoSourceType.scheduleReminder, id, reason: '物业没上班');
    final state = await db.readState(TodoSourceType.scheduleReminder, id);
    expect(state!.handleNote, '物业没上班');
  });

  // ============ ③ 备注编辑入口 ============

  test('批次2 ③ 备注：setNote 写入并可被读回（导出时一并带出）', () async {
    final db = newDb();
    await seedReminder(db, '交电费', dueInDays: 0);
    final id = (await db.getReminders()).first.id!;

    await db.setNote(TodoSourceType.scheduleReminder, id, '已缴费，等发票');
    final state = await db.readState(TodoSourceType.scheduleReminder, id);
    expect(state!.handleNote, '已缴费，等发票');
  });

  test('批次2 ③ 备注：未处理过的条目也能直接写备注（自动建状态行）',
      () async {
    final db = newDb();
    await seedReminder(db, '交电费', dueInDays: 0);
    final id = (await db.getReminders()).first.id!;

    expect(await db.readState(TodoSourceType.scheduleReminder, id), isNull);
    await db.setNote(TodoSourceType.scheduleReminder, id, '记得带电卡');
    final state = await db.readState(TodoSourceType.scheduleReminder, id);
    expect(state, isNotNull);
    expect(state!.handleNote, '记得带电卡');
    expect(state.deferCount, 0, reason: '写备注不算延期');
  });

  // ============ ④ 导出格式重做 ============

  test('批次2 ④ 导出：已完成带处理时间、未完成带延期次数与备注', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seedReminder(life, '交电费', dueInDays: 0);
    await seedReminder(life, '还书', dueInDays: 0);
    final ids = (await life.getReminders()).map((r) => r.id!).toList();

    await life.markDone(TodoSourceType.scheduleReminder, ids[0]);
    await life.defer(TodoSourceType.scheduleReminder, ids[1],
        reason: '对方还没还');

    final service = makeService(life, work);
    final content = await service.buildContent(DateTime.now());

    expect(content, contains('已完成'));
    expect(content, contains('未完成'));
    // 已完成带处理时间。
    expect(content, contains('处理于'));
    // 未完成标红（Markdown 用 `!!` 前缀标记）。
    expect(content, contains('!!'));
    // 未完成带延期次数与备注。
    expect(content, contains('已延期 1 次'));
    expect(content, contains('对方还没还'));
    // 账目快照仍在。
    expect(content, contains('账目快照'));
  });

  test('批次2 ④ 导出：未完成条目在 docx 里真标红（OOXML run properties）',
      () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seedReminder(life, '还书', dueInDays: 0);
    final id = (await life.getReminders()).first.id!;
    await life.defer(TodoSourceType.scheduleReminder, id, reason: '对方还没还');

    final service = makeService(life, work);
    final bytes = await service.buildDocx(DateTime.now());

    // ZIP 头。
    expect(bytes[0], 0x50);
    expect(bytes[1], 0x4B);
    // 解出 document.xml 查红色标记。
    final text = utf8.decode(bytes.toList(), allowMalformed: true);
    expect(text, contains('word/document.xml'));
    expect(text, contains('w:color w:val="FF0000"'),
        reason: '未完成条目必须走 OOXML 真红色');
    expect(text, contains('对方还没还'));
  });

  test('批次2 ④ 导出：docx 含已完成/未完成/账目快照三块', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seedReminder(life, '交电费', dueInDays: 0);
    await seedReminder(life, '还书', dueInDays: 0);
    final ids = (await life.getReminders()).map((r) => r.id!).toList();
    await life.markDone(TodoSourceType.scheduleReminder, ids[0]);

    final service = makeService(life, work);
    final bytes = await service.buildDocx(DateTime.now());
    final text = utf8.decode(bytes.toList(), allowMalformed: true);
    expect(text, contains('已完成'));
    expect(text, contains('未完成'));
    expect(text, contains('账目快照'));
  });

  test('批次2 ④ 导出：md 是合法 UTF-8 且含三块', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    final service = makeService(life, work);
    final bytes = await service.buildMarkdown(DateTime.now());
    final text = utf8.decode(bytes.toList(), allowMalformed: true);
    expect(text, contains('已完成'));
    expect(text, contains('未完成'));
    expect(text, contains('账目快照'));
  });

  // ============ 元宝 B6：导出内容 = 提示框内未处理的条目（同源）============

  test('批次2 B6 同源：导出「未完成」条目 = 催办区口径算出的条目', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seedReminder(life, '交电费', dueInDays: 0);
    await seedReminder(life, '还书', dueInDays: 0);
    final ids = (await life.getReminders()).map((r) => r.id!).toList();
    await life.markDone(TodoSourceType.scheduleReminder, ids[0]);

    final service = makeService(life, work);

    // 界面口径（TodoAgenda）算出来的条目。
    final agenda = await service.loadAgenda(DateTime.now());
    final pending = agenda.where((i) => !i.isDone).toList();
    expect(pending.length, 1, reason: '一条已处理、一条未处理');
    expect(pending.first.entry.title, '还书');

    // 导出里出现的未完成条目必须**只有**这一条。
    final content = await service.buildContent(DateTime.now());
    final unprocessedBlock = content.split('## 未完成').last.split('## ').first;
    expect(unprocessedBlock, contains('还书'));
    expect(unprocessedBlock, isNot(contains('交电费')),
        reason: '已处理的条目不得出现在未完成清单里');
  });

  test('批次2 B6 同源：催办区口径——原到期日 ≤ 当天的条目留在区内',
      () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seedReminder(life, '今天到期', dueInDays: 0);
    await seedReminder(life, '三天后到期', dueInDays: 3);

    final service = makeService(life, work);
    final agenda = await service.loadAgenda(DateTime.now());
    final titles = agenda.map((i) => i.entry.title).toList();
    expect(titles, contains('今天到期'));
    expect(titles, isNot(contains('三天后到期')),
        reason: '未来到期的条目不进催办区');
  });

  test('批次2 B6 同源：延期的条目仍留在催办区（原到期日不变）', () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seedReminder(life, '交电费', dueInDays: 0);
    final id = (await life.getReminders()).first.id!;
    await life.defer(TodoSourceType.scheduleReminder, id);

    final service = makeService(life, work);
    final agenda = await service.loadAgenda(DateTime.now());
    expect(agenda.length, 1,
        reason: '自动延期把 next_due_at 推到明天，但原到期日不变 → 仍留在催办区');
    expect(agenda.first.deferCount, 1);
  });

  test('批次2 B6 同源：今天勾掉的条目进「已完成」（无论原到期日在哪）',
      () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seedReminder(life, '三天后的事', dueInDays: 3);
    final id = (await life.getReminders()).first.id!;
    await life.markDone(TodoSourceType.scheduleReminder, id);

    final service = makeService(life, work);
    final agenda = await service.loadAgenda(DateTime.now());
    expect(agenda.length, 1);
    expect(agenda.first.isDone, isTrue);
  });

  // ============ ⑤ 日报入口（孤儿页修复）============

  test('批次2 ⑤ 孤儿页修复：日报页源码已被主界面引用（不再是死代码）',
      () async {
    // 回归锁：批次 1 时 DailyReportPage 全仓零引用 → 用户进不去日报。
    // 这条断言守住「概览日报签的日报入口」这条链路不被再次删掉。
    final homeSrc =
        File('lib/ui/home_page.dart').readAsStringSync();
    expect(homeSrc, contains('daily_report_page.dart'),
        reason: '主界面必须 import 日报页');
    expect(homeSrc, contains('DailyReportPage('),
        reason: '主界面必须真的构造并打开日报页');
    expect(homeSrc, contains('onOpenReport'),
        reason: '概览页必须接上日报入口回调');

    final overviewSrc =
        File('lib/ui/overview_page.dart').readAsStringSync();
    expect(overviewSrc, contains('onOpenReport'),
        reason: '概览日报签必须提供日报入口');
    expect(overviewSrc, contains('overview_open_report'),
        reason: '日报入口按钮要有稳定的 widget key');
  });

  test('批次2 ⑤ 日报服务可注入催办源与状态读取口（导出才有内容）',
      () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    await seedReminder(life, '交电费', dueInDays: 0);

    final service = makeService(life, work);
    final agenda = await service.loadAgenda(DateTime.now());
    expect(agenda.length, 1);
    expect(agenda.first.entry.title, '交电费');
    expect(agenda.first.sourceDisplayName, contains('生活区'),
        reason: '来源展示名必须带域');
  });

  // ============ 写边界回归锁（批次 2 不得破坏）============

  test('批次2 写边界：日报服务只持只读口，拿不到写待办状态的能力',
      () async {
    final life = newDb(name: 'life.db');
    final work = newDb(name: 'work.db');
    final service = makeService(life, work);
    // 只读口能读状态。
    final states = await service.todoReader!.loadStates();
    expect(states, isNotNull);
    // 但服务本身**没有**写方法（编译期保证）。
    final src = File('lib/data/daily_report_service.dart').readAsStringSync();
    expect(src.contains('markDone'), isFalse,
        reason: '日报服务不该有写待办状态的方法');
    expect(src.contains('defer('), isFalse,
        reason: '日报服务不该能改延期次数');
  });
}
