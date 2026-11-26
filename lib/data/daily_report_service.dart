import 'dart:convert';
import 'dart:typed_data';

import '../domain/overview_reader.dart';
import 'domain.dart';
import 'docx_writer.dart';
import 'inventory_repository.dart';
import 'reminder_repository.dart';
import 'report_state_store.dart';

/// V4.0：日报服务。
///
/// 日报 = 昨天的三块内容：
///  ① 当日提醒清单（标题 + 是否完成）；
///  ② 当日仓储动态（借出 / 归还 / 废弃流水，按时间戳筛）；
///  ③ 概览数字快照（两域汇总）。
///
/// **生成时机**：每天第一次打开 App 时检查昨天有没有日报，没有就补生成。
/// 判据 = 「已处理过的日期集合」，**按设备本地日期**判重，
/// 系统时间回拨到已处理过的日期也**不会重复补生成**（元宝第三轮要求）。
class DailyReportService {
  DailyReportService({
    required this.storage,
    required this.reminders,
    required this.overview,
    ReportStateStore? stateStore,
  }) : stateStore = stateStore ?? InMemoryReportStateStore();

  /// 仓储（提供借出/归还/废弃流水）。
  final InventoryRepository storage;

  /// 提醒（提供当日提醒清单）。
  final ReminderRepository reminders;

  /// 概览读取口（提供两域数字快照）。
  final OverviewReader overview;

  /// 判据状态存储。
  final ReportStateStore stateStore;

  /// 把日期格式化成 `yyyy-MM-dd`（**本地日期**，不用 UTC——用户看到的是本地那天）。
  static String formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  /// 每天首次打开 App 时调用：昨天没日报就补生成，返回是否真的生成了。
  ///
  /// 判重：已处理过的日期集合里**已有昨天** → 跳过（连开 20 次只生成 1 次；
  /// 系统时间回拨到昨天也跳过）。
  Future<bool> ensureYesterdayReport({DateTime? now}) async {
    final today = now ?? DateTime.now();
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    final key = formatDate(yesterday);
    final handled = await stateStore.handledDates();
    if (handled.contains(key)) return false;

    final existing = await reminders.getDailyReport(key);
    if (existing != null) {
      // 已经有日报（手动生成过）→ 只补判据，不重复生成。
      await stateStore.markHandled(key);
      return false;
    }

    final content = await buildContent(yesterday);
    await reminders.saveDailyReport(key, content);
    await stateStore.markHandled(key);
    return true;
  }

  /// 生成某天的日报正文（Markdown）。
  Future<String> buildContent(DateTime date) async {
    final key = formatDate(date);
    final buffer = StringBuffer();
    buffer.writeln('# 家庭仓储日报 · $key');
    buffer.writeln();

    // ① 当日提醒清单
    buffer.writeln('## 提醒清单');
    final items = await reminders.getReminders();
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final todays = items.where((r) {
      final due = r.dueAt;
      if (due == null) return false;
      final at = DateTime.fromMillisecondsSinceEpoch(due);
      return !at.isBefore(dayStart) && at.isBefore(dayEnd);
    }).toList();
    if (todays.isEmpty) {
      buffer.writeln('- 今日没有提醒');
    } else {
      for (final item in todays) {
        buffer.writeln('- [${item.isDone ? 'x' : ' '}] ${item.title}');
      }
    }
    buffer.writeln();

    // ② 当日仓储动态
    buffer.writeln('## 仓储动态');
    final startMs = dayStart.millisecondsSinceEpoch;
    final endMs = dayEnd.millisecondsSinceEpoch;
    final dynamics = <String>[];
    final loans = await storage.getAllLoans();
    for (final loan in loans) {
      if (loan.borrowedAt >= startMs && loan.borrowedAt < endMs) {
        dynamics.add('- 借出：${loan.itemName} → ${loan.borrowerName}（${loan.quantity} 个）');
      }
      final returned = loan.returnedAt;
      if (returned != null && returned >= startMs && returned < endMs) {
        dynamics.add('- 归还：${loan.itemName} ← ${loan.borrowerName}');
      }
    }
    final discards = await storage.getDiscards(includeRestored: true);
    for (final discard in discards) {
      if (discard.discardedAt >= startMs && discard.discardedAt < endMs) {
        dynamics.add('- 废弃：${discard.itemName}（${discard.quantity} 个）');
      }
    }
    if (dynamics.isEmpty) {
      buffer.writeln('- 今日没有仓储变动');
    } else {
      for (final line in dynamics) {
        buffer.writeln(line);
      }
    }
    buffer.writeln();

    // ③ 概览数字快照（两域）
    buffer.writeln('## 账目快照');
    for (final snapshot in await readSnapshots()) {
      buffer.writeln('- ${snapshot.domain.label}：在库 ${snapshot.stock}｜在借 ${snapshot.lent}'
          '｜废弃未恢复 ${snapshot.discardedPending}｜总拥有 ${snapshot.totalOwned}'
          '｜${snapshot.isBalanced ? '账平' : '账不平'}');
    }

    return buffer.toString();
  }

  /// 两域概览快照。
  Future<List<DomainOverview>> readSnapshots() async {
    final life = await overview.read(InventoryDomain.life);
    final work = await overview.read(InventoryDomain.work);
    return <DomainOverview>[life, work];
  }

  /// 导出 Markdown 字节。
  Future<Uint8List> buildMarkdown(DateTime date) async {
    final content = await buildContent(date);
    return Uint8List.fromList(utf8.encode(content));
  }

  /// 导出 docx 字节（**零新增依赖**，自研最小 OOXML 生成）。
  Future<Uint8List> buildDocx(DateTime date) async {
    final key = formatDate(date);
    final content = await buildContent(date);
    // 把 Markdown 的 '#'/'-' 装饰剥掉，正文就是纯行。
    final lines = content
        .split('\n')
        .map((line) => line
            .replaceFirst(RegExp(r'^#+\s*'), '')
            .replaceFirst(RegExp(r'^-\s+\[.\]\s*'), '□ ')
            .replaceFirst(RegExp(r'^-\s+'), '· ')
            .trimRight())
        .where((line) => line.isNotEmpty)
        .toList();
    return DocxWriter.build(title: '家庭仓储日报 · $key', lines: lines);
  }
}
