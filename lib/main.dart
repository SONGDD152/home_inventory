// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/material.dart';

import 'data/daily_report_service.dart';
import 'data/domain.dart';
import 'data/inventory_database.dart';
import 'data/report_state_store.dart';
import 'domain/domain_hub.dart';
import 'domain/overview_reader.dart';
import 'domain/reminder_source.dart';
import 'domain/reminder_sources.dart';
import 'domain/todo_state_writer.dart';
import 'ui/home_page.dart';

/// 应用入口：生产使用 sqflite 默认工厂，注入到界面。
///
/// 测试不走这里，而是直接构造 HomePage 并注入临时文件库。
///
/// **V4.0 多域（物理分库）**：生活域与工作域各持独立 `.db`——
/// 生活域沿用 `home_inventory.db`（路径不变，用户既有数据天然保留），
/// 工作域新建 `work_inventory.db`。两域共用同一套引擎代码，
/// 由 [DomainHub] 统一把守切域（切库守卫）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final life = InventoryDatabase(domain: InventoryDomain.life);
  final work = InventoryDatabase(domain: InventoryDomain.work);
  final hub = DomainHub(life: life, work: work);

  // 日报服务：每天第一次打开 App 时检查昨天有没有日报，没有就补生成
  // （判据：已处理过的日期集合，按设备本地日期；系统时间回拨不重复补生成）。
  final reportService = DailyReportService(
    storage: life,
    reminders: life,
    overview: InventoryOverviewReader(life: life, work: work),
    stateStore: FileReportStateStore(),
    // V4.1 批次 2：日报导出要带「已完成 / 未完成」两块内容，
    // 数据来自催办源 + todo_states 状态——与概览日报签**同一份口径**。
    //
    // **逐域注入**：`todo_states` 每库一张表，催办条目却跨两域，
    // 只给生活库 → 工作区条目的状态读不到 → 导出与界面对不上
    // （违反元宝 B6 的同源要求）。
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

  runApp(HomeInventoryApp(
    database: life,
    hub: hub,
    reportService: reportService,
  ));

  // 补生成不阻塞首帧：失败也不影响 App（日报只是附加功能）。
  unawaited(_fillYesterdayReport(reportService));
}

/// 补生成昨天日报（失败不影响 App：日报只是附加功能）。
Future<void> _fillYesterdayReport(DailyReportService service) async {
  try {
    await service.ensureYesterdayReport();
  } catch (_) {
    // 静默：日报补生成失败不该挡住用户记账。
  }
}

class HomeInventoryApp extends StatelessWidget {
  const HomeInventoryApp({
    super.key,
    required this.database,
    this.hub,
    this.reportService,
  });

  final InventoryDatabase database;

  /// V4.0 域中枢（null = 单域形态）。
  final DomainHub? hub;

  /// V4.0 日报服务（null = 无日报能力）。
  final DailyReportService? reportService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '家庭仓储布局',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.green),
      // V4.1 批次 2：日报服务往下传到 HomePage → 概览日报签的「日报」入口
      // 才能打开日报页（此前 DailyReportPage 是孤儿页，全仓无引用）。
      home: HomePage(
        repository: database,
        hub: hub,
        reportService: reportService,
      ),
    );
  }
}
