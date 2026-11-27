/// V4.1.4：月历每一格的农历 / 节日 / 节气小字标注（纯函数）。
///
/// 用 `lunar` 包（纯 Dart、本地算、不联网）把公历日期转成展示用小字。
/// 独立成 domain 层纯函数，便于单测覆盖闰月 / 节日 / 节气，
/// 界面（schedule_tab_view）只管把它塞进格子。
///
/// ## 优先级（PM 2026-11-28 拍板）
/// 节日名 > 节气（另标）> 农历初一（带月）> 农历日。
/// - 节日：公历节日（元旦/劳动节…）+ 农历节日（春节/中秋/除夕…）；
/// - 节气：当天恰逢二十四节气时单独标注（"另标"=比普通农历日优先）；
/// - 初一：显示"正月初一"这类（带月），而不是光秃秃的"初一"；
/// - 其余农历日：显示"十五""廿三"这类。
library;

import 'package:lunar/lunar.dart';

class LunarLabel {
  const LunarLabel._();

  /// 返回 [date] 这一格的小字标注；普通日子返回农历日（如"十五"）。
  static String of(DateTime date) {
    final solar = Solar.fromYmd(date.year, date.month, date.day);
    final lunar = solar.getLunar();

    // ① 节日名（公历 + 农历）。
    final festivals = <String>[
      ...solar.getFestivals(),
      ...lunar.getFestivals(),
    ];
    if (festivals.isNotEmpty) return festivals.first;

    // ② 节气另标。
    final jieQi = lunar.getJieQi();
    if (jieQi.isNotEmpty) return jieQi;

    // ③ 农历初一：带月显示（"正月初一"），避免只看"初一"不知道几月。
    //    getMonthInChinese() 返回"正"/"闰六"（不带"月"），需补"月"字。
    final dayInChinese = lunar.getDayInChinese();
    if (dayInChinese == '初一') {
      return '${lunar.getMonthInChinese()}月初一';
    }

    // ④ 普通农历日。
    return dayInChinese;
  }
}
