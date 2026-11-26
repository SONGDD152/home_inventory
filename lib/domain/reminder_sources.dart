import '../data/domain.dart';
import '../data/inventory_repository.dart';
import '../data/reminder.dart';
import '../data/reminder_repository.dart';
import '../data/todo_state.dart';
import 'reminder_source.dart';

/// 自然日折算：把毫秒时间戳折算到当天 00:00。
int _dateOnly(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

/// 剩余/逾期天数（正数 = 还剩 N 天，负数 = 已逾期 N 天）。
///
/// 按**自然日**折算而不是按毫秒差——「还剩 2 天」说的是日历天，
/// 不是「还剩 47 小时」。
int _dayDelta(int dueAt, int nowMs) =>
    (_dateOnly(dueAt) - _dateOnly(nowMs)) ~/ const Duration(days: 1).inMilliseconds;

/// `YYYY-MM-DD`。
String _fmtDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '${d.year}-$m-$day';
}

/// V4.0：借出到期提醒源。
///
/// 数据现成（loans.due_at），本轮先注册这一个源；
/// 日程系统按同一接口注册（[ScheduleReminderSource]）——
/// 两个源一起用，能验证「概览只认 ReminderSource 一个接口」够不够用。
///
/// V4.1：**域必填**——id 与 displayName 都带域。
/// 这是修 E1（生活区借出到期条目被工作区空集覆盖吞掉）的**两道之一**：
/// ① 概览 Map 的 key 改用 `source.id`；② 源的 id/displayName 本身唯一。
/// 域必填而不给默认值，是为了让编译器强制每个调用点显式声明域——
/// 默认 life 会让工作区的源悄悄用 life 的 id，又是同一个坑。
class LoanDueReminderSource implements ReminderSource {
  const LoanDueReminderSource(this.repository, this.domain);

  final InventoryRepository repository;
  final InventoryDomain domain;

  @override
  String get id => 'loan_due_${domain.id}';

  @override
  String get displayName => '${domain.label}·仓储借出到期';

  @override
  Future<List<OverviewEntry>> loadEntries() async {
    final loans = await repository.getAllLoans();
    final now = DateTime.now().millisecondsSinceEpoch;
    final entries = <OverviewEntry>[];
    for (final loan in loans) {
      if (loan.isReturned) continue; // 已还清不再提醒。
      final delta = _dayDelta(loan.dueAt, now);
      final expected = _dayDelta(loan.dueAt, loan.borrowedAt);
      // 副标题：借出日期 + 预期天数 + 剩余/逾期天数（元宝 E5 要求的全部字段）。
      final dueText = delta == 0
          ? '今天到期'
          : (delta > 0 ? '还剩 $delta 天' : '已逾期 ${-delta} 天');
      entries.add(OverviewEntry(
        // 条目 id 也带域：widget key 必须全库唯一，
        // 否则生活区与工作区的 loan_1 会撞 key。
        id: 'loan_${domain.id}_${loan.id}',
        title: '${loan.itemName}（借给${loan.borrowerName}）',
        subtitle: '借出 ${_fmtDate(loan.borrowedAt)} · 预期 $expected 天 · $dueText',
        dueAt: loan.dueAt,
        domain: domain,
        sourceType: TodoSourceType.loanDue,
        sourceId: loan.id,
        startedAt: loan.borrowedAt,
        expectedDays: expected,
        dayDelta: delta,
        // V4.1 批次 2（元宝裁定①）：系统类优先级。
        //
        // 系统类没有「创建时设置优先级」的入口（借出是仓储动作带出来的，
        // 不是用户在提醒库里新建的），所以由源自己定。
        // 这里定**高**（提前 3 天进催办区）：借出到期是「忘了会出事」的事，
        // 与日程类默认「中」不同——**此口径为 buddy 定，待元宝追认**。
        priority: ReminderPriority.high,
      ));
    }
    return entries;
  }
}

/// V4.0：日程提醒源（reminders 表）。
///
/// V4.1：**域必填**，id 与 displayName 带域（理由同 [LoanDueReminderSource]）。
class ScheduleReminderSource implements ReminderSource {
  const ScheduleReminderSource(this.repository, this.domain);

  final ReminderRepository repository;
  final InventoryDomain domain;

  @override
  String get id => 'schedule_reminders_${domain.id}';

  @override
  String get displayName => '${domain.label}·日程提醒';

  @override
  Future<List<OverviewEntry>> loadEntries() async {
    final items = await repository.getReminders();
    final now = DateTime.now().millisecondsSinceEpoch;
    return items.map((item) {
      final delta = item.dueAt == null ? null : _dayDelta(item.dueAt!, now);
      return OverviewEntry(
        id: 'reminder_${domain.id}_${item.id}',
        title: item.title,
        subtitle: item.detail ??
            (delta == null
                ? null
                : (delta == 0
                    ? '今天到期'
                    : (delta > 0 ? '还剩 $delta 天' : '已逾期 ${-delta} 天'))),
        done: item.isDone,
        dueAt: item.dueAt,
        domain: domain,
        sourceType: TodoSourceType.scheduleReminder,
        sourceId: item.id,
        startedAt: item.createdAt,
        dayDelta: delta,
        // V4.1 批次 2（元宝裁定①）：优先级 —— 决定催办区排序与提前量。
        priority: item.priority,
      );
    }).toList();
  }
}
