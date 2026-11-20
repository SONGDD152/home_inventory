import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/data/normalize.dart';

void main() {
  group('normalizeName 归一化', () {
    test('去首尾空格', () {
      expect(normalizeName('  梯子  '), '梯子');
    });

    test('全角空格 U+3000 当空白去掉', () {
      expect(normalizeName('\u3000梯子\u3000'), '梯子');
    });

    test('归一化顺序钉死：先全角转半角再 trim，全角空格包裹与半角同源', () {
      // 若实现成「先 trim 再转半角」，U+3000 会残留，这条即失败。
      expect(normalizeName('\u3000梯子\u3000'), normalizeName('梯子'));
      expect(normalizeName('\u3000梯子\u3000'), '梯子');
      expect(normalizeName('\u3000ＡＢＣ\u3000'), normalizeName('abc'));
    });

    test('全角 ASCII 转半角', () {
      expect(normalizeName('ＡＢＣ'), 'abc');
      expect(normalizeName('１２３'), '123');
    });

    test('大小写不敏感', () {
      expect(normalizeName('Ladder'), 'ladder');
      expect(normalizeName('LADDER'), 'ladder');
    });

    test('带尾空格与不带空格归一化为同一值', () {
      expect(normalizeName('梯子 '), normalizeName('梯子'));
    });

    test('中文不受大小写转换影响', () {
      expect(normalizeName('阳台'), '阳台');
    });

    test('纯空白归一化为空串', () {
      expect(normalizeName('   \u3000 '), '');
    });

    test('全角混合输入统一后同源', () {
      expect(normalizeName('　ＡＢＣ '), 'abc');
    });
  });
}
