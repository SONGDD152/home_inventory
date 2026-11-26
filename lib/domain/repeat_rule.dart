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
}
