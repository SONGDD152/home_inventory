// ignore_for_file: deprecated_member_use
// V4.1.5 专项：月历翻月 + 图标字体根因修复。
//
// 背景（真机反馈 2026-11-28）：PM 想看 12 月翻不了页。
// 翻月箭头（schedule_cal_prev/next）V4.1 批次3 就在代码里，
// 但 `uses-material-design: false` 导致 APK 不打包 MaterialIcons
// 字体 → 全 app 73 处 Icons.* 图标在真机上全是空白，箭头
// 「存在但看不见」。本版根因修复 = 打开字体打包，
// 并锁死 pubspec 不许再关。
//
// 教训：图标不可见是**构建配置**问题，widget 测试里图标
// 永远"能找到"（find 不依赖字体渲染），只有真机撞得出。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/todo_state.dart';
import 'package:home_inventory/domain/todo_state_writer.dart';
import 'package:home_inventory/ui/schedule_tab_view.dart';

/// 把当前月导航到目标年月（可正可负，跨年自动溢出）。
Future<void> _navigateTo(WidgetTester tester, int year, int month) async {
  final now = DateTime.now();
  var diff = (year - now.year) * 12 + (month - now.month);
  while (diff != 0) {
    await tester.tap(find.byKey(
        Key(diff > 0 ? 'schedule_cal_next' : 'schedule_cal_prev')));
    await tester.pumpAndSettle();
    diff += diff > 0 ? -1 : 1;
  }
}

String _monthText(int year, int month) {
  // DateTime(month+1) 自动处理 12→次年1月 与 1→上年12月。
  final d = DateTime(year, month);
  return '${d.year} 年 ${d.month} 月';
}

Future<Widget> _harness(List<ScheduleTabEntry> entries) async {
  return MaterialApp(
    home: Scaffold(
      body: ScheduleTabView(
        entries: entries,
        todoWriters: const <InventoryDomain, TodoStateWriter>{},
        statesByKey: const <String, TodoState>{},
      ),
    ),
  );
}

void main() {
  // 视口用真机逻辑尺寸（项目惯例），并展开月历卡。
  Future<void> pumpExpanded(WidgetTester tester,
      List<ScheduleTabEntry> entries) async {
    await tester.pumpWidget(await _harness(entries));
    await tester.pumpAndSettle();
    final header = find.byKey(const Key('schedule_calendar_header'));
    await tester.ensureVisible(header);
    await tester.tap(header);
    await tester.pumpAndSettle();
  }

  testWidgets('翻月：点一次下一月、点两次上一月（相对当前月，不依赖运行日期）',
      (tester) async {
    await pumpExpanded(tester, const <ScheduleTabEntry>[]);
    final now = DateTime.now();

    await tester.tap(find.byKey(const Key('schedule_cal_next')));
    await tester.pumpAndSettle();
    final next = DateTime(now.year, now.month + 1);
    expect(find.text(_monthText(next.year, next.month)), findsOneWidget);

    await tester.tap(find.byKey(const Key('schedule_cal_prev')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('schedule_cal_prev')));
    await tester.pumpAndSettle();
    final prev = DateTime(now.year, now.month - 1);
    expect(find.text(_monthText(prev.year, prev.month)), findsOneWidget);
  });

  testWidgets('跨年翻月：12 月再往后 → 次年 1 月；农历/节日照常标注（元旦）',
      (tester) async {
    await pumpExpanded(tester, const <ScheduleTabEntry>[]);
    // 导航到 2027-01（从任何月份出发都能到，跨年由 DateTime 溢出兜底）。
    await _navigateTo(tester, 2027, 1);
    expect(find.text('2027 年 1 月'), findsOneWidget);
    // 翻月后农历/节日仍工作：2027-01-01 元旦。
    expect(find.textContaining('元旦'), findsWidgets,
        reason: '翻到别的月份农历/节日标注不失效');
  });

  testWidgets('翻月后蓝点与副标题按显示月走（别的月有日程也点得出来）',
      (tester) async {
    final now = DateTime.now();
    final nextMonth = DateTime(now.year, now.month + 1, 5);
    await pumpExpanded(tester, <ScheduleTabEntry>[
      ScheduleTabEntry(
        id: 'reminder_life_1',
        title: '下月的事',
        domain: InventoryDomain.life,
        reminderId: 1,
        dueAt: nextMonth.millisecondsSinceEpoch,
      ),
    ]);
    // 当前月：副标题 0 天（这条日程在下月）。
    expect(find.textContaining('共 0 天有日程'), findsOneWidget);

    // 翻到下月：蓝点出现（该格 bold+有日程）→ 用副标题与格子文本双重锁。
    await tester.tap(find.byKey(const Key('schedule_cal_next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('共 1 天有日程'), findsOneWidget,
        reason: '副标题按当前显示月统计，不再显示全部月份总数');
    expect(find.byKey(Key('schedule_cal_day_${nextMonth.day}')),
        findsOneWidget);
  });

  test('源码级锁：uses-material-design 必须为 true（根因修复，不许再关）', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec.contains('uses-material-design: true'), isTrue,
        reason: 'false 会把 MaterialIcons 字体排除出 APK，'
            '真机上全部 Icons.* 图标渲染成空白（V4.1.5 根因修复）');
    expect(pubspec.contains('uses-material-design: false'), isFalse);
  });

  test('源码级锁：翻月箭头必须存在（schedule_cal_prev/next）', () {
    final src = File('lib/ui/schedule_tab_view.dart').readAsStringSync();
    expect(src.contains("Key('schedule_cal_prev')"), isTrue);
    expect(src.contains("Key('schedule_cal_next')"), isTrue);
  });

  test('源码级锁：按钮颜色全 APK 一致——主题绿色种子 + 选中高亮走主题', () {
    final main = File('lib/main.dart').readAsStringSync();
    final sched = File('lib/ui/schedule_tab_view.dart').readAsStringSync();
    expect(main, contains('colorSchemeSeed: Colors.green'),
        reason: '全局主题绿色种子（PM 拍板：所有按钮颜色一致）');
    expect(sched, contains('colorScheme.primaryContainer'),
        reason: '月历选中高亮走主题色，不再硬编码蓝色');
  });
}
