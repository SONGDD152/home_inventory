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
const String _querySuffix = '在哪';

/// V2 R1（方案 C）：放置动词词干。原 V1 仅认「放」，现扩展为四个高频动词。
const List<String> _placeVerbs = <String>['放', '搁', '塞', '摆'];

/// 动词词干后可紧跟的介词。整体上「放到/放在/搁到/塞往…」视为一个动词短语，
/// 介词并入动词吞掉，位置取介词之后的干净片段——不再用「位置以介词开头就拒绝」
/// 的黑名单（那个黑名单是穷举，且会把口语变体全挡掉）。
const List<String> _prepositions = <String>['到', '在', '往', '向', '给', '至'];

/// 倒装「把」字句的显式主语（可省略）。「把梯子放阳台」/「我把梯子放阳台」都认。
const List<String> _baSubjects = <String>['我', '你', '他'];

bool _endsWithParticle(String text) {
  if (text.isEmpty) return false;
  return _trailingParticles.contains(text.substring(text.length - 1));
}

bool _isPreposition(String text) {
  if (text.isEmpty) return false;
  return _prepositions.contains(text.substring(0, 1));
}

/// V2 审查需改点1（折中方案）：倒装剥离后的语序有效性校验。
///
/// 只拦规则层面能「确定非法」的语序：
///  - 放置动词出现次数必须恰好为 1：多动词连写（梯子放阳台放厨房）
///    或无动词（梯子在阳台）一律未识别；
///  - 倒装只剥一层：剥后核心句仍以「把」开头（我把把梯子放阳台）
///    判未识别，避免叠用倒装蒙混。
///
/// 明确「不拦」并在 CHANGELOG 如实列为已知限制：
///  - 单动词语义颠倒（阳台放梯子）：它与合法的「梯子放阳台」语法结构完全相同，
///    纯规则无词典、又不查已录入数据（纯函数不碰 DB），无从判断谁对谁错；
///  - 错位「把」字（阳台把梯子放厨房）：它与合法物品名「门把手放阳台」
///    语法结构相同，拦它必然误伤 C6 的规避命名，代价更大。
bool _isValidWordOrder(String core) {
  // 已剥过一层倒装；核心句又以「把」开头说明是叠用倒装，判未识别。
  if (core.startsWith('把')) return false;
  var verbCount = 0;
  for (var i = 0; i < core.length; i++) {
    if (_placeVerbs.contains(core.substring(i, i + 1))) verbCount++;
  }
  return verbCount == 1;
}

/// 剥离倒装前置的「把」字（可带一个显式主语）。返回剥后的核心句式。
/// 「我把梯子放阳台」→「梯子放阳台」；「把梯子放阳台」→「梯子放阳台」。
String _stripBaPrefix(String text) {
  if (text.startsWith('把')) {
    return text.substring(1).trim();
  }
  if (text.length >= 2 &&
      _baSubjects.contains(text.substring(0, 1)) &&
      text.substring(1, 2) == '把') {
    return text.substring(2).trim();
  }
  return text;
}

/// 把一句中文口语解析成结构化意图。
///
/// 纯函数：只接收一个 String，只调用 [normalizeName]，不碰仓储、数据库、UI。
/// 归一化在入口（统一 text）与出口（item/location 字段）各强制执行一次，
/// 输出字段不依赖「入口已归一」的隐含前提，normalizeName 幂等故无副作用。
/// 句尾语气词只剥一层；剥完仍以语气词结尾（叠用）判未识别，不循环剥。
/// V2 R1（方案 C）：认「放/搁/塞/摆」四类动词、动词后的介词变体（放到/放在…）、
/// 以及「把」字倒装句。查询句式 <物品>在哪 与三项归一化口径保持不变。
ParseResult parsePhrase(String input) {
  var text = normalizeName(input);
  if (text.isEmpty) return const ParseUnrecognized();

  if (_endsWithParticle(text)) {
    text = text.substring(0, text.length - 1).trim();
  }
  if (text.isEmpty || _endsWithParticle(text)) {
    return const ParseUnrecognized();
  }

  if (text.endsWith(_querySuffix)) {
    final item = text.substring(0, text.length - _querySuffix.length).trim();
    if (item.isEmpty) return const ParseUnrecognized();
    // 出口兜底：输出字段强制再过一次共用 normalizeName，不依赖
    // 「text 已在入口归一化」这一隐含前提。normalizeName 幂等，重复无副作用。
    return ParseQuery(item: normalizeName(item));
  }

  // 录入句式：先剥倒装的「把」，再校验语序（动词数/叠用倒装），最后找放置动词。
  final core = _stripBaPrefix(text);
  if (core.isEmpty || !_isValidWordOrder(core)) {
    return const ParseUnrecognized();
  }

  int? verbIndex;
  for (var i = 0; i < core.length; i++) {
    if (_placeVerbs.contains(core.substring(i, i + 1))) {
      verbIndex = i;
      break;
    }
  }
  if (verbIndex == null || verbIndex == 0 || verbIndex == core.length - 1) {
    return const ParseUnrecognized();
  }

  final item = core.substring(0, verbIndex).trim();
  var location = core.substring(verbIndex + 1).trim();
  // 动词后的介词并入动词吞掉：放到阳台 -> 位置「阳台」，不带介词前缀。
  if (_isPreposition(location)) {
    location = location.substring(1).trim();
  }
  // 吞掉一个介词后若仍以介词开头、或物品/位置为空，判未识别（保守防污染）。
  // 位置里含多个动词的情况已由前面的 _isValidWordOrder（全句动词数恰好 1）覆盖，
  // 无需再单独扫位置段。
  if (item.isEmpty || location.isEmpty || _isPreposition(location)) {
    return const ParseUnrecognized();
  }

  return ParseUpsert(
    item: normalizeName(item),
    location: normalizeName(location),
  );
}
