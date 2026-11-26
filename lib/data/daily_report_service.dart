import 'dart:convert';
import 'dart:typed_data';

import '../domain/overview_reader.dart';
import '../domain/reminder_source.dart';
import '../domain/todo_agenda.dart';
import '../domain/todo_state_writer.dart';
import 'domain.dart';
import 'docx_writer.dart';
import 'inventory_repository.dart';
import 'reminder_repository.dart';
import 'report_state_store.dart';
import 'todo_state.dart';

/// V4.1：日报服务。
///
/// 日报 = 昨天的三块内容：
///  ① 当日提醒清单（标题 + 是否完成）；
///  ② 当日仓储动态（借出 / 归还 / 废弃流水，按时间戳筛）；
///  ③ 概览数字快照（两域汇总）。
///
/// **生成时机**：每天第一次打开 App 时检查昨天有没有日报，没有就补生成。
/// 判据 = 「已处理过的日期集合」，**按设备本地日期**判重，
/// 系统时间回拨到已处理过的日期也**不会重复补生成**（元宝第三轮要求）。
///
/// ## V4.1 批次 2：导出格式重做（元宝 B6 / B7）
///
/// 导出内容改为三块：
///  ① **已完成**：今日勾选已处理的条目，**带处理时间**；
///  ② **未完成**：提示框内未处理的条目，**标红** + 标注「已延期 N 次」+ 备注；
///  ③ **账目快照**。
///
/// 「未完成 = 提示框内未处理的条目」这条要求意味着导出与界面
/// **必须同源**——所以两边都走 [TodoAgenda] 的同一份口径，
/// 不会出现「界面上勾掉了、导出里还红着」的漂移。
class DailyReportService {
  DailyReportService({
    required this.storage,
    required this.reminders,
    required this.overview,
    this.todoReader,
    this.todoReaders = const <InventoryDomain, TodoStateReader>{},
    this.todoSources = const <ReminderSource>[],
    ReportStateStore? stateStore,
  }) : stateStore = stateStore ?? InMemoryReportStateStore();

  /// 仓储（提供借出/归还/废弃流水）。
  final InventoryRepository storage;

  /// 提醒（提供当日提醒清单 + 日报读写）。
  final ReminderRepository reminders;

  /// 概览读取口（提供两域数字快照）。
  final OverviewReader overview;

  /// 待办状态读取口（提供完成态 / 延期次数 / 备注）。
  ///
  /// null = 该环境没有待办状态能力 → 导出退化为「只有提醒清单 + 账目快照」。
  ///
  /// **单域快捷口**：只覆盖生活域；多域场景请用 [todoReaders]。
  final TodoStateReader? todoReader;

  /// 各域的待办状态读取口（key = 域）。
  ///
  /// **为什么必须按域**：`todo_states` 是**每库一张表**（物理分库），
  /// 而日报的催办条目是**跨域**的（生活区 + 工作区的借出到期都在界面上）。
  /// 只拿生活库的读口 → 工作区条目的状态读不到 → 导出里「未完成」清单
  /// 与界面上的提示框对不上（违反元宝 B6 的同源要求）。
  ///
  /// 状态配对时 key **带域前缀**（见 [TodoAgenda.stateKeyOf]），
  /// 两库的 `loan_due_1` 不会互相覆盖。
  final Map<InventoryDomain, TodoStateReader> todoReaders;

  /// 催办源（提供催办条目）。
  final List<ReminderSource> todoSources;

  /// 判据状态存储。
  final ReportStateStore stateStore;

  /// 把日期格式化成 `yyyy-MM-dd`（**本地日期**，不用 UTC——用户看到的是本地那天）。
  static String formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  /// `HH:mm`（处理时间用）。
  static String formatTime(int? ms) {
    if (ms == null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m';
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

    // ① 催办条目（已完成 / 未完成）——与概览日报签同源。
    final agenda = await loadAgenda(date);
    final done = agenda.where((i) => i.isDone).toList();
    final pending = agenda.where((i) => !i.isDone).toList();

    buffer.writeln('## 已完成');
    if (done.isEmpty) {
      buffer.writeln('- 今日没有已处理的条目');
    } else {
      for (final item in done) {
        final time = formatTime(item.doneAt);
        buffer.writeln('- [x] ${item.entry.title}'
            '${time.isEmpty ? '' : '（处理于 $time）'}'
            '${item.summary.isEmpty ? '' : '｜${item.summary}'}');
      }
    }
    buffer.writeln();

    buffer.writeln('## 未完成');
    if (pending.isEmpty) {
      buffer.writeln('- 今日没有未处理的条目');
    } else {
      for (final item in pending) {
        // 标红标记：Markdown 无颜色语法，用 `!!` 前缀；
        // .docx 走 OOXML 真红色（见 buildDocx）。
        buffer.writeln('!!- [ ] ${item.entry.title}'
            '${item.summary.isEmpty ? '' : '｜${item.summary}'}');
      }
    }
    buffer.writeln();

    // ② 当日仓储动态
    buffer.writeln('## 仓储动态');
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
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

  /// 读取某日的催办条目（条目 + 状态配对），**口径与界面同源**。
  ///
  /// [date] = 报告日期。判定用该日 23:59 作为基准（日报讲的是「那天的事」）。
  Future<List<TodoAgendaItem>> loadAgenda(DateTime date) async {
    if (todoSources.isEmpty) return const <TodoAgendaItem>[];
    // 状态：**逐域读**（todo_states 每库一张表），合并时 key 带域前缀。
    final states = <String, TodoState>{};
    for (final domain in InventoryDomain.values) {
      final reader = todoReaders[domain];
      if (reader == null) continue;
      for (final state in await reader.loadStates()) {
        states[TodoAgenda.stateKeyOf(domain, state.entryKey)] = state;
      }
    }
    // 单域快捷口（未配 todoReaders 时用）：按生活域算。
    final legacy = todoReader;
    if (legacy != null && todoReaders.isEmpty) {
      for (final state in await legacy.loadStates()) {
        states[TodoAgenda.stateKeyOf(InventoryDomain.life, state.entryKey)] =
            state;
      }
    }
    final basis = DateTime(date.year, date.month, date.day, 23, 59, 59);
    final items = <TodoAgendaItem>[];
    for (final source in todoSources) {
      final isSystem = source.id.startsWith('loan_due_');
      for (final entry in await source.loadEntries()) {
        final state =
            states[TodoAgenda.stateKeyOf(entry.domain, entry.stateKey)];
        final item = TodoAgendaItem(
          entry: entry,
          state: state,
          sourceDisplayName: source.displayName,
          isSystemHint: isSystem,
        );
        if (!item.isInAgenda(basis)) continue;
        items.add(item);
      }
    }
    // 排序口径与界面同源（裁定①：优先级高 → 中 → 低）。
    TodoAgenda.sortByPriority(items);
    return items;
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
  ///
  /// 未完成清单**真标红**（OOXML `<w:color w:val="FF0000"/>`）。
  Future<Uint8List> buildDocx(DateTime date) async {
    final key = formatDate(date);
    final agenda = await loadAgenda(date);
    final done = agenda.where((i) => i.isDone).toList();
    final pending = agenda.where((i) => !i.isDone).toList();

    final lines = <DocxLine>[];
    lines.add(const DocxLine('已完成'));
    if (done.isEmpty) {
      lines.add(const DocxLine('· 今日没有已处理的条目'));
    } else {
      for (final item in done) {
        final time = formatTime(item.doneAt);
        lines.add(DocxLine('□ ${item.entry.title}'
            '${time.isEmpty ? '' : '（处理于 $time）'}'
            '${item.summary.isEmpty ? '' : '｜${item.summary}'}'));
      }
    }
    lines.add(const DocxLine(''));
    lines.add(const DocxLine('未完成'));
    if (pending.isEmpty) {
      lines.add(const DocxLine('· 今日没有未处理的条目'));
    } else {
      for (final item in pending) {
        // **标红**：未处理条目在 Word/WPS 里显示为红色加粗。
        lines.add(DocxLine(
          '□ ${item.entry.title}'
          '${item.summary.isEmpty ? '' : '｜${item.summary}'}',
          red: true,
        ));
      }
    }
    lines.add(const DocxLine(''));

    // 仓储动态
    final content = await buildContent(date);
    final dynamics = <String>[];
    final inDynamics = content.contains('## 仓储动态');
    if (inDynamics) {
      final start = content.indexOf('## 仓储动态');
      final end = content.indexOf('## 账目快照');
      if (end > start) {
        final block = content.substring(start, end);
        for (final raw in block.split('\n')) {
          final t = raw.trim();
          if (t.isEmpty ||
              t.startsWith('#') ||
              t.startsWith('!!-')) {
            continue;
          }
          dynamics.add(t.replaceFirst(RegExp(r'^-\s+'), '· '));
        }
      }
    }
    lines.add(const DocxLine('仓储动态'));
    if (dynamics.isEmpty) {
      lines.add(const DocxLine('· 今日没有仓储变动'));
    } else {
      for (final d in dynamics) {
        lines.add(DocxLine(d));
      }
    }
    lines.add(const DocxLine(''));

    // 账目快照
    lines.add(const DocxLine('账目快照'));
    for (final snapshot in await readSnapshots()) {
      lines.add(DocxLine('· ${snapshot.domain.label}：在库 ${snapshot.stock}｜在借 ${snapshot.lent}'
          '｜废弃未恢复 ${snapshot.discardedPending}｜总拥有 ${snapshot.totalOwned}'
          '｜${snapshot.isBalanced ? '账平' : '账不平'}'));
    }

    return DocxWriter.buildLines(
      title: '家庭仓储日报 · $key',
      lines: lines,
    );
  }
}
