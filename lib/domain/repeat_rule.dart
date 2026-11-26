/// V4.1 批次 3：**重复规则**（`reminders.repeat_rule` 列）。
///
/// 列本来就在（V4.0 建表时就有），但之前**没有任何 UI 用它**——
/// 批次 3 要让日程签能设、能显示，所以在这里把取值与文案定死一份，
/// UI 与数据层共用，避免两处各写一套字符串。
library;

/// 重复规则取值。
///
/// - `daily` 每天 / `weekly` 每周 / `monthly` 每月 / `yearly` 每年；
/// - null = **不重复**（一次性提醒）。
abstract class RepeatRule {
  const RepeatRule._();

  /// 每天。
  static const String daily = 'daily';

  /// 每周。
  static const String weekly = 'weekly';

  /// 每月。
  static const String monthly = 'monthly';

  /// 每年。
  static const String yearly = 'yearly';

  /// 全部可选值（按展示顺序）。
  static const List<String> all = <String>[daily, weekly, monthly, yearly];

  /// 展示名（null / 非法值 → 「不重复」）。
  static String labelOf(String? rule) {
    switch (rule) {
      case daily:
        return '每天';
      case weekly:
        return '每周';
      case monthly:
        return '每月';
      case yearly:
        return '每年';
      default:
        return '不重复';
    }
  }

  /// 取合法值（null / 非法值 → null = 不重复）。
  static String? normalize(String? value) {
    if (value == null) return null;
    return all.contains(value) ? value : null;
  }

  // ─────────────────── V4.1 批次 4：周期推进（元宝裁定②甲方案） ───────────────────
  //
  // 裁定②：重复规则语义**选甲**——完成后自动新建下一实例、**保留历史**。
  // 「下一个到期日怎么算」必须只有**一份实现**，否则界面显示的周期
  // 与数据层真正落库的周期会漂（同源铁律：口径唯一实现放 domain 层）。

  /// 按重复规则把 [from] 往后推一个周期，返回新的到期时刻。
  ///
  /// - `daily` → +1 天；`weekly` → +7 天；
  /// - `monthly` → +1 月；`yearly` → +1 年；
  /// - null / 非法规则 → **null**（不重复 = 不推进）。
  ///
  /// ## 月末怎么办（clamp）
  ///
  /// 1 月 31 日 + 1 月 = 2 月 31 日**不存在**，所以落到**该月最后一天**
  /// （2 月 28 日 / 闰年 29 日）；2 月 29 日 + 1 年 = 2 月 29 日不存在，
  /// 落到 2 月 28 日。日期语义上这是日程软件的标准做法。
  ///
  /// ## 已知取舍：链式推进会逐月漂移
  ///
  /// 1/31 → 2/28 → 3/28 → 4/28……（每月都从**上一实例**推进，
  /// 月末被 clamp 后"锚点"就丢了）。
  /// 锚点式推进（永远从链条起点算）需要额外存一列「原始锚点」，
  /// **schema v13 保持不变**是批次 4 的硬约束（零新增列零新增表），
  /// 所以本批不实现锚点式。哪天要修，再单独提一个 schema 升级批次。
  ///
  /// 时分秒原样保留——推进的是「日历周期」，不是「整点偏移」。
  static DateTime? advance(DateTime from, String? rule) {
    switch (normalize(rule)) {
      case daily:
        return from.add(const Duration(days: 1));
      case weekly:
        return from.add(const Duration(days: 7));
      case monthly:
        return _addMonths(from, 1);
      case yearly:
        return _addMonths(from, 12);
      default:
        return null;
    }
  }

  /// 加 [months] 个月，日号超出目标月时 clamp 到该月最后一天。
  static DateTime _addMonths(DateTime from, int months) {
    final index = from.month - 1 + months;
    final year = from.year + (index ~/ 12);
    final month = (index % 12) + 1;
    // DateTime(year, month + 1, 0) = 目标月的最后一天
    //（month = 12 时 DateTime(year, 13, 0) 自动落到次年 1 月 0 日 = 12 月 31 日）。
    final lastDay = DateTime(year, month + 1, 0).day;
    final day = from.day > lastDay ? lastDay : from.day;
    return DateTime(
      year,
      month,
      day,
      from.hour,
      from.minute,
      from.second,
      from.millisecond,
      from.microsecond,
    );
  }
}
