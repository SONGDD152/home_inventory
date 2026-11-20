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

/// 未识别：不符合冻结的两个句式模板。
class ParseUnrecognized extends ParseResult {
  const ParseUnrecognized();
}

const List<String> _trailingParticles = <String>['了', '呢', '吧'];
const String _placeMarker = '放';
const String _querySuffix = '在哪';

/// 位置部分若以这些介词开头（如「放到阳台」「放在阳台」），说明是 V1 不支持
/// 的介词变体口语。若照常抽取会把「到阳台」当成位置名写入库，之后按「阳台」
/// 查不到，造成数据污染。按产品拍板：V1 一律判未识别，让用户用精确句式重说。
const List<String> _locationPrepositions = <String>['到', '在', '往', '向', '给', '至'];

bool _endsWithParticle(String text) {
  if (text.isEmpty) return false;
  return _trailingParticles.contains(text.substring(text.length - 1));
}

bool _startsWithPreposition(String text) {
  if (text.isEmpty) return false;
  return _locationPrepositions.contains(text.substring(0, 1));
}

/// 把一句中文口语解析成结构化意图。
///
/// 纯函数：只接收一个 String，只调用 [normalizeName]，不碰仓储、数据库、UI。
/// 归一化在入口（统一 text）与出口（item/location 字段）各强制执行一次，
/// 输出字段不依赖「入口已归一」的隐含前提，normalizeName 幂等故无副作用。
/// 句尾语气词只剥一层；剥完仍以语气词结尾（叠用）判未识别，不循环剥。
/// 「把/搁」倒装句式、以及位置带介词前缀（放到/放在…）的变体一律判未识别，
/// 避免把「到阳台」当位置名写入库造成数据污染。
ParseResult parsePhrase(String input) {
  var text = normalizeName(input);
  if (text.isEmpty) return const ParseUnrecognized();

  if (_endsWithParticle(text)) {
    text = text.substring(0, text.length - 1).trim();
  }
  if (text.isEmpty || _endsWithParticle(text)) {
    return const ParseUnrecognized();
  }

  if (text.contains('把') || text.contains('搁')) {
    return const ParseUnrecognized();
  }

  if (text.endsWith(_querySuffix)) {
    final item = text.substring(0, text.length - _querySuffix.length).trim();
    if (item.isEmpty) return const ParseUnrecognized();
    // 出口兜底：输出字段强制再过一次共用 normalizeName，不依赖
    // 「text 已在入口归一化」这一隐含前提。normalizeName 幂等，重复无副作用。
    return ParseQuery(item: normalizeName(item));
  }

  final parts = text.split(_placeMarker);
  if (parts.length == 2) {
    final item = parts[0].trim();
    final location = parts[1].trim();
    if (item.isNotEmpty &&
        location.isNotEmpty &&
        !_startsWithPreposition(location)) {
      // 出口兜底：同查询分支，两个字段都再过一次共用 helper。
      return ParseUpsert(
        item: normalizeName(item),
        location: normalizeName(location),
      );
    }
  }
  return const ParseUnrecognized();
}
