/// V4.1：催办条目状态。
///
/// **催办条目** = 日程类（`reminders` 表）+ 系统类（借出到期，`loans` 表派生）。
/// 两类**共用同一套状态机**（完成 / 延期 / 备注），状态一律落在 `todo_states` 表，
/// 各自的业务表**只读不写状态**——这就是「状态与数据源解耦」。
///
/// 设计要点（元宝 2026-11-26 裁定）：
/// - `sourceType` + `sourceId` 指向原表主键（`reminders.id` / `loans.id`），
///   跨表关联靠 `sourceType` 区分；
/// - 后续若加新催办源（餐饮库存预警等），**只加枚举值，不加表不加列**。
class TodoState {
  const TodoState({
    this.id,
    required this.sourceType,
    required this.sourceId,
    this.status = TodoStatus.pending,
    this.doneAt,
    this.deferCount = 0,
    this.handleNote,
    this.nextDueAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final int? id;

  /// 催办源类型（见 [TodoSourceType]）。
  final String sourceType;

  /// 原表主键（`reminders.id` 或 `loans.id`）。
  final int sourceId;

  /// 待办状态（见 [TodoStatus]）。
  final String status;

  /// 处理时间（UTC 毫秒）。
  final int? doneAt;

  /// 延期次数：**按「次」累计，跨天不重置**（元宝 B4）。
  final int deferCount;

  /// 处理备注 / 延期原因（与 `reminders.detail` 语义分离）。
  final String? handleNote;

  /// 延期后的**下一次提示时间**（UTC 毫秒）。
  ///
  /// 为什么要这一列：元宝 B4 要求「到期当天未处理 → 自动延期 → 到期当天再次提示」。
  /// 「再次提示」的时间点必须有地方存，否则只能去推 `reminders.due_at`——
  /// 那等于让概览越界写日程表，破了 PM 拍板的「概览只写待办状态」边界；
  /// 或用 `defer_count` 反推天数，那「按次累计」就退化成「按天累计」，
  /// 与 B4「按次累计，非按天」直接冲突。所以这是延期机制的必要存储位，
  /// **不是**「新催办源」的表结构扩展。
  final int? nextDueAt;

  final int createdAt;
  final int updatedAt;

  bool get isDone => status == TodoStatus.done;

  bool get isDeferred => status == TodoStatus.deferred;

  bool get isPending => status == TodoStatus.pending;

  /// V4.1.4：用户主动标记的「进行中」中间态。
  bool get isInProgress => status == TodoStatus.inProgress;

  /// 派生的条目键：与 UI 侧 [OverviewEntry.id] 对齐。
  String get entryKey => TodoState.entryKeyOf(sourceType, sourceId);

  static String entryKeyOf(String sourceType, int sourceId) =>
      '${sourceType}_$sourceId';

  /// 从条目键反解出 (sourceType, sourceId)。
  ///
  /// 键的构造是 `'{sourceType}_{sourceId}'`，而 `sourceType` 本身不含下划线
  /// （`schedule_reminder` / `loan_due`），所以按下划线**从右往左**切一次即可，
  /// 不会因为类型名里有下划线而切错。
  static (String, int)? parseEntryKey(String entryKey) {
    final idx = entryKey.lastIndexOf('_');
    if (idx <= 0 || idx == entryKey.length - 1) return null;
    final sourceId = int.tryParse(entryKey.substring(idx + 1));
    if (sourceId == null) return null;
    return (entryKey.substring(0, idx), sourceId);
  }

  factory TodoState.fromMap(Map<String, Object?> map) {
    return TodoState(
      id: map[InventoryDatabaseColumn.id] as int?,
      sourceType: map[InventoryDatabaseColumn.sourceType] as String? ?? '',
      sourceId: (map[InventoryDatabaseColumn.sourceId] as num?)?.toInt() ?? 0,
      status: map[InventoryDatabaseColumn.status] as String? ??
          TodoStatus.pending,
      doneAt: (map[InventoryDatabaseColumn.doneAt] as num?)?.toInt(),
      deferCount: (map[InventoryDatabaseColumn.deferCount] as num?)?.toInt() ?? 0,
      handleNote: map[InventoryDatabaseColumn.handleNote] as String?,
      nextDueAt: (map[InventoryDatabaseColumn.nextDueAt] as num?)?.toInt(),
      createdAt: (map[InventoryDatabaseColumn.createdAt] as num?)?.toInt() ?? 0,
      updatedAt: (map[InventoryDatabaseColumn.updatedAt] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      InventoryDatabaseColumn.id: id,
      InventoryDatabaseColumn.sourceType: sourceType,
      InventoryDatabaseColumn.sourceId: sourceId,
      InventoryDatabaseColumn.status: status,
      InventoryDatabaseColumn.doneAt: doneAt,
      InventoryDatabaseColumn.deferCount: deferCount,
      InventoryDatabaseColumn.handleNote: handleNote,
      InventoryDatabaseColumn.nextDueAt: nextDueAt,
      InventoryDatabaseColumn.createdAt: createdAt,
      InventoryDatabaseColumn.updatedAt: updatedAt,
    };
  }

  TodoState copyWith({
    String? status,
    int? doneAt,
    int? deferCount,
    String? handleNote,
    int? nextDueAt,
    int? updatedAt,
  }) {
    return TodoState(
      id: id,
      sourceType: sourceType,
      sourceId: sourceId,
      status: status ?? this.status,
      doneAt: doneAt ?? this.doneAt,
      deferCount: deferCount ?? this.deferCount,
      handleNote: handleNote ?? this.handleNote,
      nextDueAt: nextDueAt ?? this.nextDueAt,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// V4.1：催办源类型枚举（PM 2026-11-26 确认）。
///
/// 后续若加新催办源（如餐饮库存预警），**只加枚举值，不加表不加列**。
class TodoSourceType {
  const TodoSourceType._();

  /// 日程类（`reminders` 表）。
  static const String scheduleReminder = 'schedule_reminder';

  /// 系统类——借出到期（`loans` 表派生）。
  static const String loanDue = 'loan_due';

  static const List<String> all = <String>[scheduleReminder, loanDue];

  static bool isValid(String value) => all.contains(value);
}

/// V4.1：待办状态取值（对应元宝 B2 的三态）。
class TodoStatus {
  const TodoStatus._();

  /// 未处理（空框）。
  static const String pending = 'pending';

  /// 进行中（半框）——V4.1.4 新增，用户主动标记。
  ///
  /// 与 [deferred] 语义不重叠：in_progress 是**用户主动**标记「做了一半」，
  /// deferred 是**系统自动**标记「超期顺延」。两者并存，各走各的路。
  static const String inProgress = 'in_progress';

  /// 已处理 / 完成（满框，划线 + 灰化，可撤销）。
  static const String done = 'done';

  /// 已延期（延期次数 +1）——系统自动标记超期，保留不动。
  static const String deferred = 'deferred';

  /// 三态勾选循环：空框 → 半框 → 满框 → 回空框。
  static const List<String> toggleCycle = <String>[
    pending,
    inProgress,
    done,
  ];

  /// 下一个勾选态（循环）。
  static String next(String status) {
    final i = toggleCycle.indexOf(status);
    if (i < 0) return pending; // 未知态（含 deferred）→ 点一下回到空框。
    return toggleCycle[(i + 1) % toggleCycle.length];
  }
}

/// V4.1：`todo_states` 表的列名常量。
///
/// 单独放在这里，避免 `inventory_database.dart` 里的常量与模型互相 import
/// 形成循环依赖（模型层不认识数据库层）。
class InventoryDatabaseColumn {
  const InventoryDatabaseColumn._();

  static const String id = 'id';
  static const String sourceType = 'source_type';
  static const String sourceId = 'source_id';
  static const String status = 'status';
  static const String doneAt = 'done_at';
  static const String deferCount = 'defer_count';
  static const String handleNote = 'handle_note';
  static const String nextDueAt = 'next_due_at';
  static const String createdAt = 'created_at';
  static const String updatedAt = 'updated_at';
}
