import '../data/domain.dart';
import '../data/todo_state.dart';
import 'reminder_source.dart';

/// V4.1 批次 2：**催办口径的唯一实现**。
///
/// ## 为什么要有这个模块
///
/// 元宝 B6 要求：「未完成：提示框内未处理的条目」——
/// 也就是说，**日报导出里那份「未完成清单」必须就是界面上那张提示框里
/// 看到的那些条目**，一个字不多一个字不少。
///
/// 如果界面和导出各自实现一套筛选逻辑，迟早会漂移：
/// 界面上按 `nextDueAt` 判、导出按 `dueAt` 判 → 用户勾掉一条，
/// 导出里还红着；或者导出里冒出一条界面上根本没显示的。
///
/// 所以口径**只写一遍**，界面（概览日报签）与导出（日报服务）都从这里取。
///
/// ## 纳入判定（元宝 B4 / B5 / B6）
///
/// 一个条目进入某一天的催办范围，当且仅当满足以下任一条：
///
///  1. **原到期日 ≤ 该日末**——到期当天或已逾期都留着；
///  2. **延期后的下一次提示日 ≤ 该日末**——手动延到今天的条目；
///  3. **处理时间落在该日**——今天勾掉的条目（无论原到期日在哪）。
///
/// ## V4.1 批次 4：第 ⓪ 条（排除历史已完成）
///
/// 元宝裁定②选**甲**（完成后自动新建下一实例、**保留历史**）后，
/// `reminders` 表里会**同时存在**当前实例与历史实例。
/// 历史实例的原到期日在过去 → 上面第 ① 条会把它判成「逾期」→
/// 它会**天天挂在催办区里**。
///
/// 所以加了一条前置排除：**已完成、且处理时间不在这一天的 → 不进该日催办区**。
/// 已处理过的事不该继续占催办位；但「今天做完了什么」仍然看得到
/// （处理时间落在当天 → 进第 ③ 条）。
///
/// 这条改在**唯一实现**里，界面与导出**同源**自动生效。
///
/// 第 1 条是元宝 B4「到期当天未处理 → 自动延期 → **到期当天再次提示**」
/// 的直接落地：自动延期把 `next_due_at` 推到明天，但**原到期日不变**，
/// 所以条目不会因为被延期就从催办区消失——它一直留着，
/// 副标题显示「已延期 N 次」，直到被勾掉。
///
/// 第 3 条保证「今天勾掉的未来日程」也会出现在今天的日报「已完成」里
/// （元宝 B6：「已完成：今日勾选已处理的条目，带处理时间」）。
class TodoAgenda {
  const TodoAgenda._();

  /// 状态配对键（**带域**）：`'{domainId}:{sourceType}_{sourceId}'`。
  ///
  /// ## 为什么要在配对时加域前缀
  ///
  /// `todo_states` 是**每库一张表**（物理分库），所以单库内
  /// `loan_due_1` 是唯一的，存储层的 `entry_id` 不带域没问题。
  ///
  /// 但**概览页与日报导出都是跨域的**：它们把生活库与工作库的状态
  /// 合并进同一张 Map。此时两库的 `loan_due_1` 会撞在一起——
  /// 生活区那条被处理过的状态，会被套到工作区那条没处理过的条目上。
  /// 这就是 E1（源 id 撞车）在**状态层**的翻版。
  ///
  /// 所以：**存储不带域，配对带域**。表结构一个字不用改。
  static String stateKeyOf(InventoryDomain? domain, String? entryKey) =>
      '${domain?.id ?? 'none'}:${entryKey ?? ''}';

  /// 催办区纳入判定。
  ///
  /// [sourceDueAt] = 条目**原到期日**（借出到期日 / 日程到期日，可空）；
  /// [nextDueAt] = 延期后的**下一次提示日**（可空）；
  /// [doneAt] = 处理时间（可空）；
  /// [leadDays] = **提前进区的天数**（元宝裁定②，由优先级推导：
  /// 高 = 提前 3 天，中 = 提前 1 天，低 = 0）；
  /// [date] = 判定基准日（取该日 23:59:59 当日末）。
  ///
  /// **按自然日比，不比时刻**——元宝口径：
  /// 「今天 20:00 到期」在「今天 10:00」不算已过期。
  static bool isInAgenda({
    required int? sourceDueAt,
    required int? nextDueAt,
    required int? doneAt,
    int leadDays = 0,
    required DateTime date,
  }) {
    final endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59)
        .millisecondsSinceEpoch;
    final dayStart =
        DateTime(date.year, date.month, date.day).millisecondsSinceEpoch;
    // ⓪ **已完成、且不是在这一天处理的 → 不进该日催办区**。
    //
    // ## 为什么要有这一条（V4.1 批次 4 · 元宝裁定②甲方案的配套）
    //
    // 甲方案完成后**保留历史实例**（旧实例留在 `reminders` 表里）。
    // 历史实例的原到期日在**过去** → 下面第 ① 条会把它判成「逾期」→
    // 于是它**天天挂在催办区里**，越积越多。
    //
    // 那是「未完成条目的留置规则」被套到了「已完成的历史」上——
    // 得在这里挡掉：已处理过的事不该继续占催办位。
    //
    // **处理时间落在当天的仍然进**（日报要看「今天做完了什么」，
    // 见下面第 ③ 条）。
    if (doneAt != null && doneAt < dayStart) return false;
    // ① 原到期日 ≤ 该日末（到期当天 / 已逾期）。
    if (sourceDueAt != null && sourceDueAt <= endOfDay) return true;
    // ② 延期后的下一次提示日 ≤ 该日末。
    if (nextDueAt != null && nextDueAt <= endOfDay) return true;
    // ③ 处理时间落在该日（今天勾掉的条目）。
    if (doneAt != null && doneAt >= dayStart && doneAt <= endOfDay) return true;
    // ④ **提前进区**（元宝裁定②）：到期日还在未来，但已进「提前量」窗口
    //    → 进催办区，不卡到期时刻。
    //
    //    提前量按**自然日**算：高优先级提前 3 天、中优先级提前 1 天、
    //    低优先级不提前（到期当天才进）。
    //
    //    边界用**自然日**比（不是时刻）：「今天 + 3 天到期」这条在
    //    「今天」就该进区（提前 3 天），而「今天 + 4 天到期」不该进。
    //    若拿时刻比（今天 23:59 + 3 天 = 第 4 天 23:59），
    //    第 4 天早上 9 点到期的提醒会在第 3 天晚上就冒出来——提前了 4 天。
    if (leadDays > 0 && sourceDueAt != null) {
      final limitDay = DateTime(date.year, date.month, date.day)
          .add(Duration(days: leadDays))
          .millisecondsSinceEpoch;
      if (dateOnly(sourceDueAt) <= limitDay) return true;
    }
    return false;
  }

  /// 自然日折算：把毫秒时间戳折算到当天 00:00。
  static int dateOnly(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
  }

  /// 某条目今天是否到期（用于「今日到期」这类提示）。
  static bool isDueToday(int? effectiveDueAt, DateTime now) {
    if (effectiveDueAt == null) return false;
    return dateOnly(effectiveDueAt) == dateOnly(now.millisecondsSinceEpoch);
  }

  /// 催办条目排序（元宝裁定①）：**优先级降序**。
  ///
  /// ① 优先级降序（高 2 → 中 1 → 低 0）；
  /// ② 同优先级 → **有效到期日升序**（近的在前，没到期日的排最后）；
  /// ③ 再同 → 标题升序（顺序稳定，不随数据库返回顺序抖动）。
  ///
  /// 放在这里而不是界面里，是因为「催办区怎么排」是**口径**，
  /// 与「哪些条目进催办区」是同一类问题——都归 [TodoAgenda] 管，
  /// 界面与导出取同一份口径。
  static void sortByPriority(List<TodoAgendaItem> items) {
    items.sort(_compareByPriority);
  }

  static int _compareByPriority(TodoAgendaItem a, TodoAgendaItem b) {
    final byPriority = b.entry.priority.compareTo(a.entry.priority);
    if (byPriority != 0) return byPriority;
    const far = 1 << 62; // 没有到期日 = 最不急，排最后。
    final da = a.effectiveDueAt ?? far;
    final db2 = b.effectiveDueAt ?? far;
    final byDue = da.compareTo(db2);
    if (byDue != 0) return byDue;
    return a.entry.title.compareTo(b.entry.title);
  }
}

/// V4.1 批次 2：**一条催办条目 + 它的状态**（界面与导出共用的载体）。
///
/// 这是「两表 JOIN」在应用层的落地形态：
/// 条目来自 [ReminderSource]（跨业务表），
/// 状态来自 `todo_states`（唯一权威源），
/// 这里按业务键配好对，交给界面渲染或导出成文。
class TodoAgendaItem {
  const TodoAgendaItem({
    required this.entry,
    required this.state,
    required this.sourceDisplayName,
    required this.isSystemHint,
  });

  /// 条目本体（标题、副标题、到期日、天数等）。
  final OverviewEntry entry;

  /// 该条目的待办状态（null = 从未处理过）。
  final TodoState? state;

  /// 来源展示名（带域，如「生活区·仓储借出到期」）。
  final String sourceDisplayName;

  /// 是否系统类（借出到期等）——用于图标区分（元宝 B5）。
  final bool isSystemHint;

  /// 是否已处理（划线灰化）。
  bool get isDone => state?.isDone ?? false;

  /// 是否已延期（三态之一）。
  bool get isDeferred => state?.isDeferred ?? false;

  /// 延期次数（按「次」累计，跨天不重置）。
  int get deferCount => state?.deferCount ?? 0;

  /// 处理备注 / 延期原因。
  String? get handleNote => state?.handleNote;

  /// 处理时间（毫秒）。
  int? get doneAt => state?.doneAt;

  /// 条目**原到期日**（借出到期日 / 日程到期日）。
  int? get sourceDueAt => entry.dueAt;

  /// 延期后的**下一次提示日**。
  int? get nextDueAt => state?.nextDueAt;

  /// 有效到期日：`next_due_at` 优先，否则用条目原到期日。
  int? get effectiveDueAt => state?.nextDueAt ?? entry.dueAt;

  /// 业务键（与 `todo_states` 配对用）。
  String? get stateKey => entry.stateKey;

  /// 条目所属域。
  InventoryDomain? get domain => entry.domain;

  /// 参与催办区判定。
  bool isInAgenda(DateTime date) => TodoAgenda.isInAgenda(
        sourceDueAt: sourceDueAt,
        nextDueAt: nextDueAt,
        doneAt: doneAt,
        leadDays: entry.leadDays,
        date: date,
      );

  /// 展示用的一行摘要（导出与界面共用，避免两处措辞漂移）。
  String get summary {
    final parts = <String>[];
    if (entry.subtitle != null && entry.subtitle!.isNotEmpty) {
      parts.add(entry.subtitle!);
    }
    if (deferCount > 0) parts.add('已延期 $deferCount 次');
    if (handleNote != null && handleNote!.isNotEmpty) {
      parts.add('备注：$handleNote');
    }
    return parts.join(' · ');
  }
}
