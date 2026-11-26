/// V4.0 日程/日报的数据模型。
///
/// 与仓储模型（[item.dart]）分开放：提醒属于**生活域的日程系统**，
/// 不参与仓储的「在库 + 在借 + 已废弃 = 总拥有」守恒口径，
/// 也不进 items / loans 那套账。
library;

/// 提醒条目（一条待办）。
///
/// 完成状态用 [status] 两态表示（pending / done），**不硬删**——
/// 已完成的也要留着，否则日报看不出「今天做完了什么」。
/// 删除走软删（is_deleted / deleted_at），与仓储侧惯例一致。
class Reminder {
  const Reminder({
    this.id,
    required this.title,
    this.detail,
    this.dueAt,
    this.status = 'pending',
    this.doneAt,
    this.repeatRule,
    this.priority = ReminderPriority.normal,
    this.isDeleted = false,
    this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final int? id;

  /// 标题（必填）。
  final String title;

  /// 备注（可空）。
  final String? detail;

  /// 到期时间（UTC 毫秒，可空 = 无期限提醒）。
  final int? dueAt;

  /// 状态：`pending` 待办 / `done` 已完成。
  final String status;

  /// 完成时间（UTC 毫秒，未完成为 null）。
  final int? doneAt;

  /// 重复规则（`daily` / `weekly` / `monthly` / `yearly` / null = 不重复）。
  final String? repeatRule;

  /// 优先级（0 低 / 1 中 / 2 高，默认 1 中）——元宝裁定①。
  ///
  /// 同时决定「提前进催办区」的提前量（见 [ReminderPriority.leadDays]）：
  /// 高优先级提前 3 天进区，中优先级提前 1 天，低优先级到期当天才进。
  final int priority;

  /// 是否已软删（进回收站）。
  final bool isDeleted;

  /// 软删时间戳（UTC 毫秒）。
  final int? deletedAt;

  final int createdAt;
  final int updatedAt;

  /// 是否待办。
  bool get isPending => status == 'pending';

  /// 是否已完成。
  bool get isDone => status == 'done';

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'title': title,
        if (detail != null) 'detail': detail,
        if (dueAt != null) 'due_at': dueAt,
        'status': status,
        if (doneAt != null) 'done_at': doneAt,
        if (repeatRule != null) 'repeat_rule': repeatRule,
        'priority': priority,
        'is_deleted': isDeleted ? 1 : 0,
        if (deletedAt != null) 'deleted_at': deletedAt,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Reminder.fromMap(Map<String, Object?> map) => Reminder(
        id: map['id'] as int?,
        title: (map['title'] as String?) ?? '',
        detail: map['detail'] as String?,
        dueAt: (map['due_at'] as num?)?.toInt(),
        status: (map['status'] as String?) ?? 'pending',
        doneAt: (map['done_at'] as num?)?.toInt(),
        repeatRule: map['repeat_rule'] as String?,
        priority: (map['priority'] as num?)?.toInt() ?? ReminderPriority.normal,
        isDeleted: (map['is_deleted'] as int?) == 1,
        deletedAt: (map['deleted_at'] as num?)?.toInt(),
        createdAt: (map['created_at'] as num?)?.toInt() ?? 0,
        updatedAt: (map['updated_at'] as num?)?.toInt() ?? 0,
      );
}

/// V4.1 批次 2：提醒优先级（元宝裁定①）。
///
/// 取值：**0 低 / 1 中 / 2 高**，默认 **1 中**。
/// 旧提醒升级到 v13 后默认拿到 1（不该因为升级就被判成低优先级）。
///
/// 优先级同时决定「**提前进催办区**」的提前量（元宝裁定②）：
/// 高优先级提前 3 天进区，中优先级提前 1 天，低优先级到期当天才进。
/// 这样「不卡到期时刻」——重要的事提前几天就露面，
/// 不用等到到期那一刻才想起。
class ReminderPriority {
  const ReminderPriority._();

  /// 低优先级。
  static const int low = 0;

  /// 中优先级（默认）。
  static const int normal = 1;

  /// 高优先级。
  static const int high = 2;

  static const List<int> all = <int>[low, normal, high];

  /// 展示名。
  static String labelOf(int priority) {
    switch (priority) {
      case high:
        return '高';
      case low:
        return '低';
      default:
        return '中';
    }
  }

  /// 提前进催办区的天数（裁定②）。
  ///
  /// 高 = 提前 3 天，中 = 提前 1 天，低 = 不提前（到期当天才进）。
  static int leadDaysOf(int priority) {
    switch (priority) {
      case high:
        return 3;
      case low:
        return 0;
      default:
        return 1;
    }
  }

  /// 取合法优先级（越界归为中）。
  static int normalize(int? value) {
    if (value == null) return normal;
    return all.contains(value) ? value : normal;
  }
}

/// 日报存档（一日一条）。
class DailyReport {
  const DailyReport({
    this.id,
    required this.reportDate,
    required this.contentMd,
    required this.generatedAt,
    this.sourceSnapshot,
  });

  final int? id;

  /// 报告日期（本地日期，`yyyy-MM-dd`）。
  final String reportDate;

  /// 正文（Markdown）。
  final String contentMd;

  /// 生成时间（UTC 毫秒）。
  final int generatedAt;

  /// 生成时的数据快照（JSON 字符串，可空）——用于回看"当时那本账长什么样"。
  final String? sourceSnapshot;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'report_date': reportDate,
        'content_md': contentMd,
        'generated_at': generatedAt,
        if (sourceSnapshot != null) 'source_snapshot': sourceSnapshot,
      };

  factory DailyReport.fromMap(Map<String, Object?> map) => DailyReport(
        id: map['id'] as int?,
        reportDate: (map['report_date'] as String?) ?? '',
        contentMd: (map['content_md'] as String?) ?? '',
        generatedAt: (map['generated_at'] as num?)?.toInt() ?? 0,
        sourceSnapshot: map['source_snapshot'] as String?,
      );
}
