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

    test('倒装句式：我把梯子放阳台了 -> 未识别', () {
      expect(parsePhrase('我把梯子放阳台了'), isA<ParseUnrecognized>());
    });

    test('倒装句式带搁：梯子搁阳台了 -> 未识别', () {
      expect(parsePhrase('梯子搁阳台了'), isA<ParseUnrecognized>());
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

    test('介词前缀位置判未识别，防止「到阳台」当位置污染入库', () {
      // 回归断言：这些若解析成 Upsert，location 会带介词前缀写入库，
      // 之后按「阳台」查询将查不到。V1 一律判未识别，让用户重说。
      expect(parsePhrase('梯子放到阳台'), isA<ParseUnrecognized>());
      expect(parsePhrase('梯子放在阳台'), isA<ParseUnrecognized>());
      expect(parsePhrase('梯子放往阳台'), isA<ParseUnrecognized>());
      expect(parsePhrase('梯子放给阳台'), isA<ParseUnrecognized>());
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
  });
}
