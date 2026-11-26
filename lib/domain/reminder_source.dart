import '../data/domain.dart';
import '../data/reminder.dart';
import '../data/todo_state.dart';

/// V4.0：概览里的一条提醒条目。
///
/// 概览对所有提醒源只认一件事：「给我待办条目列表」——
/// 所以条目结构是**统一**的，与来源（借出到期 / 日程提醒 / 将来知识库…）无关。
class OverviewEntry {
  const OverviewEntry({
    required this.id,
    required this.title,
    this.subtitle,
    this.done = false,
    this.dueAt,
    this.domain,
    // ── V4.1 新增 ──
    this.sourceType,
    this.sourceId,
    this.startedAt,
    this.expectedDays,
    this.dayDelta,
    this.deferCount = 0,
    this.handleNote,
    // ── V4.1 批次 2 新增 ──
    this.priority = ReminderPriority.normal,
    // ── V4.1 批次 3 新增 ──
    this.leadDaysOverride,
    this.repeatRule,
  });

  /// 条目唯一 id（同一来源内唯一即可）。
  final String id;

  /// 主标题。
  final String title;

  /// 副标题（补充信息，如借阅人、到期日）。
  final String? subtitle;

  /// 是否已完成。
  final bool done;

  /// 到期时间（毫秒，可空）。
  final int? dueAt;

  /// 条目所属域（null = 不分域）。
  final InventoryDomain? domain;

  // ── V4.1 新增 ──

  /// 催办源类型（见 [TodoSourceType]）——与 `todo_states` 配对的依据。
  final String? sourceType;

  /// 催办源条目主键（`reminders.id` / `loans.id`）——与 `todo_states` 配对的依据。
  final int? sourceId;

  /// 起始时间（借出日期；日程类为创建时间）。
  final int? startedAt;

  /// 预期天数（借出到期 = 到期日 − 借出日）。
  final int? expectedDays;

  /// 剩余天数（正数 = 还剩 N 天；负数 = 已逾期 N 天）。
  final int? dayDelta;

  /// 延期次数（按「次」累计，跨天不重置）。
  final int deferCount;

  /// 处理备注 / 延期原因。
  final String? handleNote;

  // ── V4.1 批次 2 新增 ──

  /// 优先级（0 低 / 1 中 / 2 高）——元宝裁定①。
  final int priority;

  /// 提前进催办区的天数（裁定②）——由优先级推导：
  /// 高 = 提前 3 天，中 = 提前 1 天，低 = 不提前。
  ///
  /// ## V4.1 批次 3：为什么多一个「显式覆盖」
  ///
  /// 元宝裁定①与裁定②在**系统类**上会打架：
  /// - 裁定①：系统类（借出到期）优先级 = **高**；
  /// - 裁定②：提前量由 priority 推导，**高 = 提前 3 天**。
  ///
  /// 但 PM 最终裁定明确：「系统类提前量取 **2 天**，不取 buddy 原定的 3 天」。
  ///
  /// 如果为了满足「系统类提前 2 天」去改 `leadDaysOf(高)` = 2，
  /// 那**日程类的高优先级提醒也会从 3 天变成 2 天**——
  /// 裁定②批的是「高 3 / 中 1 / 低 0」，一并改掉就是越权改裁定。
  ///
  /// 所以这里加一个**显式覆盖字段**：默认走 priority 推导（裁定②不变），
  /// 只有系统类那条由源自己指定 2 天（裁定①的 PM 最终裁定）。
  /// **优先级与提前量解耦**——这也是为什么不能靠改 priority 推导表来实现。
  final int? leadDaysOverride;

  /// 重复规则（`daily` / `weekly` / `monthly` / `yearly` / null = 不重复）。
  ///
  /// V4.1 批次 3：日程签的条目要显示「每天 / 每周…」标记，
  /// 所以源要把它透出来（`reminders.repeat_rule` 列本就在，
  /// 只是之前没有任何 UI 用它）。
  final String? repeatRule;

  /// 实际生效的提前进区天数。
  ///
  /// 有显式覆盖就用覆盖（系统类 = 2 天），
  /// 没有就按优先级推导（裁定②：高 3 / 中 1 / 低 0）。
  int get leadDays =>
      leadDaysOverride ?? ReminderPriority.leadDaysOf(priority);

  /// 与 `todo_states` 配对的业务键（`'{sourceType}_{sourceId}'`）。
  ///
  /// null 表示该条目没有对应状态行（还没被处理过）。
  String? get stateKey => (sourceType != null && sourceId != null)
      ? TodoState.entryKeyOf(sourceType!, sourceId!)
      : null;
}

/// V4.0：**统一的提醒源接口**。
///
/// 元宝第三轮约束：概览只认这一个接口，**不另开 OverviewPanel**。
/// 架构上必须统一——将来知识库 / 餐饮 / 衣橱 / 工作域任务都按同一接口注册进来，
/// **概览代码永不改动**。
abstract class ReminderSource {
  /// 源标识（注册与去重用）。
  ///
  /// V4.1：**必须带域**（`loan_due_life` / `loan_due_work`）——
  /// 概览拿它当 Map 的 key，不带域则生活区与工作区的同名源互相覆盖
  /// （V4.0 的 E1 bug：生活区的借出到期条目被工作区的空集吞掉）。
  String get id;

  /// 展示名（概览分组标题）。
  ///
  /// V4.1：**必须带域**（`生活区·仓储借出到期`），一眼分清来源。
  String get displayName;

  /// 取待办条目列表。
  Future<List<OverviewEntry>> loadEntries();
}
