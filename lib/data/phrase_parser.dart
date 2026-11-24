import 'normalize.dart';

/// 句式解析结果（密封类型）。
///
/// V3.7：在原三态（录入/查询/未识别）基础上扩展借出 [ParseLend] / 归还
/// [ParseReturn] 两态；[ParseUnrecognized] 携带向 UI 展示的意图猜测，
/// 供"没听懂"时弹确认框（元宝批复：不静默失败，显示猜测意图）。
sealed class ParseResult {
  const ParseResult();
}

/// 录入意图：<物品>放<位置>
class ParseUpsert extends ParseResult {
  const ParseUpsert({required this.item, required this.location, this.quantity = 1});

  final String item;
  final String location;

  /// V3.7：录入数量（"记：2个梯子放阳台" → 2），默认 1。
  final int quantity;
}

/// 查询意图：<物品>在哪
class ParseQuery extends ParseResult {
  const ParseQuery({required this.item});

  final String item;
}

/// 借出意图（V3.7）：物品 + 借阅人 + 数量 + 借期天数。
class ParseLend extends ParseResult {
  const ParseLend({
    required this.item,
    required this.borrower,
    this.quantity = 1,
    this.days,
  });

  final String item;
  final String borrower;
  final int quantity;

  /// 可选借期（"借给张三3天" → 3）；未提则用默认 3 天。
  final int? days;
}

/// 归还意图（V3.7）：物品 + 数量（未提=全部）。
///
/// V3.8 新增 [borrower]：句中明确指名的借阅人。
/// PM 真机反馈——「还了1个梯子」没说是谁还的，同一件东西两人各借一份时
/// 记到谁头上全靠猜。句式补两种指名说法：
///  * 「张三还了1个梯子」（人 + 归还动词）
///  * 「还了1个梯子给张三」（归还动词 + 物品 + 给某人）
/// 句中未指名时 borrower 为 null，由 UI 按未还清候选收敛——
/// 只有一笔时直接还，多笔时弹候选让用户点，绝不静默记账。
class ParseReturn extends ParseResult {
  const ParseReturn({required this.item, this.quantity, this.borrower});

  final String item;

  /// 归还数量；null 表示全部归还。
  final int? quantity;

  /// 句中指名的借阅人；null 表示句子没说是谁还的。
  final String? borrower;
}

/// 未识别：不符合允许的句式模板。
/// [guess] 为可选意图猜测（'lend'/'return'/null），供 UI 确认框使用。
class ParseUnrecognized extends ParseResult {
  const ParseUnrecognized({this.guess});

  /// 'lend' / 'return' / null（无猜测）。
  final String? guess;
}

// ==================== V3.9 语音化第一批 ====================

/// 废弃意图（V3.9）：把物品从明细转入回收站。
///
/// PM 原话「东西废弃的话能语音输入，说一句话就把物品从明细里转到回收站」。
class ParseDiscard extends ParseResult {
  const ParseDiscard({required this.item});

  final String item;
}

/// 恢复意图（V3.9）：把回收站里的物品恢复到明细。
class ParseRestore extends ParseResult {
  const ParseRestore({required this.item});

  final String item;
}

/// 改借期模式。
enum DueChangeMode {
  /// 「改成 5 天 / 延长到 7 天」——设为总天数。
  set,

  /// 「再借 3 天 / 续借 3 天」——在当前借期上追加。
  extendBy,
}

/// 改借期意图（V3.9）。
///
/// 元宝口径：本批只支持「改成 N 天 / 延长到 N 天 / 再借 N 天」三种；
/// 「缩短」暂不支持（没有催还机制，支持了也无效）。
class ParseDueChange extends ParseResult {
  const ParseDueChange({
    required this.days,
    this.item,
    this.borrower,
    this.mode = DueChangeMode.set,
  });

  /// 目标天数（[DueChangeMode.set] 时为总天数；[DueChangeMode.extendBy]
  /// 时为追加天数）。
  final int days;

  /// 物品名；句中没指名时为 null（由 UI 按未还清候选收敛）。
  final String? item;

  /// 借阅人；句中没指名时为 null。
  final String? borrower;

  final DueChangeMode mode;
}

/// 歧义意图（V3.9）：一句话有两种合理解释，交由用户点选。
///
/// 元宝补充①：句子同时含废弃动词与位置词（如「梯子不要了放阳台」）时，
/// 不强行选废弃，而是报歧义弹确认框让用户选意图。
class ParseAmbiguous extends ParseResult {
  const ParseAmbiguous({required this.candidates, required this.hint});

  /// 候选意图（第一个是首选）。
  final List<ParseResult> candidates;

  /// 展示给用户的说明（如「这句有两种理解：…」）。
  final String hint;
}

const List<String> _trailingParticles = <String>['了', '呢', '吧'];

/// 查询触发词（后缀）。按长度降序匹配，长的优先（「在哪里」先于「哪里」）。
const List<String> _querySuffixes = <String>['在哪里', '在哪儿', '在哪', '哪里'];

/// V3 交互说明：查询触发词（前缀）。「找梯子」「有没有梯子」。
/// 按长度降序匹配。
const List<String> _queryPrefixes = <String>['有没有', '查一下', '查查', '找'];

/// V3 交互说明：显式意图前缀。normalizeName 会把全角冒号转半角，
/// 故这里用半角冒号匹配归一化后的文本（「记：」「查：」同样命中）。
const String _recordPrefix = '记:';
const String _queryPrefixMark = '查:';

/// 放置动词词干。V1 认「放」；V2 扩「搁/塞/摆」；
/// V3 交互说明再扩「收/存/归」；V3.2 再扩「挪」（挪位语义，挪到/挪在/挪客厅）。
const List<String> _placeVerbs = <String>['放', '搁', '塞', '摆', '收', '存', '归', '挪'];

/// 动词词干后可紧跟的介词。整体上「放到/放在/搁到/塞往…」视为一个动词短语，
/// 介词并入动词吞掉，位置取介词之后的干净片段。
const List<String> _prepositions = <String>['到', '在', '往', '向', '给', '至'];

/// 倒装「把」字句的显式主语（可省略）。
const List<String> _baSubjects = <String>['我', '你', '他'];

bool _endsWithParticle(String text) {
  if (text.isEmpty) return false;
  return _trailingParticles.contains(text.substring(text.length - 1));
}

/// 组合式「查<物品>在哪儿」：后缀命中后，物品名头部可能还挂着查询词
/// （查一下/查查/有没有/找，以及口语的裸「查」），逐层剥掉。
/// 裸「查」仅在剩余长度 >2 时剥（「查表」这类两字物品名不误剥）。
String _stripLeadingQueryWords(String item) {
  var result = item;
  var changed = true;
  while (changed && result.isNotEmpty) {
    changed = false;
    for (final prefix in _queryPrefixes) {
      if (result.startsWith(prefix) && result.length > prefix.length) {
        result = result.substring(prefix.length).trim();
        changed = true;
        break;
      }
    }
    if (!changed && result.length > 2 && result.startsWith('查')) {
      result = result.substring(1).trim();
      changed = true;
    }
  }
  return result;
}

bool _isPreposition(String text) {
  if (text.isEmpty) return false;
  return _prepositions.contains(text.substring(0, 1));
}

/// 剥句尾语气词（只剥一层）。
String _stripTrailingParticle(String text) {
  if (_endsWithParticle(text)) return text.substring(0, text.length - 1).trim();
  return text;
}

/// 语序有效性校验（同 V2）：动词数恰好 1、不叠用倒装。
bool _isValidWordOrder(String core) {
  if (core.startsWith('把')) return false;
  var verbCount = 0;
  for (var i = 0; i < core.length; i++) {
    if (_placeVerbs.contains(core.substring(i, i + 1))) verbCount++;
  }
  return verbCount == 1;
}

/// 剥离倒装前置的「把」字（可带一个显式主语）。
String _stripBaPrefix(String text) {
  if (text.startsWith('把')) return text.substring(1).trim();
  if (text.length >= 2 &&
      _baSubjects.contains(text.substring(0, 1)) &&
      text.substring(1, 2) == '把') {
    return text.substring(2).trim();
  }
  return text;
}

/// 解析录入句式（核心，V1/V2 逻辑原样保留）。
/// 返回 null 表示不符合录入句式。
ParseUpsert? _parseRecord(String text) {
  final core = _stripBaPrefix(text);
  if (core.isEmpty || !_isValidWordOrder(core)) return null;

  int? verbIndex;
  for (var i = 0; i < core.length; i++) {
    if (_placeVerbs.contains(core.substring(i, i + 1))) {
      verbIndex = i;
      break;
    }
  }
  if (verbIndex == null || verbIndex == 0 || verbIndex == core.length - 1) {
    return null;
  }

  final item = core.substring(0, verbIndex).trim();
  var location = core.substring(verbIndex + 1).trim();
  if (_isPreposition(location)) {
    location = location.substring(1).trim();
  }
  if (item.isEmpty || location.isEmpty || _isPreposition(location)) {
    return null;
  }
  return ParseUpsert(
    item: normalizeName(item),
    location: normalizeName(location),
  );
}

/// 解析查询句式（V3 扩展：后缀在哪/哪里、前缀找/有没有、显式「查：」）。
ParseQuery? _parseQuery(String text) {
  // 后缀式：梯子在哪 / 梯子哪里 / 组合式「查梯子在哪儿」
  for (final suffix in _querySuffixes) {
    if (text.endsWith(suffix)) {
      final item =
          _stripLeadingQueryWords(text.substring(0, text.length - suffix.length).trim());
      if (item.isNotEmpty) return ParseQuery(item: normalizeName(item));
    }
  }
  // 前缀式：找梯子 / 有没有梯子
  for (final prefix in _queryPrefixes) {
    if (text.startsWith(prefix)) {
      final item = text.substring(prefix.length).trim();
      if (item.isNotEmpty) return ParseQuery(item: normalizeName(item));
    }
  }
  return null;
}

// ==================== V3.7 借阅/数量语义 ====================

/// 借出触发词。按长度降序，长的优先。
const List<String> _lendMarkers = <String>['借给', '借出', '借走', '借了', '借'];

/// 归还触发词。
const List<String> _returnMarkers = <String>['归还', '还了', '还回', '还'];

/// 剥掉句首的借出动词与其后的「了」，返回干净的剩余片段。
///
/// V3.7.2 修复：口语里动词与动态助词「了」常连用（「借了3个钉子」「借走了梯子」
/// 「借给了张三」）。此前只剥「借」一个字，「了」留在数量前面导致
/// [_extractLeadingQuantity] 匹配失败——数量静默丢成 1，物品名也被污染成
/// 「了3个钉子」。这里按 [_lendMarkers]（长词优先）整体剥动词，再剥一层「了」。
///
/// 不是借出动词开头时原样返回（调用方据此判定句式不匹配）。
String _stripLendVerbPrefix(String text) {
  var rest = text.trim();
  for (final marker in _lendMarkers) {
    if (!rest.startsWith(marker)) continue;
    rest = rest.substring(marker.length).trim();
    // 动词后可能跟「了」（借了/借走了/借给了）。
    if (rest.startsWith('了')) rest = rest.substring(1).trim();
    return rest;
  }
  return rest;
}

/// 剥掉句首的语气词「了/呢/吧」（只剥一层）。
///
/// 用于「借走了3个钉子」这类动词后紧跟助词、数量再跟其后的口语。
String _stripLeadingParticle(String text) {
  var rest = text.trim();
  if (rest.isEmpty) return rest;
  if (_trailingParticles.contains(rest.substring(0, 1))) {
    rest = rest.substring(1).trim();
  }
  return rest;
}

/// 中文数字 → 整数。仅覆盖 1-20（家庭场景够用）。
const Map<String, int> _cnNumbers = <String, int>{
  '一': 1, '两': 2, '二': 2, '三': 3, '四': 4, '五': 5,
  '六': 6, '七': 7, '八': 8, '九': 9, '十': 10,
  '十一': 11, '十二': 12, '十三': 13, '十四': 14, '十五': 15,
  '十六': 16, '十七': 17, '十八': 18, '十九': 19, '二十': 20,
};

/// 从文本头部剥出数量（"2个梯子" → (2, "梯子")；"两个梯子" 同）。
/// 识别阿拉伯数字与中文数字，量词 个/本/把/件/只/张 可跟可不跟。
({int value, String rest})? _extractLeadingQuantity(String text) {
  // 阿拉伯数字。
  final arabic = RegExp(r'^(\d+)\s*[个本把件只张只]?\s*');
  final m = arabic.firstMatch(text);
  if (m != null) {
    final value = int.tryParse(m.group(1)!);
    if (value != null && value >= 1) {
      return (value: value, rest: text.substring(m.end).trim());
    }
  }
  // 中文数字（长词优先：十一 先于 一）。
  final keys = _cnNumbers.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final key in keys) {
    if (!text.startsWith(key)) continue;
    var rest = text.substring(key.length).trim();
    // 剥一个可选量词。
    if (rest.isNotEmpty && '个本把件只张'.contains(rest.substring(0, 1))) {
      rest = rest.substring(1).trim();
    }
    return (value: _cnNumbers[key]!, rest: rest);
  }
  return null;
}

/// 解析借出句式。返回 null 表示不匹配。
///
/// 支持四种自然口语（数量/天数均可省略）：
///  * 借给张三2个梯子 / 借给了张三2个梯子（「给」字句，人到「给」后、物到「给」前）
///  * 张三借了2个梯子 / 张三借梯子（人+借动词）
///  * 借2个梯子给张三 / 借了2个梯子给张三（物在「借」后、「给」前，人在「给」后）
///  * 梯子被张三借走了2天（被字句，物品在前、人在「被」后）
///
/// V3.7.2 修复三处切词缺陷（真机验收打回）：
///  ① 「借了3个钉子给张三」此前只剥「借」一个字，「了」留在数量前 →
///     数量匹配失败静默丢成 1，物品名被污染成「了3个钉子」。
///  ② 「借给了张三3个钉子」→ 借阅人被切成「了张三」。
///  ③ 「梯子被张三借走了1天」此前完全不支持被字句 → 物品切成「走」、
///     借阅人切成「梯子被张三」。
ParseLend? _parseLend(String text) {
  if (!text.contains('借')) return null;

  // 形态0（被字句）：<物品>被<人>借走/借出/借了。
  // 中文被动语序，物品在最前、人在「被」后，与前三种形态的切分方向相反。
  final passive = _parseLendPassive(text);
  if (passive != null) return passive;

  // 形态1「借给」：句式 = 借给[了] + <人> + <数量物品> + [天数]
  // 人/物无显式分隔，靠数量切分："借给张三2个梯子" → 人=张三、物=梯子、数量=2。
  if (text.startsWith('借给')) {
    // V3.7.2 修复②：整体剥「借给」及紧随其后的「了」，避免人名被切成「了张三」。
    var tail = _stripLendVerbPrefix(text);
    if (tail.isEmpty) return null;

    // 先剥尾部天数（"张三2个梯子5天"）。
    int? days;
    final dayMatch = RegExp(r'(\d+)\s*天$').firstMatch(tail);
    if (dayMatch != null) {
      days = int.tryParse(dayMatch.group(1)!);
      tail = tail.substring(0, dayMatch.start).trim();
    }
    if (tail.isEmpty) return null;

    // 找数量位置：数量前面是人，数量+量词后面是物。
    final qtyMatch = RegExp(r'(\d+|[一两二三四五六七八九十]+)\s*[个本把件只张]').firstMatch(tail);
    if (qtyMatch != null) {
      final borrower = normalizeName(tail.substring(0, qtyMatch.start).trim());
      final item = normalizeName(_stripTrailingParticle(tail.substring(qtyMatch.end).trim()));
      final qty = int.tryParse(qtyMatch.group(1)!) ?? _cnNumbers[qtyMatch.group(1)!] ?? 1;
      if (borrower.isNotEmpty && item.isNotEmpty && qty >= 1) {
        return ParseLend(item: item, borrower: borrower, quantity: qty, days: days);
      }
    }
    // 无数量："借给张三梯子" — 人/物难分，返回带 guess 由 UI 确认（此处放弃精确解析）。
    return null;
  }

  final giveIdx = text.indexOf('给');
  if (giveIdx > 0) {
    // 形态2：借[了/走/出]<数量><物品>给<人>(借2个梯子给张三)
    final head = text.substring(0, giveIdx).trim(); // "借2个梯子"
    var tail = text.substring(giveIdx + 1).trim(); // "张三"
    if (tail.isEmpty) return null;
    int? days;
    final dayMatch = RegExp(r'^(.+?)(\d+)\s*天$').firstMatch(tail);
    if (dayMatch != null && dayMatch.group(1)!.trim().isNotEmpty) {
      days = int.tryParse(dayMatch.group(2)!);
      tail = dayMatch.group(1)!.trim();
    }
    final borrower = normalizeName(tail);
    if (borrower.isEmpty) return null;
    // V3.7.2 修复①：整体剥借出动词（含「借了/借走/借出」）与其后的「了」。
    // 此前只剥「借」一个字，"借了3个钉子" 剩 "了3个钉子" → 数量匹配失败
    // 静默丢成 1、物品名被污染成「了3个钉子」。
    final itemPart = _stripLendVerbPrefix(head);
    var quantity = 1;
    var rest2 = itemPart;
    final q = _extractLeadingQuantity(rest2);
    if (q != null && q.rest.isNotEmpty) {
      quantity = q.value;
      rest2 = q.rest;
    }
    final item = normalizeName(_stripTrailingParticle(rest2));
    // V3.9 加固：物品名被剥空时不再返回（空物品名的借出单是乱账）。
    if (item.isEmpty) return null;
    return ParseLend(item: item, borrower: borrower, quantity: quantity, days: days);
  }

  // 形态3：<人>借<了>?<数量><物品>。借动词必须在人之后。
  for (final marker in _lendMarkers) {
    final idx = text.indexOf(marker);
    if (idx <= 0) continue;
    final borrower = normalizeName(text.substring(0, idx));
    var rest = text.substring(idx + marker.length).trim();
    if (borrower.isEmpty || rest.isEmpty) continue;
    if (_placeVerbs.any((v) => rest.contains(v))) continue;
    // V3.7.2 修复：marker 可能只吃到「借」，剩下的「了3个钉子」需再剥一层「了」，
    // 否则数量匹配失败静默丢成 1、物品名残留「了」。
    rest = _stripLeadingParticle(rest);
    if (rest.isEmpty) continue;
    var quantity = 1;
    final q = _extractLeadingQuantity(rest);
    if (q != null && q.rest.isNotEmpty) {
      quantity = q.value;
      rest = q.rest;
    }
    int? days;
    final dayMatch = RegExp(r'(\d+)\s*天\s*$').firstMatch(rest);
    if (dayMatch != null) {
      days = int.tryParse(dayMatch.group(1)!);
      rest = rest.substring(0, dayMatch.start).trim();
    }
    final item = normalizeName(_stripTrailingParticle(rest));
    if (item.isEmpty) continue;
    return ParseLend(item: item, borrower: borrower, quantity: quantity, days: days);
  }
  return null;
}

/// 解析被字句借出：<物品>被<人>借走/借出/借了。
///
/// V3.7.2 新增。中文被动语序，物品在最前、人在「被」后，与「借给X…」「X借…」
/// 「借…给X」三种主动语序的切分方向完全相反，此前无任何形态能匹配，
/// 会被形态3 切成一团（物品="走"、借阅人="梯子被张三"）。
///
/// 例：「梯子被张三借走了1天」→ 物品=梯子、人=张三、天数=1。
/// 「3个钉子被张三借走了」→ 物品=钉子、数量=3、人=张三。
ParseLend? _parseLendPassive(String text) {
  final beiIdx = text.indexOf('被');
  if (beiIdx <= 0) return null;

  // 「被」之前是物品部分（可能带前置数量："3个钉子被张三借走了"）。
  var headPart = text.substring(0, beiIdx).trim();
  if (headPart.isEmpty) return null;
  var quantity = 1;
  final headQty = _extractLeadingQuantity(headPart);
  if (headQty != null && headQty.rest.isNotEmpty) {
    quantity = headQty.value;
    headPart = headQty.rest;
  }
  final item = normalizeName(_stripTrailingParticle(headPart));
  if (item.isEmpty) return null;

  // 「被」之后是「<人>借走/借出/借了」。
  var tail = text.substring(beiIdx + 1).trim();
  if (tail.isEmpty) return null;
  String? verb;
  int? verbIdx;
  for (final marker in _lendMarkers) {
    final i = tail.indexOf(marker);
    if (i <= 0) continue;
    // 取最靠前的动词；同位置取更长的（借走/借出 优先于 借）。
    if (verbIdx == null || i < verbIdx) {
      verbIdx = i;
      verb = marker;
    }
  }
  if (verbIdx == null || verb == null) return null;
  final borrower = normalizeName(tail.substring(0, verbIdx));
  if (borrower.isEmpty) return null;

  var rest = tail.substring(verbIdx + verb.length).trim();
  // 动词后可能跟「了」（借走了）。剥掉后为空是合法的——「梯子被张三借走了」
  // 就是完整的借出句，只是没有额外数量/天数。V3.7.2 修复：此前这里直接
  // return null，导致该句回落到形态3 被切成一团。
  rest = _stripLeadingParticle(rest);
  // 尾部天数："借走了1天" → days=1。
  int? days;
  if (rest.isNotEmpty) {
    final dayMatch = RegExp(r'(\d+)\s*天\s*$').firstMatch(rest);
    if (dayMatch != null) {
      days = int.tryParse(dayMatch.group(1)!);
      rest = rest.substring(0, dayMatch.start).trim();
    }
  }
  // 尾部数量（"借走了2个"）：只在前面没给数量时采用。
  if (rest.isNotEmpty) {
    final q = _extractLeadingQuantity(rest);
    if (q != null && q.rest.isEmpty) {
      quantity = q.value;
      rest = '';
    }
  }
  if (rest.isNotEmpty) return null;
  return ParseLend(item: item, borrower: borrower, quantity: quantity, days: days);
}

/// 归还句式解析。
///
/// 支持三类（V3.8 重构，补「是谁还的」）：
///  * A 归还动词开头：还了1个梯子 / 还梯子 / 归还梯子
///  * B 人 + 归还动词：张三还了1个梯子 / 张三归还了梯子
///  * C 归还动词 + 物品 + 给某人：还了1个梯子给张三
///
/// V3.8 修复（PM 真机反馈）：此前只支持 A，且 A 遇到尾部「给某人」会直接
/// 丢弃（「还了1个梯子给张三」拿不到张三），导致多人借同一物品时无法判定
/// 归属、只能按最早一笔静默记账。现在句式本身能指名，指不出时由 UI
/// 弹候选让用户选。
ParseReturn? _parseReturn(String text) {
  // 含「放在/收进/存到…」等放置短语的是录入句（「东西还放在阳台」），
  // 不能当归还句解析。
  if (_hasPlacementPhrase(text)) return null;
  for (final marker in _returnMarkers) {
    final idx = text.indexOf(marker);
    if (idx < 0) continue;

    // 形态B：动词前是人名 → 借阅人。
    if (idx > 0) {
      final head = text.substring(0, idx).trim();
      if (_looksLikeBorrowerName(head)) {
        final rest = _stripLeadingParticle(
            text.substring(idx + marker.length).trim());
        final body = _parseReturnBody(rest);
        if (body != null) {
          return ParseReturn(
            item: body.item,
            quantity: body.quantity,
            borrower: normalizeName(head),
          );
        }
      }
      continue;
    }

    // 形态A / C：动词在句首。
    final rest = text.substring(marker.length).trim();
    if (rest.isEmpty) continue;
    final body = _parseReturnBody(rest);
    if (body == null) continue;
    // 形态C：尾部「给某人」即借阅人（此前被直接丢弃）。
    String? borrower;
    final giveIdx = body.tail.indexOf('给');
    if (giveIdx > 0) {
      final who = body.tail.substring(giveIdx + 1).trim();
      if (who.isNotEmpty) borrower = normalizeName(who);
    }
    return ParseReturn(item: body.item, quantity: body.quantity, borrower: borrower);
  }
  return null;
}

/// 归还句式的切分结果：物品 + 数量 + 未剥离的尾部（可能仍含「给某人」）。
({String item, int? quantity, String tail})? _parseReturnBody(String rest) {
  if (rest.isEmpty) return null;
  var body = rest;
  int? quantity;
  final q = _extractLeadingQuantity(body);
  if (q != null) {
    // 只有数量没有物品名（「还了1个」）→ 不是有效归还句。
    if (q.rest.isEmpty) return null;
    quantity = q.value;
    body = q.rest;
  }
  // 物品段在「给」之前，尾部「给某人」留给调用方取借阅人。
  final giveIdx = body.indexOf('给');
  final itemPart = giveIdx > 0 ? body.substring(0, giveIdx).trim() : body;
  final item = normalizeName(_stripTrailingParticle(itemPart));
  if (item.isEmpty) return null;
  return (item: item, quantity: quantity, tail: body);
}

/// 判断句中是否含「放置动词 + 介词」构成的放置短语（放阳台 / 收进抽屉 / 存到柜子）。
///
/// 借还解析都要排除放置句，否则「东西还放在阳台」会被当成归还。
/// 只认「动词紧跟介词」的组合——这样「还了收据」「借了收纳盒」这类
/// 物品名里带 收/存 的正常句子不会被误伤。
bool _hasPlacementPhrase(String text) {
  for (final verb in _placeVerbs) {
    for (final prep in _prepositions) {
      if (text.contains('$verb$prep')) return true;
    }
  }
  return false;
}

/// 判断「归还动词前的那一段」是否像借阅人姓名。
///
/// 解析器是纯函数、拿不到仓储，无法核实是否真是借阅人——所以只做粗筛：
/// 不含数字、不含量词、不含放置动词、长度 1..8 字。真正的核对交给 UI
/// （与借出记录对不上会提示候选，不会静默记错账）。
bool _looksLikeBorrowerName(String head) {
  if (head.isEmpty || head.length > 8) return false;
  if (RegExp(r'\d').hasMatch(head)) return false;
  if (_placeVerbs.any((v) => head.contains(v))) return false;
  if ('个本把件只张'.contains(head.substring(head.length - 1))) return false;
  return true;
}

// ==================== V3.9 语音化第一批：废弃 / 恢复 / 改借期 ====================

/// 废弃动词词表（长词优先）。
///
/// 词表覆盖 PM 提的「不要了 / 废弃了 / 扔了 / 报废了 / 不用了」等口语。
/// 长词在前，命中时先剥长的（「不要了」优先于「不要」），避免把
/// 「梯子不要了」切成「梯子不」+「要了」。
///
/// 只收**表示丢弃已完成**的词（扔了/扔掉/丢掉了）与「不要了/废弃了」
/// 这类明确否定词；单字「扔/丢」不收——「梯子扔阳台」是"放到阳台"，
/// 不是丢弃，收进来会把这类句子抢答成废弃（V1「精确模板外未识别」）。
const List<String> _discardMarkers = <String>[
  '不需要了', '不要了', '不用了', '废弃了', '报废了', '丢掉了', '扔了', '扔掉',
  '不需要', '不要', '不用', '废弃', '报废', '扔', '丢',
];

/// 恢复动词词表（长词优先）。
///
/// 不用「还回」——那是归还语义（V3.7 已占用），混用会把「还回梯子」
/// 记成归还而不是恢复。
const List<String> _restoreMarkers = <String>['恢复', '还原'];

/// 改借期句的特征词。命中其一才尝试按改借期解析。
const List<String> _dueMarkers = <String>['借期', '到期', '延期', '续借', '再借'];

/// 改借期句里要剥掉的修饰词（剥完剩下的就是物品名/人名）。
const List<String> _dueKeywords = <String>[
  '借期', '到期日', '到期', '延期', '续借', '再借', '多借',
  '延长到', '延长', '改成', '改为', '改到', '调到', '设为', '变成', '借到',
];

/// 「放回明细」——恢复的特例说法。
const String _putBackSuffix = '放回明细';

/// 解析废弃句式。
///
/// 支持：梯子废弃了 / 梯子不要了 / 把梯子扔了 / 梯子报废了 / 梯子不用了。
///
/// 元宝补充①：句中**同时**含位置信息时（「梯子不要了放阳台」）不强行
/// 判废弃，而是返回 [ParseAmbiguous]（废弃 vs 放置）交给用户点选——
/// 两种理解都合理，替用户猜就是替他做决定。
ParseResult? _parseDiscard(String text) {
  String? marker;
  int? markerIdx;
  for (final m in _discardMarkers) {
    final i = text.indexOf(m);
    if (i < 0) continue;
    // 取最靠前的动词；同位置时保留词表里更长的那个（词表已按长度降序）。
    if (markerIdx == null || i < markerIdx) {
      markerIdx = i;
      marker = m;
    }
  }
  if (markerIdx == null || marker == null) return null;

  var head = text.substring(0, markerIdx).trim();
  head = _stripBaPrefix(head);
  final item = normalizeName(_stripTrailingParticle(head));
  if (item.isEmpty) return null; // 「不要了」这类没有物品名的句子不是废弃句。

  var tail = text.substring(markerIdx + marker.length).trim();
  tail = _stripTrailingParticle(tail);
  if (tail.isEmpty) return ParseDiscard(item: item);

  // 单字丢弃动词（扔/丢）后面还带东西 → 是"放到某处"不是丢弃，
  // 例如「梯子扔阳台」。这层不认废弃，交给后面的放置/未识别分支，
  // 保持 V1「精确模板之外一律未识别」的老口径不被扩大。
  if (marker == '扔' || marker == '丢') return null;

  // 动词后面还有内容 → 报歧义：既可能是「放弃这件东西」，也可能是
  // 「放到某个位置」。
  final location = _extractPlacementLocation(tail);
  final candidates = <ParseResult>[ParseDiscard(item: item)];
  if (location != null) {
    candidates.add(ParseUpsert(item: item, location: normalizeName(location)));
  }
  return ParseAmbiguous(
    candidates: candidates,
    hint: '「$item」这句有两种理解：'
        '${location != null ? '放到$location，或' : ''}把它转入回收站？',
  );
}

/// 从片段里取出放置位置（动词 + 介词之后的干净部分）。
///
/// 用于歧义分支：废弃动词之后的尾巴若还带位置（如「不要了放阳台」），
/// 就把它还原成位置候选。
String? _extractPlacementLocation(String tail) {
  for (final verb in _placeVerbs) {
    final i = tail.indexOf(verb);
    if (i < 0) continue;
    var loc = tail.substring(i + 1).trim();
    if (_isPreposition(loc)) loc = loc.substring(1).trim();
    loc = _stripTrailingParticle(loc);
    if (loc.isEmpty) continue;
    return loc;
  }
  return null;
}

/// 解析恢复句式（回收站 → 明细）。
///
/// 支持：恢复梯子 / 把梯子恢复 / 梯子恢复到明细 / 还原梯子 / 梯子放回明细。
///
/// 「放回明细」是特例——它含放置动词「放」，若放给录入分支会被解析成
/// 「把梯子放到'回明细'」这种垃圾位置，所以在这里单独拦下。
ParseRestore? _parseRestore(String text) {
  if (text.endsWith(_putBackSuffix)) {
    final head = _stripBaPrefix(
        text.substring(0, text.length - _putBackSuffix.length).trim());
    final item = normalizeName(_stripTrailingParticle(head));
    if (item.isEmpty) return null;
    return ParseRestore(item: item);
  }
  for (final marker in _restoreMarkers) {
    final idx = text.indexOf(marker);
    if (idx < 0) continue;
    final head = _stripBaPrefix(text.substring(0, idx).trim());
    // 尾部「到明细 / 回明细 / 到物品明细 / 到首页」等去处说明语。
    var tail = text.substring(idx + marker.length).trim();
    tail = tail.replaceAll(RegExp(r'(到|回)(物品)?明细.*$'), '');
    tail = tail.replaceAll(RegExp(r'到首页.*$'), '');
    tail = _stripTrailingParticle(tail.trim());

    if (head.isNotEmpty) {
      final item = normalizeName(_stripTrailingParticle(head));
      if (item.isNotEmpty) return ParseRestore(item: item);
      continue;
    }
    // 动词开头：「恢复梯子」——物品在动词后面。
    final tailItem = normalizeName(_stripTrailingParticle(tail));
    if (tailItem.isNotEmpty) return ParseRestore(item: tailItem);
  }
  return null;
}

/// 解析改借期句式。
///
/// 支持三种（元宝口径）：
///  * 「梯子借期改成 5 天」「梯子借期延长到 7 天」→ 总天数设为 N；
///  * 「梯子再借 3 天」「梯子续借 3 天」→ 在当前借期上追加 N 天。
/// 「缩短」暂不支持（没有催还机制，支持了也无效）。
ParseDueChange? _parseDueChange(String text) {
  final isExtendBy = text.contains('再借') ||
      text.contains('续借') ||
      text.contains('多借');
  final hasDueWord =
      _dueMarkers.any((m) => text.contains(m)) || isExtendBy;
  if (!hasDueWord) return null;

  final dayMatch =
      RegExp(r'(\d+|[一两二三四五六七八九十]+)\s*天').firstMatch(text);
  if (dayMatch == null) return null;
  final raw = dayMatch.group(1)!;
  final days = int.tryParse(raw) ?? _cnNumbers[raw];
  if (days == null || days < 1) return null;

  // 剥掉天数与各类修饰词，剩下的就是「谁的东西」。
  var rest = text.replaceAll(dayMatch.group(0)!, ' ');
  for (final kw in _dueKeywords) {
    rest = rest.replaceAll(kw, ' ');
  }
  rest = rest.replaceAll(RegExp(r'[\s，,。.、]'), '').trim();

  String? borrower;
  String? item;
  if (rest.isEmpty) {
    item = null; // 「借期改成5天」——没指名，交给 UI 按候选收敛。
  } else {
    final deIdx = rest.indexOf('的');
    if (deIdx > 0) {
      final head = rest.substring(0, deIdx);
      final tail = rest.substring(deIdx + 1);
      if (tail.isEmpty) {
        item = normalizeName(head); // 「梯子的借期…」——没有借阅人。
      } else {
        borrower = normalizeName(head);
        item = normalizeName(tail);
      }
    } else {
      item = normalizeName(rest);
    }
  }
  if (item != null && item.isEmpty) item = null;

  return ParseDueChange(
    days: days,
    item: item,
    borrower: borrower,
    mode: isExtendBy ? DueChangeMode.extendBy : DueChangeMode.set,
  );
}

/// 把一句中文口语解析成结构化意图。
///
/// 纯函数：只接收一个 String，只调用 [normalizeName]，不碰仓储、数据库、UI。

/// 归一化在入口与出口各强制执行一次，出口字段不依赖「入口已归一」的隐含前提。
///
/// V3 交互说明：在 V1/V2 基础上扩展
///  * 放置动词：放/搁/塞/摆/收/存/归；
///  * 查询词：在哪/哪里/在哪儿/在哪里、找/有没有、显式「查：」；
///  * 显式前缀「记：」「查：」。
/// 所有 V1/V2 语序防线（语气词只剥一层、倒装只剥一层、动词数恰好 1、
/// 介词吞并防污染）保持不变。
ParseResult parsePhrase(String input) {
  var text = normalizeName(input);
  if (text.isEmpty) return const ParseUnrecognized();

  // V3 显式前缀：「记：」强制录入，「查：」强制查询。
  if (text.startsWith(_recordPrefix)) {
    final rest = _stripTrailingParticle(
        text.substring(_recordPrefix.length).trim());
    if (rest.isEmpty) return const ParseUnrecognized();
    // 先剥数量（"记：2个梯子放阳台" → quantity=2），再解析句式。
    final q = _extractLeadingQuantity(rest);
    if (q != null) {
      final withQty = _parseRecord(q.rest);
      if (withQty != null) {
        return ParseUpsert(item: withQty.item, location: withQty.location,
            quantity: q.value);
      }
    }
    final parsed = _parseRecord(rest);
    if (parsed != null) return parsed;
    return const ParseUnrecognized();
  }
  if (text.startsWith(_queryPrefixMark)) {
    final rest =
        text.substring(_queryPrefixMark.length).trim();
    if (rest.isEmpty) return const ParseUnrecognized();
    return ParseQuery(item: normalizeName(_stripTrailingParticle(rest)));
  }

  if (_endsWithParticle(text)) {
    text = text.substring(0, text.length - 1).trim();
  }
  if (text.isEmpty || _endsWithParticle(text)) {
    return const ParseUnrecognized();
  }

  // ===== V3.9 语音化第一批：守卫优先级 =====
  // 改借期 → 废弃 → 恢复 → 借出 → 归还 → 查询 → 录入 → 未识别
  //
  // 为什么改借期排最前：「梯子借期改成5天」含「借」，若先跑借出分支，
  // 会被切成 borrower=梯子 / item=期改成5天 的乱账。
  // 为什么废弃排借出之前：「借给张三的梯子不要了」含借出动词。
  // 为什么恢复排录入之前：「梯子放回明细」含放置动词「放」，
  // 放给录入分支会变成「把梯子放到'回明细'」这种垃圾位置。
  final due = _parseDueChange(text);
  if (due != null) return due;
  final discard = _parseDiscard(text);
  if (discard != null) return discard;
  final restore = _parseRestore(text);
  if (restore != null) return restore;

  // V3.7：借/还语义优先于录入。解析函数内部已排除含放置动词的录入句
  // （如「借条放阳台」），以及查询句式由后续 query 分支兜底。
  final lend = _parseLend(text);
  if (lend != null) return lend;
  final ret = _parseReturn(text);
  if (ret != null) return ret;

  // 查询优先（后缀式与前缀式），命中即返回。
  final query = _parseQuery(text);
  if (query != null) return query;

  // 录入：先试前置数量（"2个梯子放阳台" → quantity=2），再试原样。
  final q = _extractLeadingQuantity(text);
  if (q != null) {
    final withQty = _parseRecord(q.rest);
    if (withQty != null) {
      return ParseUpsert(item: withQty.item, location: withQty.location,
          quantity: q.value);
    }
  }
  final record = _parseRecord(text);
  if (record != null) return record;

  // 未识别：给 UI 一个意图猜测（含"借"→lend，含"还"→return），供确认框展示。
  final guess = text.contains('借')
      ? 'lend'
      : (text.contains('还') ? 'return' : null);
  return ParseUnrecognized(guess: guess);
}
