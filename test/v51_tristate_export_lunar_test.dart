// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/data/daily_report_service.dart';
import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/todo_state.dart';
import 'package:home_inventory/domain/lunar_label.dart';
import 'package:home_inventory/domain/overview_reader.dart';
import 'package:home_inventory/domain/reminder_source.dart';
import 'package:home_inventory/domain/reminder_sources.dart';

import 'fake_domain_repository.dart';

/// V4.1.4 专项：三态勾选 + 日报导出四区 + 月历阴历节日。
/// 纯 Dart + fake 仓储，不碰 ffi（避免 sqflite isolate 与测试卡死）。
void main() {
  // ─────────────── ① 农历标注纯函数 ───────────────

  test('V4.1.4①：农历标注——公历节日优先', () {
    expect(LunarLabel.of(DateTime(2026, 1, 1)), contains('元旦'));
    expect(LunarLabel.of(DateTime(2026, 5, 1)), contains('劳动节'));
    expect(LunarLabel.of(DateTime(2026, 10, 1)), contains('国庆节'));
  });

  test('V4.1.4①：农历节日（春节 / 中秋 / 除夕）可标', () {
    // 2026 春节 = 2 月 17 日（农历正月初一）。
    expect(LunarLabel.of(DateTime(2026, 2, 17)), contains('春节'));
    // 2026 中秋 = 9 月 25 日（农历八月十五）。
    expect(LunarLabel.of(DateTime(2026, 9, 25)), contains('中秋'));
  });

  test('V4.1.4①：初一显示带月，普通日显示农历日', () {
    // 2026-02-17 是正月初一（春节优先，另取一个非节日的初一）。
    final someFirst = LunarLabel.of(DateTime(2026, 3, 19)); // 农历二月初一
    expect(someFirst, contains('初一'));
    expect(someFirst, isNot('初一'), reason: '初一要带月份');
    // 普通日子返回农历日（非空）。
    expect(LunarLabel.of(DateTime(2026, 6, 10)), isNotEmpty);
  });

  test('V4.1.4①：闰月可被正确换算（2025 乙巳年闰六月）', () {
    // 2025-07-25 = 农历闰六月初一。
    expect(LunarLabel.of(DateTime(2025, 7, 25)), contains('闰六月'));
  });

  // ─────────────── ② 三态状态机与写口 ───────────────

  test('V4.1.4②：TodoStatus 三态循环 空→半→满→空', () {
    expect(TodoStatus.next(TodoStatus.pending), TodoStatus.inProgress);
    expect(TodoStatus.next(TodoStatus.inProgress), TodoStatus.done);
    expect(TodoStatus.next(TodoStatus.done), TodoStatus.pending);
    // deferred（系统态）点一下回到空框，不被三态循环吞掉。
    expect(TodoStatus.next(TodoStatus.deferred), TodoStatus.pending);
  });

  test('V4.1.4②：setTodoStatus 写 in_progress 清 done_at，deferred 不被覆盖',
      () async {
    final life = FakeDomainRepository();
    const key = 'schedule_reminder';
    await life.setTodoStatus(key, 1, TodoStatus.inProgress);
    var s = (await life.loadStates()).single;
    expect(s.status, TodoStatus.inProgress);
    expect(s.isInProgress, isTrue);
    expect(s.doneAt, isNull, reason: '进行中不是完成，done_at 必须为空');

    // 系统延期写入 deferred 后，用户三态不该直接覆盖它（数据层只认三态）。
    await life.defer(key, 1, reason: '超期');
    s = (await life.loadStates()).single;
    expect(s.isDeferred, isTrue, reason: 'deferred 仍独立存在');
  });

  test('V4.1.4②：setTodoStatus 写 done 记 done_at 且与 markDone 同源', () async {
    final life = FakeDomainRepository();
    await life.setTodoStatus('schedule_reminder', 1, TodoStatus.done);
    final s = (await life.loadStates()).single;
    expect(s.isDone, isTrue);
    expect(s.doneAt, isNotNull, reason: '完成必须记时间戳供「今日完成」段用');
  });

  // ─────────────── ③ 日报导出四区 ───────────────

  DailyReportService serviceOf(FakeDomainRepository life,
          FakeDomainRepository work) =>
      DailyReportService(
        storage: life,
        reminders: life,
        overview: InventoryOverviewReader(life: life, work: work),
        todoReader: life,
        todoSources: <ReminderSource>[
          ScheduleReminderSource(life, InventoryDomain.life),
        ],
      );

  test('V4.1.4③：四区严格口径——今天 pending / in_progress / 今天 done / 明天 pending',
      () async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    final today = DateTime(2026, 11, 28);
    final tomorrow = today.add(const Duration(days: 1));
    final dayAfter = today.add(const Duration(days: 2));

    // 四条提醒：今天待办 / 今天进行中 / 今天完成 / 明日前瞻 / 后天（不该进任何区）。
    await life.addReminder('今天待办', dueAt: today);
    await life.addReminder('今天在做', dueAt: today);
    await life.addReminder('今天做完', dueAt: today);
    await life.addReminder('明天要做', dueAt: tomorrow);
    await life.addReminder('后天要做', dueAt: dayAfter);

    // 设状态：2=进行中，3=完成（addReminder 返回 id 从 1 起）。
    await life.setTodoStatus('schedule_reminder', 2, TodoStatus.inProgress);
    await life.setTodoStatus('schedule_reminder', 3, TodoStatus.done);

    final service = serviceOf(life, work);
    final sections = await service.loadFourSections(today);

    expect(sections.pending.map((i) => i.entry.title), contains('今天待办'));
    expect(sections.pending.map((i) => i.entry.title),
        isNot(contains('今天在做')), reason: '进行中不进未完成区');
    expect(sections.inProgress.map((i) => i.entry.title), contains('今天在做'));
    expect(sections.done.map((i) => i.entry.title), contains('今天做完'));
    expect(sections.tomorrow.map((i) => i.entry.title), contains('明天要做'),
        reason: '明日前瞻只算明天');
    expect(sections.tomorrow.map((i) => i.entry.title),
        isNot(contains('后天要做')), reason: '不往后堆');
    expect(sections.pending.map((i) => i.entry.title),
        isNot(contains('后天要做')), reason: '后天不进今日未完成');
  });

  test('V4.1.4③：明日前瞻不套提前量——高优先级后天到期不进明天区', () async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    final today = DateTime(2026, 11, 28);
    final dayAfter = today.add(const Duration(days: 2));

    // 高优先级后天到期：若套 isInAgenda(明天) 的提前 3 天会被误纳入。
    await life.addReminder('高优先级后天', dueAt: dayAfter, priority: 2);

    final service = serviceOf(life, work);
    final sections = await service.loadFourSections(today);
    expect(sections.tomorrow.map((i) => i.entry.title),
        isNot(contains('高优先级后天')),
        reason: 'PM 拍板：明日前瞻严格 dateOnly(due)==明天，不套提前量');
  });

  test('V4.1.4③：导出文本四段顺序 + 明日待办标题 + 不显完成进未完成段', () async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    final today = DateTime(2026, 11, 28);

    await life.addReminder('甲待办', dueAt: today);
    await life.addReminder('乙在做', dueAt: today);
    await life.addReminder('丙做完', dueAt: today);
    await life.setTodoStatus('schedule_reminder', 2, TodoStatus.inProgress);
    await life.setTodoStatus('schedule_reminder', 3, TodoStatus.done);

    final content = await serviceOf(life, work).buildContent(today);
    final iPending = content.indexOf('## 未完成');
    final iDoing = content.indexOf('## 今日进行中');
    final iDone = content.indexOf('## 已完成');
    final iTomorrow = content.indexOf('## 明日前瞻');
    expect(iPending, lessThan(iDoing));
    expect(iDoing, lessThan(iDone));
    expect(iDone, lessThan(iTomorrow));
    expect(content, contains('明日待办'));
    // 三段各自归位。
    expect(content.split('## 未完成').last.split('## ').first, contains('甲待办'));
    expect(content.split('## 今日进行中').last.split('## ').first,
        contains('乙在做'));
    expect(content.split('## 已完成').last.split('## ').first, contains('丙做完'));
  });

  // ─────────────── ④ 源码级锁 ───────────────

  test('V4.1.4④：源码级——schema 仍 v13、三态 tristate、lunar 依赖、界面两框不动',
      () {
    final db = File('lib/data/inventory_database.dart').readAsStringSync();
    final ui = File('lib/ui/overview_page.dart').readAsStringSync();
    final sched = File('lib/ui/schedule_tab_view.dart').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final agenda = File('lib/domain/todo_agenda.dart').readAsStringSync();

    expect(pubspec, contains('lunar:'), reason: '月历阴历依赖已引入');
    expect(pubspec, contains('4.1.4+29'), reason: '版号 +29');
    expect(sched, contains('tristate: true'), reason: '三态勾选');
    expect(sched, contains('schedule_lunar_toggle'), reason: '农历开关');
    expect(sched, contains('LunarLabel.of'), reason: '月历用农历标注');
    expect(ui, contains('overview_block_list_'), reason: '两框结构不动');
    expect(agenda, contains('isInProgress'), reason: 'TodoAgenda 暴露进行中态');
    // schema：无 in_progress 列（只加枚举值，不加列）。
    expect(db.contains('columnInProgress'), isFalse,
        reason: 'schema 零新增列');
  });
}
