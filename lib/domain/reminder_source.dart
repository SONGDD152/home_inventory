import '../data/domain.dart';
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
