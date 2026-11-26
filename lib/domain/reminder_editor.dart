/// V4.1 批次 3：**提醒条目编辑口**（只写 `reminders` 表，不碰别的）。
///
/// ## 为什么单独拆一个接口
///
/// 批次 3 要让**概览页的日程签**能创建 / 编辑 / 删除提醒。
/// 最省事的做法是把 `ReminderRepository` 塞给概览页——但那是**过宽**的：
///
/// - `ReminderRepository` 里混着**日报读写**（`getDailyReport` /
///   `saveDailyReport` / `getDailyReports`）。概览页不需要写日报，
///   却会平白拿到写日报的能力——这正是「写边界要窄」要防的事。
/// - `ReminderRepository` 是**既有接口**（V4.0 定），
///   改它的签名会波及所有实现者 → 有破「461 条旧测试一条不能删」红线的风险。
///
/// 所以这里拆一个**只管提醒条目本身**的窄接口。
///
/// ## 方法名为什么与 `ReminderRepository` 错开
///
/// `InventoryDatabase` 同时实现两个接口。如果两个接口有**同名同参**的方法，
/// Dart 要求有**唯一实现**——两个接口方法名一样但语义略有差异时
/// （比如 `updateReminder` 要不要带 `repeatRule`）就会打架，
/// 或者逼得实现里写一个语义妥协的合并方法。
///
/// 错开名字（`createReminder` / `editReminder` / `removeReminder`）
/// 就没有这个问题：两个接口的方法各写各的，实现里转调即可。
///
/// ## 写边界
///
/// 这个接口能写的**只有 `reminders` 表**（日程/提醒系统），
/// 它**不涉及** `items` / `loans` / `locations` ——仓储账一个字都碰不到。
/// 所以「概览改不了账」这条地基仍然成立：**概览页拿到的写口**
/// 只有 `TodoStateWriter`（只写 `todo_states`）与本接口（只写 `reminders`），
/// 两个都不含仓储句柄。
abstract interface class ReminderEditor {
  /// 新建一条提醒，返回新条目 id。
  ///
  /// [priority]：0 低 / 1 中 / 2 高，默认 1 中（元宝裁定①）。
  /// [repeatRule]：重复规则（`daily` / `weekly` / `monthly` / `yearly`），
  /// null = 不重复。
  Future<int> createReminder(String title,
      {String? detail,
      DateTime? dueAt,
      String? repeatRule,
      int priority});

  /// 编辑提醒（只改传入的字段；null = 不改）。
  ///
  /// [repeatRule]：重复规则。传 null 表示**不改**重复规则
  /// （不是「清空」——要清空走 [clearRepeatRule]）。
  /// [clearRepeatRule]：显式清空重复规则。
  Future<void> editReminder(int id,
      {String? title,
      String? detail,
      DateTime? dueAt,
      String? repeatRule,
      bool clearRepeatRule = false,
      int? priority});

  /// 软删提醒（进回收站，不硬删）。
  Future<void> removeReminder(int id);
}
