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

    // ---- V3 交互说明：扩展触发词 ----

    test('V3 新动词 收/存/归：梯子收阳台、梯子存阳台、梯子归阳台 -> Upsert', () {
      for (final phrase in <String>['梯子收阳台', '梯子存阳台', '梯子归阳台']) {
        final ok = parsePhrase(phrase);
        expect(ok, isA<ParseUpsert>(), reason: phrase);
        final upsert = ok as ParseUpsert;
        expect(upsert.item, '梯子');
        expect(upsert.location, '阳台');
      }
    });

    test('V3 查询后缀 哪里/在哪儿/在哪里 -> Query(梯子)', () {
      for (final phrase in <String>[
        '梯子在哪里',
        '梯子在哪儿',
        '梯子哪里'
      ]) {
        final ok = parsePhrase(phrase);
        expect(ok, isA<ParseQuery>(), reason: phrase);
        expect((ok as ParseQuery).item, '梯子');
      }
    });

    test('V3 查询前缀 找/有没有 -> Query(梯子)', () {
      for (final phrase in <String>['找梯子', '有没有梯子']) {
        final ok = parsePhrase(phrase);
        expect(ok, isA<ParseQuery>(), reason: phrase);
        expect((ok as ParseQuery).item, '梯子');
      }
    });

    test('V3 显式前缀 记：/查： -> Upsert/Query', () {
      final rec = parsePhrase('记：梯子放阳台');
      expect(rec, isA<ParseUpsert>());
      expect((rec as ParseUpsert).item, '梯子');
      expect(rec.location, '阳台');

      final qry = parsePhrase('查：梯子');
      expect(qry, isA<ParseQuery>());
      expect((qry as ParseQuery).item, '梯子');
    });

    test('V3 全角冒号前缀同认：记：/查：', () {
      expect(parsePhrase('记：螺丝放厨房'), isA<ParseUpsert>());
      expect((parsePhrase('查：螺丝') as ParseQuery).item, '螺丝');
    });

    // 技术审核条件②：扩展触发词后，「找/存/收」出现在物品名里的歧义锁定。
    // 与 C6/D4/D5 同思路：固定当前表现、落档已知限制，不代表认可该结果正确。
    test('歧义锁定：物品名以「找」开头 + 录入 → 被查询前缀误吞', () {
      // 「找找放阳台」本意物品「找找」，但查询前缀「找」先命中，
      // 结果变成 Query(item=找放阳台)。已知限制，V2 口语扩展时再处理。
      final r = parsePhrase('找找放阳台');
      expect(r, isA<ParseQuery>(), reason: '找前缀优先于录入句式');
      expect((r as ParseQuery).item, '找放阳台');
    });

    test('歧义锁定：物品名以放置动词「存/收/归」开头 + 录入 → 未识别', () {
      // 动词数须恰好 1；「存钱罐放阳台」含「存」+「放」两个动词，
      // 判未识别，避免把「钱罐放阳台」整串当位置污染。
      for (final phrase in <String>[
        '存钱罐放阳台',
        '收纳箱放阳台',
        '收衣服放阳台',
        '归置架放阳台',
      ]) {
        expect(parsePhrase(phrase), isA<ParseUnrecognized>(), reason: phrase);
      }
    });

    test('歧义边界：含动词/前缀词的物品名在「在哪」查询句里正常解析', () {
      // 后缀查询先命中；物品名里的「存/收」不是查询词，不干扰。
      for (final phrase in <String>['存钱罐在哪', '收纳箱在哪']) {
        expect(parsePhrase(phrase), isA<ParseQuery>(), reason: phrase);
      }
      expect((parsePhrase('存钱罐在哪') as ParseQuery).item, '存钱罐');
    });

    // 2026-11-21 真机实测修复：「查梯子在哪儿」曾解析成查「查梯子」。
    // 组合式（查询词+后缀同时出现）现在剥掉头部查询词，按真实语义查物品本身。
    test('组合式：查梯子在哪儿/查梯子在哪里 -> Query(梯子)', () {
      for (final phrase in <String>['查梯子在哪儿', '查梯子在哪里', '查梯子在哪']) {
        final r = parsePhrase(phrase);
        expect(r, isA<ParseQuery>(), reason: phrase);
        expect((r as ParseQuery).item, '梯子', reason: phrase);
      }
    });

    test('组合式：找/有没有/查一下 与后缀连用 -> 剥头部查询词', () {
      expect((parsePhrase('找梯子在哪儿') as ParseQuery).item, '梯子');
      expect((parsePhrase('有没有梯子在哪儿') as ParseQuery).item, '梯子');
      expect((parsePhrase('查一下充电器在哪') as ParseQuery).item, '充电器');
      expect((parsePhrase('查查螺丝在哪里') as ParseQuery).item, '螺丝');
      // 旧锁定「找东西在哪 -> 查找东西」按组合式新语义更新为查「东西」。
      expect((parsePhrase('找东西在哪') as ParseQuery).item, '东西');
    });

    test('组合式守卫：两字物品名「查表」不被误剥裸查', () {
      expect((parsePhrase('查表在哪') as ParseQuery).item, '查表');
    });

    test('V3.2 挪位动词：「挪到/挪在/挪」作为放置动词', () {
      final to = parsePhrase('梯子挪到客厅');
      expect(to, isA<ParseUpsert>());
      expect((to as ParseUpsert).item, '梯子');
      expect(to.location, '客厅');

      final at = parsePhrase('梯子挪在客厅');
      expect(at, isA<ParseUpsert>());
      expect((at as ParseUpsert).item, '梯子');
      expect(at.location, '客厅');

      final bare = parsePhrase('梯子挪客厅');
      expect(bare, isA<ParseUpsert>());
      expect((bare as ParseUpsert).item, '梯子');
      expect(bare.location, '客厅');
    });

    test('裸查单独开头仍不作为查询前缀：查梯子 -> 未识别（规格不变）', () {
      expect(parsePhrase('查梯子'), isA<ParseUnrecognized>());
    });
  });

  // =========== V3.7 借还语义 + 数量 ===========
  group('V3.7 借阅语义解析', () {
    test('借出「借给张三2个梯子」→ ParseLend(物/人/数量)', () {
      final r = parsePhrase('借给张三2个梯子');
      expect(r, isA<ParseLend>());
      final lend = r as ParseLend;
      expect(lend.item, '梯子');
      expect(lend.borrower, '张三');
      expect(lend.quantity, 2);
      expect(lend.days, isNull);
    });

    test('借出「借2个梯子给张三」→ ParseLend', () {
      final r = parsePhrase('借2个梯子给张三') as ParseLend;
      expect(r.item, '梯子');
      expect(r.borrower, '张三');
      expect(r.quantity, 2);
    });

    test('借出「张三借了梯子」数量默认 1', () {
      final r = parsePhrase('张三借了梯子') as ParseLend;
      expect(r.borrower, '张三');
      expect(r.item, '梯子');
      expect(r.quantity, 1);
    });

    test('借出带天数「张三借梯子3天」→ days=3', () {
      final r = parsePhrase('张三借梯子3天') as ParseLend;
      expect(r.item, '梯子');
      expect(r.days, 3);
    });

    test('中文数量「张三借了两个梯子」→ quantity=2', () {
      final r = parsePhrase('张三借了两个梯子') as ParseLend;
      expect(r.quantity, 2);
      expect(r.item, '梯子');
    });

    test('归还「还了2个梯子」→ ParseReturn(物/数量)', () {
      final r = parsePhrase('还了2个梯子');
      expect(r, isA<ParseReturn>());
      expect((r as ParseReturn).item, '梯子');
      expect(r.quantity, 2);
    });

    test('归还「归还梯子给张三」→ ParseReturn 数量 null=全部', () {
      final r = parsePhrase('归还梯子给张三') as ParseReturn;
      expect(r.item, '梯子');
      expect(r.quantity, isNull);
    });

    test('录入带数量「2个梯子放阳台」→ ParseUpsert quantity=2', () {
      final r = parsePhrase('2个梯子放阳台') as ParseUpsert;
      expect(r.item, '梯子');
      expect(r.location, '阳台');
      expect(r.quantity, 2);
    });

    test('未识别带猜测：借/还相关给出 guess，无关为 null', () {
      expect((parsePhrase('借梯子') as ParseUnrecognized).guess, 'lend');
      expect((parsePhrase('梯子还') as ParseUnrecognized).guess, 'return');
      expect((parsePhrase('梯子') as ParseUnrecognized).guess, isNull);
    });

    test('歧义防线：含放置动词的「借条放阳台」仍走录入不被借出误吞', () {
      final r = parsePhrase('借条放阳台');
      expect(r, isA<ParseUpsert>());
      expect((r as ParseUpsert).item, '借条');
      expect(r.location, '阳台');
    });

    test('老句式零回归：查询/录入/显式前缀照旧', () {
      expect(parsePhrase('梯子在哪'), isA<ParseQuery>());
      expect(parsePhrase('记:梯子放阳台'), isA<ParseUpsert>());
      expect(parsePhrase('查:梯子'), isA<ParseQuery>());
    });

    // ===== V3.9 语音化第一批：废弃 / 恢复 / 改借期 =====
    group('V3.9 新增意图', () {
      test('废弃：「梯子废弃了/不要了/不用了」→ 物品=梯子', () {
        for (final phrase in <String>['梯子废弃了', '梯子不要了', '梯子不用了']) {
          final r = parsePhrase(phrase) as ParseDiscard;
          expect(r.item, '梯子', reason: phrase);
        }
      });

      test('废弃：「把梯子扔了/梯子报废了」→ 剥掉把字，物品=梯子', () {
        for (final phrase in <String>['把梯子扔了', '梯子报废了']) {
          final r = parsePhrase(phrase) as ParseDiscard;
          expect(r.item, '梯子', reason: phrase);
        }
      });

      test('废弃：多字物品名不被切坏', () {
        final r = parsePhrase('旧充电器不要了') as ParseDiscard;
        expect(r.item, '旧充电器');
      });

      test('废弃 + 位置词共存 → 报歧义，不擅自选废弃（元宝补充①）', () {
        final r = parsePhrase('梯子不要了放阳台');
        expect(r, isA<ParseAmbiguous>());
        final amb = r as ParseAmbiguous;
        expect(amb.candidates.first, isA<ParseDiscard>());
        expect(amb.candidates.any((c) => c is ParseUpsert), isTrue);
      });

      test('恢复：「恢复梯子/把梯子恢复/梯子恢复到明细」→ 物品=梯子', () {
        for (final phrase in <String>['恢复梯子', '把梯子恢复', '梯子恢复到明细']) {
          final r = parsePhrase(phrase) as ParseRestore;
          expect(r.item, '梯子', reason: phrase);
        }
      });

      test('恢复：「还原梯子」「梯子放回明细」→ 物品=梯子', () {
        expect((parsePhrase('还原梯子') as ParseRestore).item, '梯子');
        expect((parsePhrase('梯子放回明细') as ParseRestore).item, '梯子');
      });

      test('改借期：「梯子借期改成5天」→ 物品=梯子 天数=5 set', () {
        final r = parsePhrase('梯子借期改成5天') as ParseDueChange;
        expect(r.item, '梯子');
        expect(r.days, 5);
        expect(r.mode, DueChangeMode.set);
      });

      test('改借期：「借期延长到7天」→ 总天数 7', () {
        final r = parsePhrase('梯子借期延长到7天') as ParseDueChange;
        expect(r.item, '梯子');
        expect(r.days, 7);
        expect(r.mode, DueChangeMode.set);
      });

      test('改借期：「再借3天/续借3天」→ 追加模式', () {
        for (final phrase in <String>['梯子再借3天', '梯子续借3天']) {
          final r = parsePhrase(phrase) as ParseDueChange;
          expect(r.item, '梯子', reason: phrase);
          expect(r.days, 3);
          expect(r.mode, DueChangeMode.extendBy);
        }
      });

      test('改借期：「张三的梯子借期改成5天」→ 指名借阅人=张三', () {
        final r = parsePhrase('张三的梯子借期改成5天') as ParseDueChange;
        expect(r.borrower, '张三');
        expect(r.item, '梯子');
        expect(r.days, 5);
      });

      test('改借期：没说物品 → item 为 null（交 UI 按候选收敛）', () {
        final r = parsePhrase('借期改成5天') as ParseDueChange;
        expect(r.item, isNull);
        expect(r.borrower, isNull);
        expect(r.days, 5);
      });

      test('改借期：中文数字也认（借期改成五天）', () {
        final r = parsePhrase('梯子借期改成五天') as ParseDueChange;
        expect(r.days, 5);
      });
    });

    // ===== V3.9 守卫优先级（防抢答） =====
    group('V3.9 守卫优先级', () {
      test('「梯子借期改成5天」不被借出抢答（item 不会被切成「期改成5天」）', () {
        final r = parsePhrase('梯子借期改成5天');
        expect(r, isA<ParseDueChange>());
      });

      test('「借给张三的梯子不要了」不被借出抢答', () {
        final r = parsePhrase('借给张三的梯子不要了');
        expect(r, isA<ParseDiscard>());
        // V3.9.1 真机打回（PM 场景②）：物品名此前是「借给张三的梯子」——
        // 借出修饰语被当成了名字的一部分，查库必然找不到。已剥成「梯子」。
        expect((r as ParseDiscard).item, '梯子');
      });

      test('「梯子放回明细」不被放置抢答（位置不变成「回明细」）', () {
        final r = parsePhrase('梯子放回明细');
        expect(r, isA<ParseRestore>());
        expect((r as ParseRestore).item, '梯子');
      });

      test('V3.8 老句式零回归：借出/归还/查询/录入都不受影响', () {
        expect(parsePhrase('梯子放阳台'), isA<ParseUpsert>());
        expect(parsePhrase('梯子在哪'), isA<ParseQuery>());
        final lend = parsePhrase('借给张三1个梯子') as ParseLend;
        expect(lend.item, '梯子');
        expect(lend.borrower, '张三');
        final ret = parsePhrase('还了1个梯子') as ParseReturn;
        expect(ret.item, '梯子');
        expect(ret.quantity, 1);
      });
    });

    // ===== V3.9 语音化第一批：废弃 / 恢复 / 改借期 =====
    group('V3.9 新增意图', () {
      test('废弃：「梯子废弃了/不要了/不用了」→ 物品=梯子', () {
        for (final phrase in <String>['梯子废弃了', '梯子不要了', '梯子不用了']) {
          final r = parsePhrase(phrase) as ParseDiscard;
          expect(r.item, '梯子', reason: phrase);
        }
      });

      test('废弃：「把梯子扔了/梯子报废了」→ 剥掉把字，物品=梯子', () {
        for (final phrase in <String>['把梯子扔了', '梯子报废了']) {
          final r = parsePhrase(phrase) as ParseDiscard;
          expect(r.item, '梯子', reason: phrase);
        }
      });

      test('废弃：多字物品名不被切坏', () {
        final r = parsePhrase('旧充电器不要了') as ParseDiscard;
        expect(r.item, '旧充电器');
      });

      test('废弃 + 位置词共存 → 报歧义，不擅自选废弃（元宝补充①）', () {
        final r = parsePhrase('梯子不要了放阳台');
        expect(r, isA<ParseAmbiguous>());
        final amb = r as ParseAmbiguous;
        expect(amb.candidates.first, isA<ParseDiscard>());
        expect(amb.candidates.any((c) => c is ParseUpsert), isTrue);
      });

      test('恢复：「恢复梯子/把梯子恢复/梯子恢复到明细」→ 物品=梯子', () {
        for (final phrase in <String>['恢复梯子', '把梯子恢复', '梯子恢复到明细']) {
          final r = parsePhrase(phrase) as ParseRestore;
          expect(r.item, '梯子', reason: phrase);
        }
      });

      test('恢复：「还原梯子」「梯子放回明细」→ 物品=梯子', () {
        expect((parsePhrase('还原梯子') as ParseRestore).item, '梯子');
        expect((parsePhrase('梯子放回明细') as ParseRestore).item, '梯子');
      });

      test('改借期：「梯子借期改成5天」→ 物品=梯子 天数=5 set', () {
        final r = parsePhrase('梯子借期改成5天') as ParseDueChange;
        expect(r.item, '梯子');
        expect(r.days, 5);
        expect(r.mode, DueChangeMode.set);
      });

      test('改借期：「借期延长到7天」→ 总天数 7', () {
        final r = parsePhrase('梯子借期延长到7天') as ParseDueChange;
        expect(r.item, '梯子');
        expect(r.days, 7);
        expect(r.mode, DueChangeMode.set);
      });

      test('改借期：「再借3天/续借3天」→ 追加模式', () {
        for (final phrase in <String>['梯子再借3天', '梯子续借3天']) {
          final r = parsePhrase(phrase) as ParseDueChange;
          expect(r.item, '梯子', reason: phrase);
          expect(r.days, 3);
          expect(r.mode, DueChangeMode.extendBy);
        }
      });

      test('改借期：「张三的梯子借期改成5天」→ 指名借阅人=张三', () {
        final r = parsePhrase('张三的梯子借期改成5天') as ParseDueChange;
        expect(r.borrower, '张三');
        expect(r.item, '梯子');
        expect(r.days, 5);
      });

      test('改借期：没说物品 → item 为 null（交 UI 按候选收敛）', () {
        final r = parsePhrase('借期改成5天') as ParseDueChange;
        expect(r.item, isNull);
        expect(r.borrower, isNull);
        expect(r.days, 5);
      });

      test('改借期：中文数字也认（借期改成五天）', () {
        final r = parsePhrase('梯子借期改成五天') as ParseDueChange;
        expect(r.days, 5);
      });
    });

    // ===== V3.9 守卫优先级（防抢答） =====
    group('V3.9 守卫优先级', () {
      test('「梯子借期改成5天」不被借出抢答（item 不会被切成「期改成5天」）', () {
        final r = parsePhrase('梯子借期改成5天');
        expect(r, isA<ParseDueChange>());
      });

      test('「借给张三的梯子不要了」不被借出抢答', () {
        final r = parsePhrase('借给张三的梯子不要了');
        expect(r, isA<ParseDiscard>());
        // V3.9.1 真机打回（PM 场景②）：物品名此前是「借给张三的梯子」——
        // 借出修饰语被当成了名字的一部分，查库必然找不到。已剥成「梯子」。
        expect((r as ParseDiscard).item, '梯子');
      });

      test('「梯子放回明细」不被放置抢答（位置不变成「回明细」）', () {
        final r = parsePhrase('梯子放回明细');
        expect(r, isA<ParseRestore>());
        expect((r as ParseRestore).item, '梯子');
      });

      test('V3.8 老句式零回归：借出/归还/查询/录入都不受影响', () {
        expect(parsePhrase('梯子放阳台'), isA<ParseUpsert>());
        expect(parsePhrase('梯子在哪'), isA<ParseQuery>());
        final lend = parsePhrase('借给张三1个梯子') as ParseLend;
        expect(lend.item, '梯子');
        expect(lend.borrower, '张三');
        final ret = parsePhrase('还了1个梯子') as ParseReturn;
        expect(ret.item, '梯子');
        expect(ret.quantity, 1);
      });
    });

    // ===== V3.8 真机验收打回修复回归 =====
    // 根因：形态2 只剥「借」一个字，「了」留在数量前 → 数量静默丢成 1、
    // 物品名被污染成「了3个钉子」；形态1 固定剥 2 字符 → 借阅人成「了张三」。
    test('V3.8：「借了3个钉子给张三」→ 物品=钉子 数量=3 借阅人=张三', () {
      final r = parsePhrase('借了3个钉子给张三') as ParseLend;
      expect(r.item, '钉子');
      expect(r.quantity, 3);
      expect(r.borrower, '张三');
    });

    test('V3.8：「借给了张三3个钉子」→ 借阅人不带「了」、数量=3', () {
      final r = parsePhrase('借给了张三3个钉子') as ParseLend;
      expect(r.borrower, '张三');
      expect(r.item, '钉子');
      expect(r.quantity, 3);
    });

    test('V3.8：「张三借走了3个钉子」→ 数量=3 不被「了」吞掉', () {
      final r = parsePhrase('张三借走了3个钉子') as ParseLend;
      expect(r.borrower, '张三');
      expect(r.item, '钉子');
      expect(r.quantity, 3);
    });

    // 被字句：中文被动语序，此前无形态能匹配（被形态3 切成一团）。
    test('V3.8：「梯子被张三借走了1天」→ 物品=梯子 人=张三 天数=1', () {
      final r = parsePhrase('梯子被张三借走了1天') as ParseLend;
      expect(r.item, '梯子');
      expect(r.borrower, '张三');
      expect(r.days, 1);
    });

    test('V3.8：「梯子被张三借走了」→ 剥「了」后为空也算合法借出句', () {
      final r = parsePhrase('梯子被张三借走了') as ParseLend;
      expect(r.item, '梯子');
      expect(r.borrower, '张三');
      expect(r.quantity, 1);
    });

    test('V3.8：「3个钉子被张三借走了」→ 前置数量=3', () {
      final r = parsePhrase('3个钉子被张三借走了') as ParseLend;
      expect(r.item, '钉子');
      expect(r.quantity, 3);
      expect(r.borrower, '张三');
    });

    // ===== V3.8 归还指名到人（PM：没说谁还的会记错账）=====
    test('V3.8：「还了1个梯子」→ 无借阅人（交给 UI 按候选收敛）', () {
      final r = parsePhrase('还了1个梯子') as ParseReturn;
      expect(r.item, '梯子');
      expect(r.quantity, 1);
      expect(r.borrower, isNull);
    });

    test('V3.8：「张三还了1个梯子」→ 借阅人=张三', () {
      final r = parsePhrase('张三还了1个梯子') as ParseReturn;
      expect(r.item, '梯子');
      expect(r.quantity, 1);
      expect(r.borrower, '张三');
    });

    test('V3.8：「还了1个梯子给张三」→ 尾部「给某人」不再被丢弃', () {
      final r = parsePhrase('还了1个梯子给张三') as ParseReturn;
      expect(r.item, '梯子');
      expect(r.quantity, 1);
      expect(r.borrower, '张三');
    });

    test('V3.8：「张三归还了梯子」→ 借阅人=张三、数量 null=全部', () {
      final r = parsePhrase('张三归还了梯子') as ParseReturn;
      expect(r.borrower, '张三');
      expect(r.item, '梯子');
      expect(r.quantity, isNull);
    });

    test('V3.8：放置短语不吃归还：「东西还放在阳台」仍走录入', () {
      final r = parsePhrase('东西还放在阳台');
      expect(r, isA<ParseUpsert>());
      expect((r as ParseUpsert).location, '阳台');
    });

    test('V3.8：物品名带「收」不被误伤：「还了收纳盒」→ 物品=收纳盒', () {
      final r = parsePhrase('还了收纳盒') as ParseReturn;
      expect(r.item, '收纳盒');
    });
  });

  // ============ V3.9.1 真机打回修复 ============
  //
  // PM 真机复验打回（场景②④）的根因：口语「梯子借给张三」是「物品在前、
  // 动词在后」的语序，旧解析器只认「动词在前」，借出动词「借」留在了物品名里，
  // 物品被建成「梯子借」；再者废弃/改借期分支没剥「借给张三的」这类修饰语，
  // 物品名成了「借给张三的梯子」。
  group('V3.9.1 真机打回修复', () {
    test('「梯子借给张三」→ 物品=梯子、借阅人=张三（物品在前、动词在后）', () {
      final r = parsePhrase('梯子借给张三') as ParseLend;
      expect(r.item, '梯子');
      expect(r.borrower, '张三');
      expect(r.quantity, 1);
    });

    test('「梯子借给张三3个」→ 数量跟在人后面也不能丢', () {
      final r = parsePhrase('梯子借给张三3个') as ParseLend;
      expect(r.item, '梯子');
      expect(r.borrower, '张三');
      expect(r.quantity, 3);
    });

    test('「借给张三的梯子废弃了」→ 剥掉借出修饰语，物品=梯子', () {
      final r = parsePhrase('借给张三的梯子废弃了') as ParseDiscard;
      expect(r.item, '梯子');
    });

    test('「张三借走的梯子废弃了」→ 剥掉借出修饰语，物品=梯子', () {
      final r = parsePhrase('张三借走的梯子废弃了') as ParseDiscard;
      expect(r.item, '梯子');
    });

    test('「借给张三的梯子借期改成5天」→ 物品=梯子、借阅人=张三', () {
      final r = parsePhrase('借给张三的梯子借期改成5天') as ParseDueChange;
      expect(r.item, '梯子');
      expect(r.borrower, '张三');
      expect(r.days, 5);
    });

    test('借出老句式零回归（动词在前那几种照旧）', () {
      final a = parsePhrase('借给张三1个梯子') as ParseLend;
      expect(a.item, '梯子');
      expect(a.borrower, '张三');
      expect(a.quantity, 1);

      final b = parsePhrase('借了3个钉子给张三') as ParseLend;
      expect(b.item, '钉子');
      expect(b.borrower, '张三');
      expect(b.quantity, 3);

      final c = parsePhrase('借2个梯子给张三') as ParseLend;
      expect(c.item, '梯子');
      expect(c.quantity, 2);

      final d = parsePhrase('张三借了2个梯子') as ParseLend;
      expect(d.item, '梯子');
      expect(d.borrower, '张三');
      expect(d.quantity, 2);

      final e = parsePhrase('梯子被张三借走了1天') as ParseLend;
      expect(e.item, '梯子');
      expect(e.borrower, '张三');
      expect(e.days, 1);
    });

    test('真名里带「借」不被误剥：「借书」「借款单」原样保留', () {
      final r = parsePhrase('借书不要了') as ParseDiscard;
      expect(r.item, '借书');
    });

    test('口语变体：「把梯子借给张三」不把「把」留在物品名里', () {
      final r = parsePhrase('把梯子借给张三') as ParseLend;
      expect(r.item, '梯子');
      expect(r.borrower, '张三');
    });

    test('口语变体：「梯子借给张三吧」的语气词不粘进人名', () {
      final r = parsePhrase('梯子借给张三吧') as ParseLend;
      expect(r.item, '梯子');
      expect(r.borrower, '张三');
    });
  });
}
