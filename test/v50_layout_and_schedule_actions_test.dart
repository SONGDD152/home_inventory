// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/reminder.dart';
import 'package:home_inventory/data/todo_state.dart';
import 'package:home_inventory/domain/overview_reader.dart';
import 'package:home_inventory/domain/reminder_source.dart';
import 'package:home_inventory/domain/reminder_sources.dart';
import 'package:home_inventory/domain/todo_state_writer.dart';
import 'package:home_inventory/ui/overview_page.dart';

import 'fake_domain_repository.dart';

/// V4.1.3 真机补充回执专项：
/// ① 日报条目左对齐、单行不折字（勾选框在前、文字 Expanded）；
/// ② 日程条目点整行进编辑；③ 左滑/长按删除（软删回收站 + 硬删二次确认）；
/// ④ 「隐藏已完成」默认开，纯视图过滤不删数据。
void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required FakeDomainRepository life,
    required FakeDomainRepository work,
    bool editable = true,
  }) async {
    tester.view.physicalSize = const Size(1080, 1920); // 真机逻辑 360×640
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

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
          editableScheduleDomains: editable
              ? const <InventoryDomain>{InventoryDomain.life}
              : const <InventoryDomain>{},
          onEditReminder: (domain, id, draft) async {},
          onDeleteReminder: (domain, id) async {
            if (domain == InventoryDomain.life) await life.deleteReminder(id);
          },
          onListDeletedReminders: (domain) =>
              domain == InventoryDomain.life
                  ? life.getDeletedReminders()
                  : work.getDeletedReminders(),
          onRestoreReminder: (domain, id) async {
            if (domain == InventoryDomain.life) await life.restoreReminder(id);
          },
          onPurgeReminder: (domain, id) async {
            if (domain == InventoryDomain.life) await life.purgeReminder(id);
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openSchedule(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('overview_tab_schedule')));
    await tester.pumpAndSettle();
  }

  testWidgets('V4.1.3：日报条目勾选框在前、文字靠左、单行不折字',
      (tester) async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    final now = DateTime.now();
    await life.addReminder('作早餐',
        dueAt: DateTime(now.year, now.month, now.day + 1, 9));
    await work.addReminder('报税',
        dueAt: DateTime(now.year, now.month, now.day + 1, 9));
    await work.addReminder('作分析',
        dueAt: DateTime(now.year, now.month, now.day + 1, 10));
    await pumpPage(tester, life: life, work: work);

    for (final title in <String>['作早餐', '报税', '作分析']) {
      final finder = find.text(title);
      expect(finder, findsOneWidget, reason: '条目文字必须存在：$title');
      final rect = tester.getRect(finder);
      expect(rect.height, lessThan(30),
          reason: '$title 必须单行显示，不能折成「${title.substring(0, 2)}/…」');
      expect(rect.left, lessThan(180),
          reason: '$title 必须靠左，不能居中后右侧大片留白');
      expect(rect.width, greaterThan(60),
          reason: '$title 的文字区要 Expanded 占满剩余宽度');
    }

    // 勾选框在文字左边。
    final check =
        tester.getRect(find.byKey(const Key('overview_check_reminder_life_1')));
    final title = tester.getRect(find.text('作早餐'));
    expect(check.right, lessThan(title.left),
        reason: '勾选框必须在信息前、文字紧随其右');
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('V4.1.3：点日程整行就能进编辑详情', (tester) async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    await life.addReminder('报税', dueAt: DateTime.now());
    await pumpPage(tester, life: life, work: work);
    await openSchedule(tester);

    await tester.tap(find.byKey(const Key('schedule_entry_reminder_life_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reminder_edit_dialog')), findsOneWidget,
        reason: '点条目必须能进详情改标题，不再只有右侧小图标');
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('V4.1.3：长按→移到回收站→在回收站恢复', (tester) async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    await life.addReminder('报税', dueAt: DateTime.now());
    await pumpPage(tester, life: life, work: work);
    await openSchedule(tester);

    await tester.longPress(find.byKey(const Key('schedule_entry_reminder_life_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule_delete_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule_delete_trash')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule_entry_reminder_life_1')), findsNothing,
        reason: '软删后日程签不再显示');
    expect((await life.getReminders()).length, 0, reason: '活跃列表不再含它');
    expect((await life.getDeletedReminders()).length, 1, reason: '它进了回收站');

    await tester.tap(find.byKey(const Key('schedule_open_trash')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule_trash_dialog')), findsOneWidget);
    expect(find.byKey(const Key('schedule_trash_life_1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule_restore_life_1')));
    await tester.pumpAndSettle();
    expect((await life.getDeletedReminders()).isEmpty, isTrue);
    // 恢复按钮自己关弹窗，不用再点「关闭」。
    expect(find.byKey(const Key('schedule_entry_reminder_life_1')), findsOneWidget,
        reason: '恢复后条目回到日程签');
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('V4.1.3：左滑→彻底删除要二次确认，硬删后回收站为空', (tester) async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    await life.addReminder('作分析', dueAt: DateTime.now());
    await pumpPage(tester, life: life, work: work);
    await openSchedule(tester);

    await tester.drag(
        find.byKey(const Key('schedule_entry_reminder_life_1')),
        const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule_delete_dialog')), findsOneWidget,
        reason: '左滑必须弹删除选择');

    await tester.tap(find.byKey(const Key('schedule_delete_purge')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule_purge_confirm')), findsOneWidget,
        reason: '彻底删除必须二次确认');
    await tester.tap(find.byKey(const Key('schedule_purge_confirm_ok')));
    await tester.pumpAndSettle();

    expect((await life.getReminders()).isEmpty, isTrue);
    expect((await life.getDeletedReminders()).isEmpty, isTrue,
        reason: '硬删不留回收站痕迹');
    await tester.tap(find.byKey(const Key('schedule_open_trash')));
    await tester.pumpAndSettle();
    expect(find.text('回收站为空'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('V4.1.3：隐藏已完成默认开，切换只动视图不动数据', (tester) async {
    final life = FakeDomainRepository();
    final work = FakeDomainRepository();
    await life.addReminder('旧衣服', dueAt: DateTime.now());
    await life.addReminder('交电费', dueAt: DateTime.now());
    await life.markDone(TodoSourceType.scheduleReminder, 1);
    await pumpPage(tester, life: life, work: work);
    await openSchedule(tester);

    expect(find.byKey(const Key('schedule_entry_reminder_life_1')), findsNothing,
        reason: '已完成默认隐藏');
    expect(find.byKey(const Key('schedule_entry_reminder_life_2')), findsOneWidget);
    expect((await life.getReminders()).length, 2, reason: '纯视图过滤，不删数据');

    await tester.tap(find.byKey(const Key('schedule_toggle_done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule_entry_reminder_life_1')), findsOneWidget,
        reason: '随时可切回显示');
    await tester.tap(find.byKey(const Key('schedule_toggle_done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule_entry_reminder_life_1')), findsNothing);
    expect((await life.getReminders()).length, 2,
        reason: '来回切换后数据一条不少、不进回收站');
    expect((await life.getDeletedReminders()).isEmpty, isTrue,
        reason: '隐藏已完成不触发软删');
  }, timeout: const Timeout(Duration(seconds: 90)));
}
