import 'reminder.dart';

/// V4.0：提醒 / 日报能力接口。
///
/// **为什么不加进 [InventoryRepository]**：仓储接口是既有测试里假仓储
/// `implements` 的契约——Dart 的 `implements` **不继承默认实现**，
/// 往仓储接口加方法等于逼所有假仓储改代码（旧测试红线：一条不能删）。
/// 所以日程能力单独成接口：实现者（[InventoryDatabase]）同时实现两个接口，
/// 界面按能力探测（`repository is ReminderRepository`），
/// 拿不到能力时功能优雅降级，而不是编译期炸掉。
abstract class ReminderRepository {
  /// 提醒条目（未软删，按到期时间、再按 id 排序）。
  /// [includeDone] 为 false 时只返回待办。
  Future<List<Reminder>> getReminders({bool includeDone = true});

  /// 新增一条提醒，返回新条目 id。
  ///
  /// [priority]：0 低 / 1 中 / 2 高，默认 1 中（元宝裁定①）。
  Future<int> addReminder(String title,
      {String? detail,
      DateTime? dueAt,
      String? repeatRule,
      int priority = ReminderPriority.normal});

  /// 编辑提醒（只改传入的字段）。
  ///
  /// [priority]：0 低 / 1 中 / 2 高（元宝裁定①，日程签编辑时可设）。
  Future<void> updateReminder(int id,
      {String? title, String? detail, DateTime? dueAt, int? priority});

  /// 标记完成 / 取消完成（两态，不硬删——已完成也要留着，日报要看）。
  Future<void> setReminderDone(int id, {bool done = true});

  /// 软删提醒（进回收站）。
  Future<void> deleteReminder(int id);

  /// 取某天的日报（没有则返回 null）。
  Future<DailyReport?> getDailyReport(String reportDate);

  /// 日报列表（日期倒序）。
  Future<List<DailyReport>> getDailyReports({int limit = 30});

  /// 写入 / 覆盖某天的日报（同日覆盖，不重复）。
  Future<void> saveDailyReport(String reportDate, String contentMd,
      {String? sourceSnapshot});
}
