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
  const ParseUpsert({
    required this.item,
    required this.location,
    this.quantity = 1,
    this.additive = false,
    this.isMove = false,
    this.hasQuantity = false,
  });

  final String item;
  final String location;

  /// V3.11（元宝批复第 1 条）：这句话的动词是不是「挪」。
  /// 放置动词（放/搁/塞/摆/收/存/归）= 录入到某位置，只动目标位；
  /// 「挪」= 挪位，整体挪或部分挪。UI 据此分流到不同数据层方法，
  /// 不靠 quantity 是否为 null 判断。
  final bool isMove;

  /// V3.11：句子里是否**显式**说了数量（「把1个梯子挪到客厅」=true，
  /// 「把梯子挪到客厅」=false）。带数量的挪位走部分挪、不带数的走整体挪。
  final bool hasQuantity;

  /// V3.7：录入数量（"记：2个梯子放阳台" → 2），默认 1。
  final int quantity;

  /// V3.10：**累加语义**标记（PM 补充要求1）。
  ///
  /// false = 覆盖（默认）：说「3个梯子」是在纠正数量，直接覆盖原值
  /// （PM 拍板③）。
  /// true = 累加：「再放2个梯子」「又多了3个」这类说法是在补充，
  /// 数量 += N 而不是覆盖。
  final bool additive;

  /// V3.10：累加语义下**允许没有位置**。
  ///
  /// 「再放2个梯子」「又多了2个梯子」说的是"又添了几个"，东西本来就在
  /// 某处，不必重复说位置。location 为空串时，UI 层**只改数量、不挪位**，
  /// 沿用物品原有位置关联。
  bool get hasLocation => location.isNotEmpty;
}

/// 查询意图：<物品>在哪
class ParseQuery extends ParseResult {
  const ParseQuery({required this.item});

  final String item;
}

/// 查数量意图（PM 2026-11-25 真机新增）：「梯子有几个」→ 回在库/在借/一共。
///
/// 与 [ParseQuery]（查位置）分开：查数量走 getQuantityInfo 回三口径，
/// 查位置走 findByName 回位置列表。
class ParseQuantityQuery extends ParseResult {
  const ParseQuantityQuery({required this.item});

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
  const ParseDiscard({required this.item, this.borrower, this.quantity});

  final String item;

  /// 句中指名的借阅人（「借给王五的梯子废弃了」→ 王五）；没指名为 null。
  ///
  /// V3.9.2：指名时只废弃该借阅人那一笔借出，不连带销掉别人的账。
  final String? borrower;

  /// V3.12：废弃几个。null = 整件废弃（老行为，物品整条进回收站）；
  /// 有值 = 部分废弃（只废这几个，其余留在明细里）。
  final int? quantity;
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

/// V3.10：解析「又多了N个X」「再添N个X」这类**无位置**的累加表述。
///
/// 这类句子不含放置动词（「放/搁/塞…」），走 [_parseRecord] 会因
/// 找不到动词而落空。但语义很清楚：物品已经在某处，又添了 N 个——
/// 只改数量、不挪位。
///
/// 返回 null 表示不匹配（非累加表述，或没有数量）。
ParseUpsert? _parseAdditiveNoLocation(String text) {
  var rest = text.trim();
  // 剥累加前缀（「又」/「再」）。
  final additive = _extractAdditivePrefix(rest);
  if (!additive.isAdditive) return null;
  rest = additive.rest;
  // 剥「多了/添了/多了些/来」等描述词。
  for (final w in const <String>['多了', '添了', '多出', '增加', '来']) {
    if (rest.startsWith(w)) {
      rest = rest.substring(w.length).trim();
      break;
    }
  }
  // 剥掉尾随的「了」（「又来了2个梯子」）。
  if (rest.startsWith('了')) {
    rest = rest.substring(1).trim();
  }
  if (rest.isEmpty) return null;
  // 必须带数量，否则不是「又添了几个」的说法。
  final q = _extractLeadingQuantity(rest);
  if (q == null || q.rest.isEmpty) return null;
  final item = q.rest.trim();
  if (item.isEmpty) return null;
  // 物品名不能带位置词（「梯子阳台」不是物品名）——交给下游校验，
  // 这里只做最基本的长度与字符检查。
  if (item.length > 20) return null;
  return ParseUpsert(
    item: normalizeName(item),
    location: '',
    quantity: q.value,
    additive: true,
  );
}

/// V3.10：解析「3个梯子」这种**只带数量、不带位置也不带动词**的说法。
///
/// 语义（PM 拍板③）：普通说法 = 纠正数量，直接覆盖——只改数量、不挪位。
/// 累加说法（「又多了2个梯子」）由 [_parseAdditiveNoLocation] 兜住。
///
/// 必须带量词（个/本/把/件/只/张）才认，避免把「5号电池」当成
/// 「5 个 号电池」——那样物品名会被数量污染。
ParseUpsert? _parseQuantityOnly(String text) {
  final t = text.trim();
  final m = RegExp(r'^(\d+)\s*[个本把件只张]\s*(.+)$').firstMatch(t);
  if (m == null) return null;
  final value = int.tryParse(m.group(1)!);
  if (value == null || value < 1) return null;
  final item = m.group(2)!.trim();
  if (item.isEmpty || item.length > 20) return null;
  // 物品名里不能有放置动词——有动词的句子归录入分支管。
  for (var i = 0; i < item.length; i++) {
    if (_placeVerbs.contains(item.substring(i, i + 1))) return null;
  }
  return ParseUpsert(item: normalizeName(item), location: '', quantity: value);
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
  var core = _stripBaPrefix(text);
  if (core.isEmpty || !_isValidWordOrder(core)) return null;

  // V3.10：前置数量（「3个梯子放阳台」）在**切动词之前**剥掉——
  // 否则「个」这类量词里的字可能干扰动词定位，且数量会丢失。
  var qty = 1;
  var hasExplicitQty = false; // V3.11：句子里是否显式说了数量。
  final leadQty = _extractLeadingQuantity(core);
  if (leadQty != null && leadQty.rest.isNotEmpty) {
    qty = leadQty.value;
    hasExplicitQty = true;
    core = leadQty.rest;
    if (core.isEmpty || !_isValidWordOrder(core)) return null;
  }

  int? verbIndex;
  for (var i = 0; i < core.length; i++) {
    if (_placeVerbs.contains(core.substring(i, i + 1))) {
      verbIndex = i;
      break;
    }
  }
  if (verbIndex == null || verbIndex == core.length - 1) {
    return null;
  }

  // V3.10：支持「动词在前」的形式——「放2个梯子在阳台」「再放2个梯子」。
  // 形式为：动词[介词][数量][物品][介词][位置]。
  // 物品名在「物品+动词+位置」语序里位于动词之前；这里反之。
  // V3.11：动词是不是「挪」——放置动词（放/搁/塞/…）= 录入；
  // 「挪」= 挪位（整体/部分），UI 据此分流到不同数据层方法。
  final isMoveVerb = core.substring(verbIndex, verbIndex + 1) == '挪';

  if (verbIndex == 0) {
    var body = core.substring(1).trim();
    // 剥动词后的助词「了」：「又放了3个梯子」→「3个梯子」。
    if (body.startsWith('了')) body = body.substring(1).trim();
    // 剥动词后的介词（放在/放到）。
    if (_isPreposition(body)) body = body.substring(1).trim();
    // 前置数量：「2个梯子」→ 数量 2、余下「梯子」。
    final q = _extractLeadingQuantity(body);
    var bodyQty = 1;
    var bodyHasQty = false;
    var rest = body;
    if (q != null && q.rest.isNotEmpty) {
      bodyQty = q.value;
      bodyHasQty = true;
      rest = q.rest;
    }
    // PM 真机打回（V3.10 复验）：语音常把数量说在物品后面——
    // 「再放梯子3个在阳台」「放梯子三个到阳台」。这里物品名尾部会残留
    // 数量，若不剥掉会建成「梯子3个」这种新物品（明细莫名其妙多一行）。
    // 与 V3.9.1「梯子借」、本版 Bug②「5号电池」同源——物品名不许带数量。
    final trailing = _extractTrailingQuantity(rest);
    if (trailing != null && trailing.rest.isNotEmpty) {
      bodyQty = trailing.value;
      bodyHasQty = true;
      rest = trailing.rest;
    }
    rest = rest.trim();
    if (rest.isEmpty) return null;
    // 余下部分可能是「梯子在阳台」（物品+介词+位置）或
    // 「梯子放阳台」（物品+动词+位置）——后者用同一套切词逻辑处理。
    final inner = _parseRecord(rest);
    if (inner != null) {
      return ParseUpsert(
        item: inner.item,
        location: inner.location,
        quantity: bodyQty,
        isMove: isMoveVerb || inner.isMove,
        hasQuantity: bodyHasQty || inner.hasQuantity,
      );
    }
    // 「梯子在阳台」形式：按介词切。
    final locMatch = RegExp(r'^(.+?)(?:在|到|往|向)(.+)$').firstMatch(rest);
    if (locMatch != null) {
      var itemPart = locMatch.group(1)!.trim();
      final locPart = locMatch.group(2)!.trim();
      if (itemPart.isNotEmpty && locPart.isNotEmpty) {
        // 「再放梯子3个在阳台」：数量夹在物品与介词之间，
        // 切完位置后物品名是「梯子3个」——必须把尾部数量剥出来。
        final tail = _extractTrailingQuantity(itemPart);
        if (tail != null && tail.rest.isNotEmpty) {
          bodyQty = tail.value;
          bodyHasQty = true;
          itemPart = tail.rest;
        }
        return ParseUpsert(
          item: normalizeName(itemPart),
          location: normalizeName(locPart),
          quantity: bodyQty,
          isMove: isMoveVerb,
          hasQuantity: bodyHasQty,
        );
      }
    }
    // 没有位置——「放2个梯子」缺位置信息，不算完整录入句。
    return null;
  }

  var item = core.substring(0, verbIndex).trim();
  var location = core.substring(verbIndex + 1).trim();
  if (_isPreposition(location)) {
    location = location.substring(1).trim();
  }
  if (item.isEmpty || location.isEmpty || _isPreposition(location)) {
    return null;
  }
  // PM 真机打回（V3.10 复验）：数量说在物品后面——「梯子3个放阳台」。
  // 不剥会建成「梯子3个」新物品，明细多出一行。数量后置是常见口语，
  // 用与借出侧同源的 _extractTrailingQuantity（支持中文数字）。
  final trailing = _extractTrailingQuantity(item);
  if (trailing != null && trailing.rest.isNotEmpty) {
    qty = trailing.value;
    hasExplicitQty = true;
    item = trailing.rest;
  }
  return ParseUpsert(
    item: normalizeName(item),
    location: normalizeName(location),
    quantity: qty,
    isMove: isMoveVerb,
    hasQuantity: hasExplicitQty,
  );
}

/// 解析「查数量」句式（PM 2026-11-25 真机新增）：
///  * 后缀式：梯子有几个 / 梯子多少 / 梯子还有几个 / 梯子在借几个 / 梯子一共几个
///  * 前缀式：有几个梯子 / 多少梯子
///  * 「数量」式：梯子数量
///
/// 必须与位置查询 [ParseQuery] 分开，且守卫排在归还之前——
/// 「梯子还有几个」含「还」字，若不先拦会被归还分支抢答（同 V3.9
/// 「借期」含「借」被借出抢答的教训）。
ParseQuantityQuery? _parseQuantityQuery(String text) {
  // 后缀：数量疑问词结尾。长词优先，先「一共几个」再「还有几个」。
  const suffixes = <String>[
    '一共几个', '总共有几个', '总共几个', '共有几个',
    '还有几个', '还剩几个', '在借几个', '借出几个',
    '有几个', '多少', '几件', '几本',
  ];
  for (final suffix in suffixes) {
    if (!text.endsWith(suffix)) continue;
    var head = text.substring(0, text.length - suffix.length).trim();
    // 「梯子还有几个」→ head=梯子；「梯子在借几个」→ head=梯子。
    // 但「一共/还有/在借」这类前缀词若粘在物品上要剥掉（防御）。
    const leadWords = <String>['一共', '总共', '还有', '还剩', '在借', '借出'];
    for (final w in leadWords) {
      if (head.endsWith(w)) {
        head = head.substring(0, head.length - w.length).trim();
        break;
      }
    }
    if (head.isNotEmpty) return ParseQuantityQuery(item: normalizeName(head));
  }
  // 前缀式：有几个梯子 / 多少梯子。
  const prefixes = <String>['有几个', '多少', '总共有'];
  for (final prefix in prefixes) {
    if (text.startsWith(prefix)) {
      final item = text.substring(prefix.length).trim();
      if (item.isNotEmpty) {
        return ParseQuantityQuery(item: normalizeName(item));
      }
    }
  }
  // 「梯子数量」「梯子几件」这类显式名词后缀。
  const nounSuffixes = <String>['数量', '个数'];
  for (final suffix in nounSuffixes) {
    if (text.endsWith(suffix) && text.length > suffix.length) {
      return ParseQuantityQuery(
          item: normalizeName(text.substring(0, text.length - suffix.length)));
    }
  }
  return null;
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

/// 剥掉片段**尾部**的借出动词：「梯子借」→「梯子」。
///
/// V3.9.1 真机打回（PM 场景②）：口语里「物品 + 借 + 给/走 + 人」很常见
/// ——「梯子借给张三」。旧解析器只认「动词在前」的语序（借2个梯子给张三），
/// 遇到「梯子借给张三」时 head 切出来是「梯子借」，借出动词「借」被留在了
/// 物品名里 → 物品被建成「梯子借」，借出记录也挂在这个脏名上，
/// 之后说「梯子借期改成5天」按「梯子」就再也查不到那条记录。
///
/// 只剥词尾动词，剥完为空（片段本身就是「借」）时返回原名。
String _stripLendVerbSuffix(String text) {
  var rest = text.trim();
  if (rest.isEmpty) return rest;
  for (final marker in _lendMarkers) {
    if (!rest.endsWith(marker)) continue;
    final head = rest.substring(0, rest.length - marker.length).trim();
    if (head.isEmpty) break;
    rest = head;
    break;
  }
  return rest;
}

/// 从片段**尾部**剥出数量：「张三1个」→ (1, "张三")。
///
/// 用于「梯子借给张三1个」这种「数量跟在人后面」的口语。
({int value, String rest})? _extractTrailingQuantity(String text) {
  final m = RegExp(
          r'(\d+|[一两二三四五六七八九十]+)\s*[个本把件只张]\s*$')
      .firstMatch(text);
  if (m == null) return null;
  final value = int.tryParse(m.group(1)!) ?? _cnNumbers[m.group(1)!];
  if (value == null || value < 1) return null;
  return (value: value, rest: text.substring(0, m.start).trim());
}

/// 剥掉物品名周围表示「借出状态」的修饰语。
///
/// V3.9.1 真机打回（PM 场景②）：说「借给张三的梯子废弃了」时，
/// 旧解析器把「借给张三的」当成了物品名的一部分 → 物品名 = 「借给张三的梯子」，
/// 查库自然找不到，PM 看到的是"没有找到「借给张三的梯子」"。
///
/// 处理后：
///  * 前缀「借给张三的」「被张三借走的」「张三借走的」「借出的」「借的」→ 剥掉；
///  * 尾部「借给张三的」「借走的」「借出的」「借的」→ 剥掉。
///
/// 「借书」「借款单」这类真名不受影响——只匹配「借 + 走/出/了/的/给…」这类
/// 明确的动词组合。
String _stripLendModifier(String text) {
  var s = text.trim();
  if (s.isEmpty) return s;

  final prefixPatterns = <RegExp>[
    RegExp(r'^借给[^的]*的'), // 借给张三的
    RegExp(r'^被[^的]*借走的'), // 被张三借走的
    RegExp(r'^[^的]*借走的'), // 张三借走的
    RegExp(r'^借走的'),
    RegExp(r'^借出的'),
    RegExp(r'^借的'),
  ];
  final suffixPatterns = <RegExp>[
    RegExp(r'借给[^的]*的$'), // 梯子借给张三的
    RegExp(r'借走的$'),
    RegExp(r'借出的$'),
    RegExp(r'借的$'),
  ];

  bool changed = true;
  while (changed) {
    changed = false;
    for (final p in prefixPatterns) {
      final m = p.firstMatch(s);
      // 不允许剥到空（m.end == s.length 说明整串都是修饰语，无物品名）。
      if (m != null && m.end < s.length) {
        s = s.substring(m.end).trim();
        changed = true;
        break;
      }
    }
    if (changed) continue;
    for (final p in suffixPatterns) {
      final m = p.firstMatch(s);
      if (m != null && m.start > 0) {
        s = s.substring(0, m.start).trim();
        changed = true;
        break;
      }
    }
  }
  return s;
}

/// 从借出修饰语里摘出借阅人：「借给王五的」→「王五」、「被张三借走的」→「张三」。
///
/// V3.9.2：摘人名与 [_stripLendModifier] 剥修饰语必须成对使用——
/// 只剥不留就会把「王五」连同修饰语一起丢掉，用户指名了谁就再也分不清。
/// 返回 null 表示句中没指名借阅人。
String? _extractModifierPerson(String text) {
  final give = RegExp(r'借给([^的]+)').firstMatch(text);
  final take = RegExp(r'被?([^的]*?)借走的').firstMatch(text);
  final giveName = give?.group(1)?.trim();
  final takeName = take?.group(1)?.trim();
  if (giveName != null && giveName.isNotEmpty) return normalizeName(giveName);
  if (takeName != null && takeName.isNotEmpty) return normalizeName(takeName);
  return null;
}

/// 中文数字 → 整数。仅覆盖 1-20（家庭场景够用）。
const Map<String, int> _cnNumbers = <String, int>{
  '一': 1, '两': 2, '二': 2, '三': 3, '四': 4, '五': 5,
  '六': 6, '七': 7, '八': 8, '九': 9, '十': 10,
  '十一': 11, '十二': 12, '十三': 13, '十四': 14, '十五': 15,
  '十六': 16, '十七': 17, '十八': 18, '十九': 19, '二十': 20,
};

/// 从文本头部剥出数量（"2个梯子" → (2, "梯子")；"两个梯子" 同）。
///
/// 识别阿拉伯数字与中文数字，量词 个/本/把/件/只/张 跟在数字后面。
///
/// **量词是必需的**（V3.10 修）：原来量词可选，"5号电池" 会被切成
/// 「5 个 号电池」——物品名被数量污染，之后按「电池」永远查不到它
/// （V3.9.2「物品名必须干净」的教训，同一个坑）。
/// 数字后没有量词就不当数量，物品名保持原样。
({int value, String rest})? _extractLeadingQuantity(String text) {
  // 阿拉伯数字（量词必需）。
  final arabic = RegExp(r'^(\d+)\s*([个本把件只张])\s*').firstMatch(text);
  if (arabic != null) {
    final value = int.tryParse(arabic.group(1)!);
    if (value != null && value >= 1) {
      return (value: value, rest: text.substring(arabic.end).trim());
    }
  }
  // 中文数字（长词优先：十一 先于 一），量词同样必需。
  final keys = _cnNumbers.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final key in keys) {
    if (!text.startsWith(key)) continue;
    var rest = text.substring(key.length).trim();
    if (rest.isEmpty) continue;
    if (!'个本把件只张'.contains(rest.substring(0, 1))) continue;
    rest = rest.substring(1).trim();
    return (value: _cnNumbers[key]!, rest: rest);
  }
  return null;
}

/// V3.10：识别累加前缀（PM 补充要求1）。
///
/// 覆盖是默认口径（PM 拍板③）：说「3个梯子」= 纠正数量，直接覆盖。
/// 但用户也需要一条累加路径——「再放2个梯子」「又多了3个」说的是
/// **又添了几个**，语义是累加而非覆盖。
///
/// 返回 (isAdditive, rest)：命中累加词时剥掉它并标记 true。
///
/// 词表要窄：只认「再/又/多」这类**明确表示增加**的词，且必须紧邻数量
/// 或物品名，避免误伤「还」这种在借还语境里高频的词（此处只处理录入分支，
/// 且要求后面还跟着数量或物品）。
const List<String> _additiveMarkers = <String>['又', '再', '多'];

/// 返回 (isAdditive, rest)。
({bool isAdditive, String rest}) _extractAdditivePrefix(String text) {
  var rest = text.trim();
  for (final marker in _additiveMarkers) {
    if (!rest.startsWith(marker)) continue;
    final after = rest.substring(marker.length).trim();
    // 剥掉「了/了有」这类助词：「又放了2个」→「2个」。
    var body = after;
    if (body.startsWith('了')) body = body.substring(1).trim();
    if (body.startsWith('有')) body = body.substring(1).trim();
    if (body.isEmpty) continue;
    // 后面必须还有实质内容（数量或物品），否则不认。
    rest = body;
    return (isAdditive: true, rest: rest);
  }
  return (isAdditive: false, rest: rest);
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
    // 口语尾巴的语气词（"借给张三吧"）不能粘进人名。
    tail = _stripTrailingParticle(tail);
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
    // V3.9.1：也覆盖「物品 + 借 + 给 + 人」（梯子借给张三）——此时 head 尾巴
    // 带着借出动词，必须剥掉，否则物品名被建成「梯子借」（真机打回场景②）。
    final head = text.substring(0, giveIdx).trim(); // "借2个梯子" / "梯子借"
    var tail = text.substring(giveIdx + 1).trim(); // "张三" / "张三1个"
    if (tail.isEmpty) return null;
    // 口语尾巴的语气词（"梯子借给张三吧"）不能粘进人名。
    tail = _stripTrailingParticle(tail);
    if (tail.isEmpty) return null;
    // 「数量跟在人后面」：梯子借给张三1个 → 数量=1、人=张三。
    var tailQuantity = 1;
    final tailQty = _extractTrailingQuantity(tail);
    if (tailQty != null && tailQty.rest.isNotEmpty) {
      tailQuantity = tailQty.value;
      tail = tailQty.rest;
    }
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
    var itemPart = _stripLendVerbPrefix(head);
    // V3.9.1：再剥尾部借出动词——「梯子借」→「梯子」。
    itemPart = _stripLendVerbSuffix(itemPart);
    // 「把梯子借给张三」——把字句的"把"不能留在物品名里。
    itemPart = _stripBaPrefix(itemPart);
    var quantity = 1;
    var rest2 = itemPart;
    final q = _extractLeadingQuantity(rest2);
    if (q != null && q.rest.isNotEmpty) {
      quantity = q.value;
      rest2 = q.rest;
    }
    // 尾部数量（跟在人后面）仅在物品本身没给数量时采用。
    if (quantity == 1 && tailQuantity > 1) quantity = tailQuantity;
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
  // V3.12：坏掉的说法也算废弃（「梯子坏了1个」= 废 1 个）。
  // 「坏」也要收：parsePhrase 会先剥句尾助词「了」，
  // 「梯子坏了」进来时已经是「梯子坏」，只认「坏了」会漏。
  '坏掉了', '坏了', '坏',
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
  // V3.9.1：剥掉借出修饰语——「借给张三的梯子废弃了」→ 物品名应是「梯子」，
  // 不能是「借给张三的梯子」（真机打回场景②的根因）。
  // V3.9.2：剥之前先摘出借阅人——「借给王五的梯子废弃了」指名了王五，
  // UI 才能只还他那一笔，不连带清零李四张三的账（PM 真机复验新缺陷）。
  final modifierPerson = _extractModifierPerson(head);
  head = _stripLendModifier(head);

  // V3.12：数量可能在动词**前面**——「把1个梯子废弃了」。
  // 不剥会把「1个」粘进物品名（建成「1个梯子」这种新物品，明细多一行）。
  int? quantity;
  final headQty = _extractLeadingQuantity(head);
  if (headQty != null && headQty.rest.isNotEmpty) {
    quantity = headQty.value;
    head = headQty.rest;
  }

  var tail = text.substring(markerIdx + marker.length).trim();
  tail = _stripTrailingParticle(tail);

  // V3.12：数量也可能在动词**后面**——「梯子报废1个」「废弃1个梯子」。
  // 原来这里一律当"动词后还有东西 = 歧义"，导致「梯子不要了1个」报歧义。
  var tailRest = tail;
  final tailQty = _extractDiscardQuantity(tail);
  if (tailQty != null) {
    quantity ??= tailQty.value;
    tailRest = tailQty.rest;
    // 「废弃1个梯子」：动词前没有物品名，物品名在数量后面。
    if (head.isEmpty && tailRest.isNotEmpty) {
      head = tailRest;
      tailRest = '';
    }
  }

  final item = normalizeName(_stripTrailingParticle(head));
  if (item.isEmpty) return null; // 「不要了」这类没有物品名的句子不是废弃句。

  if (tailRest.isEmpty) {
    return ParseDiscard(item: item, borrower: modifierPerson, quantity: quantity);
  }

  // 单字丢弃动词（扔/丢）后面还带东西 → 是"放到某处"不是丢弃，
  // 例如「梯子扔阳台」。这层不认废弃，交给后面的放置/未识别分支，
  // 保持 V1「精确模板之外一律未识别」的老口径不被扩大。
  if (marker == '扔' || marker == '丢') return null;

  // 动词后面还有内容 → 报歧义：既可能是「放弃这件东西」，也可能是
  // 「放到某个位置」。
  final location = _extractPlacementLocation(tailRest);
  final candidates = <ParseResult>[
    ParseDiscard(item: item, borrower: modifierPerson, quantity: quantity),
  ];
  if (location != null) {
    candidates.add(ParseUpsert(item: item, location: normalizeName(location)));
  }
  return ParseAmbiguous(
    candidates: candidates,
    hint: '「$item」这句有两种理解：'
        '${location != null ? '放到$location，或' : ''}把它转入回收站？',
  );
}

/// V3.12：废弃句里的数量（阿拉伯 + 中文数字，量词 个/本/把/件/只/张）。
///
/// 与 [_extractLeadingQuantity] 的差别：中文数字后面**不再要求有字**
/// （「梯子报废一个」也算数），而 [_extractLeadingQuantity] 在录入场景
/// 需要后面的物品名，所以那里保持"必须有字"的老口径不动。
({int value, String rest})? _extractDiscardQuantity(String text) {
  final direct = _extractLeadingQuantity(text);
  if (direct != null) return direct;
  final keys = _cnNumbers.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final key in keys) {
    if (!text.startsWith(key)) continue;
    var rest = text.substring(key.length).trim();
    if (rest.isEmpty) continue;
    if (!'个本把件只张'.contains(rest.substring(0, 1))) continue;
    rest = rest.substring(1).trim();
    return (value: _cnNumbers[key]!, rest: rest);
  }
  return null;
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
    var head = _stripBaPrefix(text.substring(0, idx).trim());
    // V3.9.1：剥借出修饰语——「把借给张三的梯子恢复」→ 物品名是「梯子」。
    head = _stripLendModifier(head);
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
    final tailItem = normalizeName(_stripTrailingParticle(_stripLendModifier(tail)));
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

  // V3.9.1：借出修饰语里可能藏着借阅人——「借给张三的梯子借期改成5天」。
  // 先把人名摘出来，再把修饰语整段剥掉，物品名才干净。
  // V3.9.2：与废弃分支共用 [_extractModifierPerson]，避免两套正则走偏。
  final modifierPerson = _extractModifierPerson(rest);
  rest = _stripLendModifier(rest);

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
  // 修饰语里摘出的借阅人优先（比「X的Y」切分更可靠：
  // 「借给张三的梯子」里「张三」不是物品的一部分）。
  if (borrower == null && modifierPerson != null && modifierPerson.isNotEmpty) {
    borrower = normalizeName(modifierPerson);
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
    // V3.10：先剥累加前缀（「记：再放2个梯子」→ additive=true）。
    final additive = _extractAdditivePrefix(rest);
    final restForQty = additive.rest;
    // 数量提取统一交给 [_parseRecord] 内部（见主录入路径的同名注释）。
    final parsed = _parseRecord(restForQty);
    if (parsed != null) {
      return ParseUpsert(
          item: parsed.item,
          location: parsed.location,
          quantity: parsed.quantity,
          additive: additive.isAdditive,
          isMove: parsed.isMove,
          hasQuantity: parsed.hasQuantity);
    }
    return const ParseUnrecognized();
  }
  if (text.startsWith(_queryPrefixMark)) {
    final rest =
        text.substring(_queryPrefixMark.length).trim();
    if (rest.isEmpty) return const ParseUnrecognized();
    // V3.10（元宝审核补充②）：「查：梯子有几个」走数量查询，
    // 与「查：梯子在哪」（位置查询）分流，别留半截功能。
    final qty = _parseQuantityQuery(rest);
    if (qty != null) return qty;
    return ParseQuery(item: normalizeName(_stripTrailingParticle(rest)));
  }

  if (_endsWithParticle(text)) {
    text = text.substring(0, text.length - 1).trim();
  }
  if (text.isEmpty || _endsWithParticle(text)) {
    return const ParseUnrecognized();
  }

  // ===== V3.9 语音化第一批：守卫优先级 =====
  // 查数量 → 改借期 → 废弃 → 恢复 → 借出 → 归还 → 查询 → 录入 → 未识别
  //
  // 查数量排最前：「梯子还有几个」含「还」会被归还抢答，
  // 「梯子借出几个」含「借」会被借出抢答——先拦下来再说。
  final qtyQuery = _parseQuantityQuery(text);
  if (qtyQuery != null) return qtyQuery;
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
  // V3.10：先剥累加前缀（「再放2个梯子」→ additive=true，语义是又添了2个）。
  final additive = _extractAdditivePrefix(text);
  final textForQty = additive.rest;
  // V3.10：数量提取统一交给 [_parseRecord] 内部完成（它已能处理
  // 「数量+物品+动词+位置」与「动词+数量+物品+位置」两种语序）。
  // 外层不再单独剥数量，否则 [_parseRecord] 会看不到数量而静默丢成 1。
  final record = _parseRecord(textForQty);
  if (record != null) {
    return ParseUpsert(
        item: record.item,
        location: record.location,
        quantity: record.quantity,
        additive: additive.isAdditive,
        isMove: record.isMove,
        hasQuantity: record.hasQuantity);
  }

  // V3.10：无位置的累加表述（「又多了2个梯子」）——不含放置动词，
  // 走上面的录入分支会落空，这里单独兜住：只改数量、不挪位。
  final noLoc = _parseAdditiveNoLocation(text);
  if (noLoc != null) return noLoc;

  // V3.10：只带数量的表述（「3个梯子」）——纠正数量，只改数量、不挪位。
  final qtyOnly = _parseQuantityOnly(text);
  if (qtyOnly != null) return qtyOnly;

  // 未识别：给 UI 一个意图猜测（含"借"→lend，含"还"→return），供确认框展示。
  final guess = text.contains('借')
      ? 'lend'
      : (text.contains('还') ? 'return' : null);
  return ParseUnrecognized(guess: guess);
}
