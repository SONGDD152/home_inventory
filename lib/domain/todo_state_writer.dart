import '../data/todo_state.dart';

/// V4.1：**待办条目状态写入口**。
///
/// 与 [OverviewReader] 严格分离——概览页持有两个接口：
/// - `OverviewReader`：**只读账目**（物品 / 在库 / 在借 / 守恒），**无任何写方法**；
/// - `TodoStateWriter`：**只写待办条目状态**（`todo_states` 表），不触碰任何账目字段。
///
/// **类型层面的保证**（不是靠自觉，是靠签名）：
/// 方法入参只有 `sourceType`（字符串）+ `sourceId`（整数），
/// **拿不到任何仓储句柄、拿不到 items / loans / locations 任何一个**。
/// 所以「概览改不了账」这条地基在 V4.1 之后依然在**编译期**成立——
/// 概览就算想改账，也没有那条路。
///
/// 之所以单独拆接口（不塞进 `InventoryRepository`）：Dart 的 `implements`
/// **不继承默认实现**，往 `InventoryRepository` 加方法会逼所有旧测试的
/// 假仓储改代码，直接破「461 条旧测试一条不能删」的红线。
abstract interface class TodoStateWriter {
  /// 读单个催办条目的状态（null = 从未处理过）。
  Future<TodoState?> readState(String sourceType, int sourceId);

  /// 读全部催办条目状态（概览页按 sourceType + sourceId 与条目配对）。
  Future<List<TodoState>> loadStates();

  /// 标记已处理 / 撤销已处理（划线灰化的开关）。
  ///
  /// 撤销时清掉 `doneAt`，状态回到 pending；延期次数与备注**不清零**
  /// （那是历史，不是完成态）。
  Future<void> markDone(String sourceType, int sourceId, {bool done = true});

  /// 延期：延期次数 **+1**（按「次」累计，跨天不重置），
  /// 写入延期原因，并把下一次提示时间往后推。
  ///
  /// [days] 是往后推的天数（默认 1 天）。手动延期一天点 3 次
  /// 就是 3 次延期——这正是元宝 B4「按次累计，非按天」的要求。
  Future<void> defer(String sourceType, int sourceId,
      {String? reason, int days = 1});

  /// 写处理备注 / 延期原因（导出时一并带出）。
  Future<void> setNote(String sourceType, int sourceId, String note);

  /// 自动延期同步：把「已过期且仍未处理」的条目推进一天，延期次数 +1。
  ///
  /// **每天最多自动 +1 次**——推进到 `max(原到期 + 1 天, 明天)`。
  /// 否则一条过期 5 天的提醒会在一次同步里涨 5 次，
  /// 用户看到的「已延期 N 次」直接失真。
  ///
  /// **幂等**：同一天重复调用不会重复加次（`next_due_at` 已推到明天，
  /// 不再满足「已过期」判定）。
  ///
  /// 返回本次实际推进的条目数。
  Future<int> syncOverdue(DateTime now);
}
