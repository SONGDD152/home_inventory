import 'normalize.dart';

/// 句式解析结果（密封类型，三态）。
sealed class ParseResult {
  const ParseResult();
}

/// 录入意图：<物品>放<位置>
class ParseUpsert extends ParseResult {
  const ParseUpsert({required this.item, required this.location});

  final String item;
  final String location;
}

/// 查询意图：<物品>在哪
class ParseQuery extends ParseResult {
  const ParseQuery({required this.item});

  final String item;
}

/// 未识别：不符合允许的句式模板。
class ParseUnrecognized extends ParseResult {
  const ParseUnrecognized();
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
/// V3 交互说明再扩「收/存/归」（收阳台/存阳台/归阳台）。
const List<String> _placeVerbs = <String>['放', '搁', '塞', '摆', '收', '存', '归'];

/// 动词词干后可紧跟的介词。整体上「放到/放在/搁到/塞往…」视为一个动词短语，
/// 介词并入动词吞掉，位置取介词之后的干净片段。
const List<String> _prepositions = <String>['到', '在', '往', '向', '给', '至'];

/// 倒装「把」字句的显式主语（可省略）。
const List<String> _baSubjects = <String>['我', '你', '他'];

bool _endsWithParticle(String text) {
  if (text.isEmpty) return false;
  return _trailingParticles.contains(text.substring(text.length - 1));
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
  // 后缀式：梯子在哪 / 梯子哪里
  for (final suffix in _querySuffixes) {
    if (text.endsWith(suffix)) {
      final item = text.substring(0, text.length - suffix.length).trim();
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
    final parsed = _parseRecord(rest);
    return parsed ?? const ParseUnrecognized();
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

  // 查询优先（后缀式与前缀式），命中即返回。
  final query = _parseQuery(text);
  if (query != null) return query;

  return _parseRecord(text) ?? const ParseUnrecognized();
}
