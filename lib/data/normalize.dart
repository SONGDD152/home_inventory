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

/// 借出动词后缀（物品名尾部可能残留的「借」及其变体）。
///
/// V3.9.1 真机打回：说「梯子借给张三」时，旧解析器只认「动词在前」的语序，
/// 把「借」留在了物品名里 → 物品被建成「梯子借」，借出记录也挂在这个脏名上。
/// 之后说「梯子借期改成5天」按「梯子」就查不到那条记录。
const List<String> _loanSuffixWords = <String>[
  '借给', '借走', '借出', '借了', '借的', '借',
];

/// 剥掉物品名尾部的借出动词后缀：「梯子借」→「梯子」。
///
/// 只剥**词尾**的借出动词，不动词中的「借」——「借书」「借款单」「借用证」
/// 这类真名不受影响。剥完为空（物品名本身就是「借」）时返回原名，
/// 不制造出空名字。
String stripLoanSuffix(String name) {
  var value = name.trim();
  if (value.isEmpty) return value;
  for (final word in _loanSuffixWords) {
    if (!value.endsWith(word)) continue;
    final head = value.substring(0, value.length - word.length).trim();
    if (head.isEmpty) break; // 「借」本身就是名字 → 不剥。
    return head;
  }
  return value;
}

/// V3.10 复验打回（PM 2026-11-25）：剥掉物品名尾部残留的数量。
///
/// 解析器已能剥「再放梯子3个在阳台」的后置数量，但语音识别语序千变万化，
/// 万一漏剥，「梯子3个」就会建成一件新物品（明细莫名多一行）——与
/// V3.9.1「梯子借」同源。数据层再兜一道：落库前剥掉尾部「数字/中文数字+量词」。
/// 只剥词尾，「5号电池」「2梯子」这类真名不含量词、不受影响。
final RegExp _trailingQuantityPattern =
    RegExp(r'(\d+|[一两二三四五六七八九十百]+)\s*[个本把件只张]$');

String stripTrailingQuantity(String name) {
  final value = name.trim();
  final match = _trailingQuantityPattern.firstMatch(value);
  if (match == null) return value;
  // 量词必需才剥：「5号电池」里「5」后面是「号」，不误伤。
  final head = value.substring(0, match.start).trim();
  if (head.isEmpty) return value; // 「3个」本身就是名字 → 不剥，避免空名。
  return head;
}

/// 物品名的「词根」：归一化后剥掉尾部借出动词与残留数量。
///
/// 「梯子」与「梯子借」的词根都是「梯子」——它们本该是同一件东西，
/// 只是历史上被脏数据拆成了两条记录。
String itemNameRoot(String name) =>
    stripTrailingQuantity(stripLoanSuffix(normalizeName(name)));

/// 物品名宽松相等：精确相等，或词根相等。
///
/// 用于语音查库时的兜底匹配——让 V3.9 之前产生的「梯子借」这类脏名
/// 仍能被用户说「梯子」时找到（PM 真机复验场景②④）。
bool itemNamesMatch(String a, String b) {
  final x = normalizeName(a);
  final y = normalizeName(b);
  if (x == y) return true;
  return itemNameRoot(x) == itemNameRoot(y) && itemNameRoot(x).isNotEmpty;
}
