// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/domain/overview_reader.dart';
import 'package:home_inventory/domain/reminder_source.dart';
import 'package:home_inventory/domain/reminder_sources.dart';
import 'package:home_inventory/domain/todo_state_writer.dart';
import 'package:home_inventory/ui/overview_page.dart';

import 'fake_domain_repository.dart';

/// V4.1.1 **整改 2** 专项：日程签提醒列表可滚动。
///
/// ## 缺陷现象（PM 2026-11-27 真机手点）
///
/// 日程 Tab 里提醒超过一屏后**无法滑动**，下方内容够不着。
/// 复现：日程页 → 新建 5 条以上提醒 → 上下拖拽列表。
///
/// ## 真因（不是「手势被抢」，是**弹窗把页面 build 打断了**）
///
/// `ReminderEditDialog.show()` 原来是**静态方法**：
///
/// ```dart
/// final result = await showDialog<ReminderDraft>(...);
/// titleController.dispose();   // ← showDialog 一返回就 dispose
/// detailController.dispose();
/// ```
///
/// 但 `showDialog` 返回时**弹窗的退出动画还没播完**——
/// 对话框还在 `Overlay` 里做反向动画，它的 `TextField` 会在这段时间
/// 继续 rebuild，一 rebuild 就撞上「controller 已被 dispose」：
///
/// - `A TextEditingController was used after being disposed`
/// - `'_dependents.isEmpty': is not true`
/// - `Tried to build dirty widget in the wrong build scope`
///
/// **整个页面的 build 被打断** → 用户看到的就是
/// 「新建完提醒之后，日程列表再也拖不动」。
///
/// 修法：弹窗改成 `StatefulWidget`，controller 随 `State` 生命周期，
/// `dispose` 由框架在组件**真正卸载**时调用（那时动画早已结束）。
///
/// ## 怎么测「能滚」（而不是猜）
///
/// **不靠「条目在不在 widget 树里」判断**——`ListView.builder` 会预建
/// 缓存区（cacheExtent）外的条目，「第 10 条 findsNothing」这种前置断言
/// 既不稳也不准（实测会误判）。
///
/// 直接量**滚动位移**：`ScrollableState.position.pixels`
/// 拖动前后必须变大。这是「能滚」的定义式判据。
///
/// ## 屏幕尺寸
///
/// **逻辑 360×640**（物理 1080×1920 ÷ dpr 3.0）——真机典型手机尺寸。
///
/// v44 的旧 widget 测试用 `Size(1200, 3000)` + dpr 1.0 = 1200×3000 **逻辑**像素，
/// 那是平板尺寸，10 条日程一屏就装得下，**根本测不出滚动问题**——
/// 这是本缺陷能一路漏到真机的原因之一。
///
/// ## 为什么用 fake 而不是真库
///
/// 真库（sqflite ffi）跑在**独立 isolate** 上，与 widget 测试的 FakeAsync
/// 时钟不同步 → `pumpAndSettle` 永远等不到静止帧（实测卡满 10 分钟超时）。
/// widget 测试一律用纯 Dart fake。
void main() {
  /// 造 10 条提醒（全部同一天 → 时间轴一个分组、10 行）。
  Future<void> seedTen(FakeDomainRepository life) async {
    final now = DateTime.now();
    for (var i = 1; i <= 10; i++) {
      await life.addReminder('提醒$i',
          dueAt: DateTime(now.year, now.month, now.day, 9, i));
    }
  }

  Future<void> pumpScheduleTab(
      WidgetTester tester, FakeDomainRepository life) async {
    final work = FakeDomainRepository();
    // **逻辑 360×640**（物理 1080×1920 ÷ dpr 3.0）——真机典型手机尺寸。
    //
    // v44 的旧 widget 测试用 `Size(1200, 3000)` + dpr 1.0 = 1200×3000 **逻辑**像素，
    // 那是平板尺寸，10 条日程一屏就装得下，**根本测不出滚动问题**——
    // 这是本缺陷能一路漏到真机的原因之一。
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

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
          // 开放生活域的日程编辑（真实组合根里由能力开关决定）。
          editableScheduleDomains: const <InventoryDomain>{
            InventoryDomain.life,
          },
          onCreateReminder: (domain, draft) async {
            await life.addReminder(draft.title,
                dueAt: draft.dueAt, detail: draft.detail);
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('overview_tab_schedule')));
    await tester.pumpAndSettle();
  }

  /// 日程签的滚动位移（0 = 没滚）。
  ///
  /// **取该 ListView 内部的 [Scrollable]**——
  /// `ListView` 自己不是 `StatefulWidget`（拿不到 `state<ScrollableState>`），
  /// 它内部的 `Scrollable` 才是滚动状态真正的持有者。
  double scrollOffset(WidgetTester tester) {
    final scrollable = find.descendant(
      of: find.byKey(const Key('overview_schedule_tab')),
      matching: find.byType(Scrollable),
    );
    final state = tester.state<ScrollableState>(scrollable.first);
    return state.position.pixels;
  }

  testWidgets('整改2：日程签 10 条提醒 → 列表能滚动', (tester) async {
    final life = FakeDomainRepository();
    await seedTen(life);
    await pumpScheduleTab(tester, life);

    // 起点：没滚过。
    expect(scrollOffset(tester), 0, reason: '初始应在顶部');

    // **往上拖**——列表必须能滚。
    await tester.drag(
      find.byKey(const Key('overview_schedule_tab')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();

    expect(scrollOffset(tester), greaterThan(0),
        reason: '整改2：日程签列表必须能滚动——拖动后滚动位移应大于 0');
  }, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('整改2：新建提醒后列表仍能滚（真因回归锁）', (tester) async {
    // **这条是整改 2 的核心回归锁**——
    // PM 的复现路径是「新建 5 条以上提醒 → 拖拽」，
    // 真因是弹窗 controller 提前 dispose 打断了页面 build。
    final life = FakeDomainRepository();
    // 先垫 8 条 → 内容超一屏（360×640 的视口装不下），
    // 这样「能不能滚」才有得判（否则装得下，位移当然是 0）。
    await seedTen(life);
    await pumpScheduleTab(tester, life);

    // 通过 UI 新建 3 条（走真实的弹窗 → 回调路径）。
    for (var i = 1; i <= 3; i++) {
      await tester.tap(find.byKey(const Key('schedule_add')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('reminder_title_field')), 'UI新建$i');
      await tester.pump();
      await tester.tap(find.byKey(const Key('reminder_save')));
      await tester.pumpAndSettle();
    }

    // **弹窗退出动画期间不能抛「controller 已 dispose」**——
    // 那正是打断页面 build、把列表搞废的真凶。
    expect(tester.takeException(), isNull,
        reason: '整改2：弹窗退出动画期间不得抛 controller 已 dispose');

    // 新建确实落库了。
    expect((await life.getReminders()).length, 13);

    // **建完之后列表还能滚**——这才是 PM 报的原始现象。
    await tester.drag(
      find.byKey(const Key('overview_schedule_tab')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    expect(scrollOffset(tester), greaterThan(0),
        reason: '整改2：新建提醒后列表必须仍能滚动');
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('整改2：滚动后条目仍可勾选（滚不是把交互滚没了）',
      (tester) async {
    final life = FakeDomainRepository();
    await seedTen(life);
    await pumpScheduleTab(tester, life);

    await tester.drag(
      find.byKey(const Key('overview_schedule_tab')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(scrollOffset(tester), greaterThan(0));

    // 滚到第 10 条后，它的勾选框要点得动（滚完了东西还能用）。
    final check = find.byKey(const Key('overview_check_reminder_life_10'));
    expect(check, findsOneWidget, reason: '第 10 条的勾选框要能滚进视口');
    await tester.tap(check);
    await tester.pumpAndSettle();

    // 状态真写进库了。
    final states = await life.loadStates();
    expect(states.any((s) => s.entryKey.endsWith('schedule_reminder_10')),
        isTrue,
        reason: '第 10 条勾选必须真落库');
  }, timeout: const Timeout(Duration(seconds: 90)));
}
