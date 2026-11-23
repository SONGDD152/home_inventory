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
class ParseReturn extends ParseResult {
  const ParseReturn({required this.item, this.quantity});

  final String item;

  /// 归还数量；null 表示全部归还。
  final int? quantity;
}

/// 未识别：不符合允许的句式模板。
/// [guess] 为可选意图猜测（'lend'/'return'/null），供 UI 确认框使用。
class ParseUnrecognized extends ParseResult {
  const ParseUnrecognized({this.guess});

  /// 'lend' / 'return' / null（无猜测）。
  final String? guess;
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
/// 支持三种自然口语（数量/天数均可省略）：
///  * 借给张三2个梯子 / 借给张三梯子（「给」字句，人到「给」后、物到「给」前）
///  * 张三借了2个梯子 / 张三借梯子（人+借动词）
///  * 借2个梯子给张三（物在「借」后、「给」前，人在「给」后）
ParseLend? _parseLend(String text) {
  if (!text.contains('借')) return null;

  // 形态1「借给」：句式 = 借给 + <人> + <数量物品> + [天数]
  // 人/物无显式分隔，靠数量切分："借给张三2个梯子" → 人=张三、物=梯子、数量=2。
  if (text.startsWith('借给')) {
    var tail = text.substring(2).trim(); // "张三2个梯子" / "张三5天梯子"
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
    // 形态2：借<数量><物品>给<人>(借2个梯子给张三)
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
    var itemPart = head.startsWith('借') ? head.substring(1).trim() : head;
    var quantity = 1;
    final q = _extractLeadingQuantity(itemPart);
    if (q != null && q.rest.isNotEmpty) {
      quantity = q.value;
      itemPart = q.rest;
    }
    final item = normalizeName(_stripTrailingParticle(itemPart));
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

/// 解析归还句式。支持：还了2个梯子 / 还梯子 / 归还梯子给张三。
ParseReturn? _parseReturn(String text) {
  for (final marker in _returnMarkers) {
    if (!text.startsWith(marker)) continue;
    var rest = text.substring(marker.length).trim();
    if (rest.isEmpty) continue;
    int? quantity;
    final q = _extractLeadingQuantity(rest);
    if (q != null && q.rest.isNotEmpty) {
      quantity = q.value;
      rest = q.rest;
    }
    // 去掉尾部 "给某人"（归还对象借出时已记在 loan 上，这里只取物品）。
    final giveIdx = rest.indexOf('给');
    if (giveIdx > 0) rest = rest.substring(0, giveIdx).trim();
    final item = normalizeName(_stripTrailingParticle(rest));
    if (item.isEmpty) continue;
    return ParseReturn(item: item, quantity: quantity);
  }
  return null;
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
