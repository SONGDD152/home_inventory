import '../data/domain.dart';

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
}

/// V4.0：**统一的提醒源接口**。
///
/// 元宝第三轮约束：概览只认这一个接口，**不另开 OverviewPanel**。
/// 架构上必须统一——将来知识库 / 餐饮 / 衣橱 / 工作域任务都按同一接口注册进来，
/// **概览代码永不改动**。
abstract class ReminderSource {
  /// 源标识（注册与去重用）。
  String get id;

  /// 展示名（概览分组标题）。
  String get displayName;

  /// 取待办条目列表。
  Future<List<OverviewEntry>> loadEntries();
}
