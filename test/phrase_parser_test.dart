import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/data/normalize.dart';
import 'package:home_inventory/data/phrase_parser.dart';

void main() {
  group('parsePhrase 句式解析', () {
    test('录入模板：梯子放阳台 -> Upsert(梯子, 阳台)', () {
      final result = parsePhrase('梯子放阳台');
      expect(result, isA<ParseUpsert>());
      expect((result as ParseUpsert).item, '梯子');
      expect(result.location, '阳台');
    });

    test('查询模板：梯子在哪 -> Query(梯子)', () {
      final result = parsePhrase('梯子在哪');
      expect(result, isA<ParseQuery>());
      expect((result as ParseQuery).item, '梯子');
    });

    test('录入带句尾语气词：梯子放阳台了 -> Upsert', () {
      final result = parsePhrase('梯子放阳台了');
      expect(result, isA<ParseUpsert>());
      expect((result as ParseUpsert).item, '梯子');
      expect(result.location, '阳台');
    });

    test('查询带句尾语气词：梯子在哪呢 -> Query', () {
      final result = parsePhrase('梯子在哪呢');
      expect(result, isA<ParseQuery>());
      expect((result as ParseQuery).item, '梯子');
    });

    test('V2 倒装句式：我把梯子放阳台了 -> Upsert(梯子, 阳台)', () {
      // 契约变更 CR-V2-R1：V1 判未识别，V2 方案 C 认「把」字倒装。
      final result = parsePhrase('我把梯子放阳台了');
      expect(result, isA<ParseUpsert>());
      expect((result as ParseUpsert).item, '梯子');
      expect(result.location, '阳台');
    });

    test('V2 倒装句式带搁：梯子搁阳台了 -> Upsert(梯子, 阳台)', () {
      final result = parsePhrase('梯子搁阳台了');
      expect(result, isA<ParseUpsert>());
      expect((result as ParseUpsert).item, '梯子');
      expect(result.location, '阳台');
    });

    test('空串 -> 未识别', () {
      expect(parsePhrase(''), isA<ParseUnrecognized>());
      expect(parsePhrase('   '), isA<ParseUnrecognized>());
    });

    test('只有位置没有物品：放阳台 -> 未识别', () {
      expect(parsePhrase('放阳台'), isA<ParseUnrecognized>());
    });

    test('只有物品没有位置：梯子放 -> 未识别', () {
      expect(parsePhrase('梯子放'), isA<ParseUnrecognized>());
    });

    test('叠用语气词只剥一层：梯子放阳台了吧 -> 未识别', () {
      expect(parsePhrase('梯子放阳台了吧'), isA<ParseUnrecognized>());
    });

    test('纯物品名不匹配任何模板 -> 未识别', () {
      expect(parsePhrase('梯子'), isA<ParseUnrecognized>());
    });

    test('入口强制归一化：输出字段等于对原始入参直接 normalize 的结果（不依赖调用方预处理）', () {
      // 入参故意不归一化：首尾空格 + 全角 ASCII。parsePhrase 必须在函数内部
      // 第 54 行自己做 normalizeName，否则下面的断言立刻失败。
      final result = parsePhrase('  ＬＡＤＤＥＲ放　ＡＢＣ　') as ParseUpsert;
      expect(result.item, normalizeName('ＬＡＤＤＥＲ')); // 'ladder'
      expect(result.item, 'ladder');
      expect(result.location, normalizeName('ＡＢＣ')); // 'abc'
      expect(result.location, 'abc');
    });

    test('归一化同源：带空格与全角输入解析出同一物品名', () {
      final spaced = parsePhrase('  梯子  放  阳台  ') as ParseUpsert;
      final plain = parsePhrase('梯子放阳台') as ParseUpsert;
      expect(spaced.item, plain.item);
      expect(spaced.location, plain.location);

      final fullWidth = parsePhrase('梯子放ＡＢＣ') as ParseUpsert;
      expect(fullWidth.location, normalizeName('ABC'));
    });

    test('V2 介词变体整体识别：位置取介词后的干净片段，不污染入库', () {
      // 契约变更 CR-V2-R1：V1 因怕「到阳台」污染而判未识别；V2 由动词吞掉介词，
      // 位置天然干净，四条口语变体都识别成同一个 Upsert(梯子, 阳台)。
      for (final phrase in const <String>[
        '梯子放到阳台',
        '梯子放在阳台',
        '梯子放往阳台',
        '梯子放给阳台',
      ]) {
        final result = parsePhrase(phrase);
        expect(result, isA<ParseUpsert>(), reason: phrase);
        expect((result as ParseUpsert).item, '梯子', reason: phrase);
        expect(result.location, '阳台', reason: phrase);
      }
    });

    test('介词拦截不误伤：位置名首字非介词时正常录入', () {
      final result = parsePhrase('梯子放阳台');
      expect(result, isA<ParseUpsert>());
      expect((result as ParseUpsert).location, '阳台');
    });

    test('两个精确模板之外一律未识别', () {
      expect(parsePhrase('梯子在阳台'), isA<ParseUnrecognized>());
      expect(parsePhrase('梯子扔阳台'), isA<ParseUnrecognized>());
    });

    // =========== V2 R1 方案 C 新增用例 ===========

    test('C1 新动词 塞/摆：梯子塞阳台、梯子摆阳台 -> Upsert', () {
      for (final phrase in const <String>['梯子塞阳台', '梯子摆阳台']) {
        final result = parsePhrase(phrase);
        expect(result, isA<ParseUpsert>(), reason: phrase);
        expect((result as ParseUpsert).item, '梯子', reason: phrase);
        expect(result.location, '阳台', reason: phrase);
      }
    });

    test('C2 他动词+介词：梯子搁到阳台、梯子塞在床上 -> 位置剥介词', () {
      final a = parsePhrase('梯子搁到阳台') as ParseUpsert;
      expect(a.item, '梯子');
      expect(a.location, '阳台');
      final b = parsePhrase('梯子塞在床上') as ParseUpsert;
      expect(b.item, '梯子');
      expect(b.location, '床上');
    });

    test('C3 无主语倒装：把梯子放阳台 -> Upsert(梯子, 阳台)', () {
      final result = parsePhrase('把梯子放阳台') as ParseUpsert;
      expect(result.item, '梯子');
      expect(result.location, '阳台');
    });

    test('C4 主语+倒装+搁+语气词：我把梯子搁阳台了 -> Upsert', () {
      final result = parsePhrase('我把梯子搁阳台了') as ParseUpsert;
      expect(result.item, '梯子');
      expect(result.location, '阳台');
    });

    test('C5 介词变体出口归一化：我把梯子放到　ＡＢＣ　 -> abc', () {
      final result = parsePhrase('我把梯子放到　ＡＢＣ　') as ParseUpsert;
      expect(result.item, '梯子');
      expect(result.location, normalizeName('ABC'));
      expect(result.location, 'abc');
    });

    test('C6 已知歧义：以把开头的物品名被当倒装（把手放阳台 -> 手/阳台）', () {
      // 契约第四·已知限制：纯规则无词表无法区分「把手」这类物品名与倒装标志。
      // 规避口径=物品命名避免以「把」开头（如用「门把手」）。此用例锁住当前行为，
      // 防止后续改动悄悄改变歧义表现却不落档。
      final result = parsePhrase('把手放阳台') as ParseUpsert;
      expect(result.item, '手');
      expect(result.location, '阳台');
    });

    test('C7 多动词连写判未识别，防「阳台放厨房」整串当位置污染', () {
      // V1 split('放') 遇两句动词直接未识别；V2 找第一个动词后须保持同等防线。
      expect(parsePhrase('梯子放阳台放厨房'), isA<ParseUnrecognized>());
    });

    // =========== 审查需改点1：语序有效性防线 ===========

    test('D1 叠用倒装：我把把梯子放阳台 -> 未识别（倒装只剥一层）', () {
      // _stripBaPrefix 剥掉一层「我把」后核心句仍以「把」开头，判未识别，
      // 避免连续倒装标志蒙混过关。
      expect(parsePhrase('我把把梯子放阳台'), isA<ParseUnrecognized>());
    });

    test('D2 多动词换词：梯子搁阳台放厨房 -> 未识别（全句动词数须恰好1）', () {
      // 语序校验按「整句放置动词计数==1」实现，覆盖换动词后的连写变体。
      expect(parsePhrase('梯子搁阳台放厨房'), isA<ParseUnrecognized>());
    });

    test('D3 无放置动词：梯子和阳台 -> 未识别', () {
      expect(parsePhrase('梯子和阳台'), isA<ParseUnrecognized>());
    });

    test('D4 已知限制锁定：阳台放梯子仍按字面解析（语义颠倒纯规则拦不住）', () {
      // CHANGELOG 如实列为已知限制：它与合法的「梯子放阳台」语法结构相同，
      // pure function 无词典、不查库无法区分。此用例锁住当前行为，防止改动
      // 悄悄改变歧义表现却不落档（同 C6 思路），不代表认可该输入正确。
      final result = parsePhrase('阳台放梯子') as ParseUpsert;
      expect(result.item, '阳台');
      expect(result.location, '梯子');
    });

    test('D5 已知限制锁定：错位把字仍按字面解析（拦它会误伤「门把手」）', () {
      // 「阳台把梯子放厨房」与合法物品名「门把手放阳台」结构相同，
      // 规则层无法只拦前者，故列为已知限制并锁定当前行为。
      final result = parsePhrase('阳台把梯子放厨房') as ParseUpsert;
      expect(result.item, '阳台把梯子');
      expect(result.location, '厨房');
      // 反向确认：规避命名「门把手」不被误伤，仍正常录入。
      final ok = parsePhrase('门把手放阳台') as ParseUpsert;
      expect(ok.item, '门把手');
      expect(ok.location, '阳台');
    });
  });
}
