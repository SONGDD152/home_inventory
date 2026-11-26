import '../data/todo_state.dart';

/// V4.1 批次 2：**待办状态只读口**。
///
/// 与 [TodoStateWriter] 分开——日报服务（纯导出）只需要读，
/// 不该拿到写能力。给导出流程开一条「顺手改状态」的路不是不行，
/// 是没必要，且会让「导出是只读动作」这条性质失守。
///
/// [TodoStateWriter] 继承本接口，所以持有写口的人也能读；
/// 反过来只持读口的人**编译期就写不了**。
abstract interface class TodoStateReader {
  /// 读全部催办条目状态。
  Future<List<TodoState>> loadStates();
}

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
abstract interface class TodoStateWriter implements TodoStateReader {
  /// 读单个催办条目的状态（null = 从未处理过）。
  Future<TodoState?> readState(String sourceType, int sourceId);

  /// 读全部催办条目状态（概览页按 sourceType + sourceId 与条目配对）。
  @override
  Future<List<TodoState>> loadStates();

  /// 标记已处理 / 撤销已处理（划线灰化的开关）。
  ///
  /// 撤销时清掉 `doneAt`，状态回到 pending；延期次数与备注**不清零**
  /// （那是历史，不是完成态）。
  ///
  /// ## V4.1 批次 4：完成**日程类**条目会联动新建下一实例（元宝裁定② · 甲方案）
  ///
  /// 重复规则的语义选**甲**：完成后自动新建下一实例、**保留历史**
  /// （旧实例留在 `reminders` 表里，日报看得到「今天做完了什么」）。
  ///
  /// **展开逻辑挂在数据层**（`InventoryDatabase` 内部），不挂 UI 层——
  /// 因为概览的「日报签」与「日程签」两处勾选**都走本方法**，
  /// 挂数据层两签天然同源；挂 UI 层要改两处、必然漂移。
  ///
  /// 展开只写 `reminders` 表（**日程系统自己的表**），
  /// 仓储账（items / loans / locations）**一个字不动**——
  /// 「概览改不了账」这条地基不受影响。
  ///
  /// 撤销完成**不回收**已建的下一实例（排期不回滚）。
  Future<void> markDone(String sourceType, int sourceId, {bool done = true});

  /// 延期：延期次数 **+1**（按「次」累计，跨天不重置），
  /// 写入延期原因，并把下一次提示时间往后推。
  ///
  /// ## 两种延期方式（元宝裁定③）
  ///
  /// - **[days] 相对推进**（旧口径，默认 1 天）：
  ///   从现有 `next_due_at`（没有就从源条目原到期日）往后推 N 天。
  /// - **[dueOn] 绝对日期**（裁定③要的「延到明天 / 具体日期」）：
  ///   写 `next_due_at = dueOn`。
  ///
  /// ## 只往后推，不许回拉（V4.1 批次 3 · 元宝裁定④修订）
  ///
  /// 选了**早于**当前下一次提示日（`next_due_at`；没有就回落到源条目
  /// 原到期日，再没有就以「现在」为基准）的日子 → **这次延期被忽略**，
  /// 状态行一个字不动（延期次数也不加），并抛 [ArgumentError]。
  ///
  /// **校验在数据层**：UI 只是入口，数据层才是唯一能保证这条规矩
  /// 成立的地方——只在 UI 拦的话，绕过 UI 的调用照样能把提示时间往回拉。
  ///
  /// 两个口径都只动 `todo_states`（`next_due_at` / `defer_count` / `handle_note`），
  /// **不碰源表**（`reminders.due_at` 一列不动）——概览的写边界依然成立。
  ///
  /// [days] 是往后推的天数（默认 1 天）。手动延期一天点 3 次
  /// 就是 3 次延期——这正是元宝 B4「按次累计，非按天」的要求。
  Future<void> defer(String sourceType, int sourceId,
      {String? reason, int days = 1, DateTime? dueOn});

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
