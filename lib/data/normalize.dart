/// 名称归一化纯函数：全角转半角、去首尾空白、大小写不敏感。
///
/// 这是仓储写入/查询边界与句式解析函数共用的唯一入口，保证「UI 文本框直录」、
/// 「chip 选择位置」、「句式解析」三条路径得到的归一化值天然同源。
///
/// 本函数只做归一化，不做非空/长度校验——校验由调用方负责。
String normalizeName(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune == 0x3000) {
      // 全角空格 U+3000 -> 半角空格。
      buffer.write(' ');
    } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
      // 全角 ASCII U+FF01..U+FF5E -> 半角 ASCII（差 0xFEE0）。
      buffer.writeCharCode(rune - 0xFEE0);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  // 先做全角转换再 trim：全角空格转成半角后才能被去掉。
  return buffer.toString().trim().toLowerCase();
}
