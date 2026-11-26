import '../data/inventory_repository.dart';
import '../data/reminder_repository.dart';
import 'reminder_source.dart';

/// V4.0：借出到期提醒源。
///
/// 数据现成（loans.due_at），本轮先注册这一个源；
/// 日程系统按同一接口注册（[ScheduleReminderSource]）——
/// 两个源一起用，能验证「概览只认 ReminderSource 一个接口」够不够用。
class LoanDueReminderSource implements ReminderSource {
  const LoanDueReminderSource(this.repository);

  final InventoryRepository repository;

  @override
  String get id => 'loan_due';

  @override
  String get displayName => '借出到期';

  @override
  Future<List<OverviewEntry>> loadEntries() async {
    final loans = await repository.getAllLoans();
    final now = DateTime.now().millisecondsSinceEpoch;
    final entries = <OverviewEntry>[];
    for (final loan in loans) {
      if (loan.isReturned) continue; // 已还清不再提醒。
      final overdue = loan.isOverdue(now);
      entries.add(OverviewEntry(
        id: 'loan_${loan.id}',
        title: '${loan.itemName}（借给${loan.borrowerName}）',
        subtitle: overdue ? '已逾期' : '待归还',
        dueAt: loan.dueAt,
      ));
    }
    return entries;
  }
}

/// V4.0：日程提醒源（reminders 表）。
class ScheduleReminderSource implements ReminderSource {
  const ScheduleReminderSource(this.repository);

  final ReminderRepository repository;

  @override
  String get id => 'schedule_reminders';

  @override
  String get displayName => '日程提醒';

  @override
  Future<List<OverviewEntry>> loadEntries() async {
    final items = await repository.getReminders();
    return items.map((item) => OverviewEntry(
          id: 'reminder_${item.id}',
          title: item.title,
          subtitle: item.detail,
          done: item.isDone,
          dueAt: item.dueAt,
        )).toList();
  }
}
