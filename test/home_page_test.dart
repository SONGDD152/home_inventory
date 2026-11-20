// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/home_inventory.dart';

/// 纯内存仓储：用于 widget 测试，操作是内存级的，pump 一帧即可落地。
/// 数据层的真实数据库行为由 inventory_database_test.dart 用真实 sqlite 覆盖。
///
/// Step 0（第 4 块测试基建）：三处 key 生成已改用生产共用 normalizeName，
/// 与仓储边界同源；不再各自 trim()，杜绝两套归一化标准。
class InMemoryRepository implements InventoryRepository {
  final List<Location> _locations = <Location>[];
  final List<Item> _items = <Item>[];
  final List<ItemLocation> _links = <ItemLocation>[];
  int _locationId = 0;
  int _itemId = 0;

  @override
  Future<List<Location>> getAllLocations() async =>
      List<Location>.unmodifiable(_locations);

  @override
  Future<int> addLocation(String name) async {
    final key = normalizeName(name);
    final existing = _locations.where((l) => l.name == key).toList();
    if (existing.isNotEmpty) return existing.first.id!;
    final id = ++_locationId;
    _locations.add(
      Location(id: id, name: key, createdAt: 1, updatedAt: 1),
    );
    return id;
  }

  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId) async {
    final key = normalizeName(itemName);
    var item = _items.where((i) => i.name == key).toList();
    final int itemId;
    if (item.isEmpty) {
      itemId = ++_itemId;
      _items.add(Item(id: itemId, name: key, createdAt: 1, updatedAt: 1));
    } else {
      itemId = item.first.id!;
    }
    final exists = _links.any(
      (l) => l.itemId == itemId && l.locationId == locationId,
    );
    if (exists) {
      return UpsertResult(itemId: itemId, locationId: locationId, created: false);
    }
    _links.add(
      ItemLocation(
        id: _links.length + 1,
        itemId: itemId,
        locationId: locationId,
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    return UpsertResult(itemId: itemId, locationId: locationId, created: true);
  }

  @override
  Future<ItemWithLocations?> findByName(String name) async {
    final key = normalizeName(name);
    final item = _items.where((i) => i.name == key).toList();
    if (item.isEmpty) return null;
    final locationIds = _links
        .where((l) => l.itemId == item.first.id)
        .map((l) => l.locationId)
        .toList();
    final locations = _locations
        .where((l) => locationIds.contains(l.id))
        .toList(growable: false);
    return ItemWithLocations(item: item.first, locations: locations);
  }

  int get linkCount => _links.length;
  int get locationCount => _locations.length;
}

/// V2 语音按钮测试替身：返回预设结果，绝不触碰真实平台通道。
/// cancelCount 记录取消次数，供"再次点击结束听"等断言。
class FakeSpeechInput implements SpeechInput {
  FakeSpeechInput({this.result = const SpeechNoResult()});

  SpeechResult result;
  int listenCount = 0;
  int cancelCount = 0;

  @override
  Future<SpeechResult> listen() async {
    listenCount++;
    return result;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
  }

  @override
  bool get isListening => false;
}

/// 挂起型语音替身：listen() 返回一个受控 future，用于覆盖"识别中 dispose"。
/// 只有测试显式 complete 才会返回，能精确模拟平台异步悬挂。
class PendingSpeechInput implements SpeechInput {
  final Completer<SpeechResult> _completer = Completer<SpeechResult>();
  int listenCount = 0;
  int cancelCount = 0;

  void complete(SpeechResult result) {
    if (!_completer.isCompleted) _completer.complete(result);
  }

  @override
  Future<SpeechResult> listen() {
    listenCount++;
    return _completer.future;
  }

  @override
  Future<void> cancel() async {
    // 只记录调用，不完成 future：用于模拟"取消后平台仍可能迟到回调"的边界，
    // 由测试手动 complete 来控制回调时机。
    cancelCount++;
  }

  @override
  bool get isListening => !_completer.isCompleted;
}

void main() {
  late InMemoryRepository repo;

  // 冻结文案（测试按模板生成期望值，不写死样例值）。
  const notUnderstood =
      '没听懂，请这样说："XX放YY"记位置，或"XX在哪"查位置。';
  String notFound(String item) => '没有找到「$item」的记录。';
  String recorded(String item, String location) =>
      '已记下：「$item」放在「$location」。';
  String alreadyRecorded(String item, String location) =>
      '「$item」已经在「$location」了。';
  String locationAdded(String location) => '已添加位置：「$location」。';
  const emptyLocation = '位置名称不能为空。';

  setUp(() {
    repo = InMemoryRepository();
  });

  // Step 0 等价断言：直接证明内存仓储的归一化与生产共用 helper 一致，
  // 不经过 UI。N2/N4 依赖的前提由此从「推断」变为「实测」。
  test('Step0 归一化等价：全角/带空格输入经内存仓储落成归一化名', () async {
    final id = await repo.addLocation('　ＡＢＣ　');
    final locations = await repo.getAllLocations();
    expect(locations, hasLength(1));
    expect(locations.single.name, normalizeName('　ＡＢＣ　'));
    expect(locations.single.name, 'abc');
    expect(locations.single.id, id);
  });

  Future<void> pumpApp(WidgetTester tester) {
    return tester.pumpWidget(MaterialApp(home: HomePage(repository: repo)));
  }

  /// pump 一帧让 async 微任务与 rebuild 完成。
  /// 内存仓储无真实 I/O，无需 runAsync（headless 下 runAsync 会死锁）。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }

  Future<void> submit(WidgetTester tester, String phrase) async {
    await tester.enterText(find.byKey(const Key('phrase_field')), phrase);
    await tester.tap(find.byKey(const Key('submit_button')));
    await settle(tester);
  }

  Future<void> addLocation(WidgetTester tester, String name) async {
    await tester.enterText(find.byKey(const Key('new_location_field')), name);
    await tester.tap(find.byKey(const Key('add_location_button')));
    await settle(tester);
  }

  // ============ 6 条原有回归用例（保留意图，改为单句式驱动 + 冻结文案）============

  testWidgets('新增位置→录入→按精确名称能查到', (tester) async {
    await pumpApp(tester);
    await addLocation(tester, '阳台');
    expect(find.text(locationAdded('阳台')), findsOneWidget);

    await submit(tester, '梯子放阳台');
    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);

    await submit(tester, '梯子在哪');
    expect(find.text('「梯子」在：阳台（共1处）。'), findsOneWidget);
    expect(find.byKey(const Key('result_location_1')), findsOneWidget);
    expect(find.textContaining('没有找到'), findsNothing);
  });

  testWidgets('连点两下记下只产生一条关联', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');
    // 第一次：断言「已记下」确实出现过（建立对比基线）。
    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);

    await submit(tester, '梯子放阳台');
    // 第二次：走幂等分支，只显示「已记过」；第一次的「已记下」被覆盖，
    // 不得两条并存——否则文案分支判定错误（DeepSeek 第92轮圈点）。
    expect(repo.linkCount, 1);
    expect(repo.locationCount, 1);
    expect(find.text(alreadyRecorded('梯子', '阳台')), findsOneWidget);
    expect(find.text(recorded('梯子', '阳台')), findsNothing);
  });

  testWidgets('空库查询显示没有记录且不报错', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子在哪');

    expect(find.text(notFound('梯子')), findsOneWidget);
  });

  testWidgets('空句式输入走没听懂且不写库', (tester) async {
    await pumpApp(tester);
    await submit(tester, '');

    // 用例 4 替代关系：原「请填写物品名称」被「没听懂」取代（非漏删）。
    expect(find.text(notUnderstood), findsOneWidget);
    expect(find.text('请填写物品名称'), findsNothing);
    expect(repo.linkCount, 0);
  });

  testWidgets('同名多位置全量列出', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');
    await submit(tester, '梯子放储物间');

    await submit(tester, '梯子在哪');
    expect(find.text('「梯子」在：阳台、储物间（共2处）。'), findsOneWidget);
    expect(find.byKey(const Key('result_location_1')), findsOneWidget);
    expect(find.byKey(const Key('result_location_2')), findsOneWidget);
  });

  testWidgets('精确名称不通配：查「梯」找不到「梯子」', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');

    await submit(tester, '梯在哪');
    expect(find.text(notFound('梯')), findsOneWidget);
    expect(find.textContaining('「梯子」在：'), findsNothing);
  });

  // ============ 6 条新增用例（自动新建 / 归一化驱动 / 幂等 / 同源 / 提示分开）============

  testWidgets('N1 句式录入新位置自动新建并关联', (tester) async {
    await pumpApp(tester);
    // 前置：库里没有任何位置（未点 add_location_button）。
    expect(repo.locationCount, 0);

    await submit(tester, '梯子放阳台');

    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);
    expect(repo.locationCount, 1);
    expect(repo.linkCount, 1);
    final locations = await repo.getAllLocations();
    expect(locations.single.name, '阳台');
  });

  testWidgets('N2 自动新建由归一化结果驱动（全角+空格）', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放　ＡＢＣ　');

    final locations = await repo.getAllLocations();
    expect(locations.single.name, 'abc'); // 全角转半角 + lower + trim
    expect(repo.locationCount, 1);
  });

  testWidgets('N2b 添加位置名为空走冻结文案，非没听懂', (tester) async {
    await pumpApp(tester);
    await addLocation(tester, '   ');

    // D2 边界：添加位置框空名 →「位置名称不能为空」，且不得显示「没听懂」。
    expect(find.text(emptyLocation), findsOneWidget);
    expect(find.text(notUnderstood), findsNothing);
    expect(repo.locationCount, 0);
  });

  testWidgets('N3 重复录入同一新位置幂等、无 UI 旁路', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');
    await submit(tester, '梯子放阳台');

    expect(repo.locationCount, 1);
    expect(repo.linkCount, 1);
  });

  testWidgets('N4 显式添加位置与句式录入同源：位置表、关联表各恰好1条', (tester) async {
    await pumpApp(tester);
    // 显式入口添加全角位置名 → 归一化落库。
    await addLocation(tester, '　ＡＢＣ　');
    expect(find.text(locationAdded('abc')), findsOneWidget);

    // 句式录入到同一位置（归一化后同为 abc）。
    await submit(tester, '梯子放abc');

    // 两处分别断言，精确同源。
    final locations = await repo.getAllLocations();
    expect(locations, hasLength(1)); // 位置表恰好 1 条
    expect(locations.single.name, 'abc');
    expect(repo.linkCount, 1); // 关联表恰好 1 条
  });

  testWidgets('N5 两种提示分开且没听懂零写入', (tester) async {
    await pumpApp(tester);
    // 句式不合规 → 没听懂，且无任何写入。
    await submit(tester, '梯子呢');
    expect(find.text(notUnderstood), findsOneWidget);
    expect(repo.linkCount, 0);
    expect(repo.locationCount, 0);
    final locations = await repo.getAllLocations();
    expect(locations, isEmpty);

    // 句式合法但查不到 → 没有记录（与没听懂不混）。
    await submit(tester, '梯子在哪');
    expect(find.text(notFound('梯子')), findsOneWidget);
    expect(find.text(notUnderstood), findsNothing);
  });

  testWidgets('N6 V2倒装与介词口语现在录入成功且位置不重复', (tester) async {
    // 契约变更 CR-V2-R1：V1 这两句判没听懂、零写入；V2 方案 C 认倒装与介词变体。
    await pumpApp(tester);

    await submit(tester, '我把梯子放阳台了');
    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);
    expect(find.text(notUnderstood), findsNothing);
    expect(repo.locationCount, 1);
    expect(repo.linkCount, 1);

    // 第二句同物同位的口语变体（放到=放），应走「已经记过」分支，不重复建位置/关联。
    await submit(tester, '梯子放到阳台');
    expect(find.text(alreadyRecorded('梯子', '阳台')), findsOneWidget);
    expect(find.text(notUnderstood), findsNothing);
    expect(repo.locationCount, 1);
    expect(repo.linkCount, 1);
  });

  testWidgets('N7 语序非法输入判没听懂且零写入（叠用倒装/多动词）',
      (tester) async {
    // 审查需改点1：规则层能确定非法的语序必须拦住，且不产生任何脏数据。
    await pumpApp(tester);

    for (final phrase in const <String>[
      '我把把梯子放阳台', // 叠用倒装
      '梯子搁阳台放厨房', // 多动词连写
      '梯子和阳台', // 无放置动词
    ]) {
      await submit(tester, phrase);
      expect(find.text(notUnderstood), findsOneWidget, reason: phrase);
      expect(repo.locationCount, 0, reason: phrase);
      expect(repo.linkCount, 0, reason: phrase);
    }
    expect(await repo.getAllLocations(), isEmpty);
  });

  // ============ V2 语音按钮用例（注入 FakeSpeechInput，不碰平台）============

  Future<void> pumpWithSpeech(WidgetTester tester, SpeechInput speech) {
    // UniqueKey 强制重建 State：否则连续 pump 同类 HomePage 会复用旧 State，
    // _speech 缓存着上一个 Fake，导致换假实现不生效（V4 曾因此误报）。
    return tester.pumpWidget(MaterialApp(
      home: HomePage(
          key: UniqueKey(), repository: repo, speechInput: speech),
    ));
  }

  Future<void> tapVoice(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('voice_button')));
    await settle(tester);
  }

  testWidgets('V1 语音识别文字只填入输入框，不自动提交、零写入',
      (tester) async {
    final speech = FakeSpeechInput(result: const SpeechText('梯子放阳台'));
    await pumpWithSpeech(tester, speech);

    await tapVoice(tester);

    expect(speech.listenCount, 1);
    final field = tester.widget<TextField>(find.byKey(const Key('phrase_field')));
    expect(field.controller!.text, '梯子放阳台');
    // 关键：不自动提交——没有提示、没有入库。
    expect(find.text(recorded('梯子', '阳台')), findsNothing);
    expect(repo.locationCount, 0);
    expect(repo.linkCount, 0);
  });

  testWidgets('V2 语音填入后点确定，走原 parsePhrase 链路正常录入', (tester) async {
    final speech = FakeSpeechInput(result: const SpeechText('梯子放阳台'));
    await pumpWithSpeech(tester, speech);

    await tapVoice(tester);
    await tester.tap(find.byKey(const Key('submit_button')));
    await settle(tester);

    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);
    expect(repo.locationCount, 1);
    expect(repo.linkCount, 1);
  });

  testWidgets('V3 语音原文不被 UI 预处理，归一化仍由仓储边界完成', (tester) async {
    // Fake 返回全角+首尾空格的原文；UI 须原样填入，点确定后落成规范名。
    final speech = FakeSpeechInput(result: const SpeechText('　梯子放阳台　'));
    await pumpWithSpeech(tester, speech);

    await tapVoice(tester);
    final field = tester.widget<TextField>(find.byKey(const Key('phrase_field')));
    expect(field.controller!.text, '　梯子放阳台　');

    await tester.tap(find.byKey(const Key('submit_button')));
    await settle(tester);
    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);
  });

  testWidgets('V4 语音不可用提示与没听清提示分离，均零写入', (tester) async {
    // 不可用。
    var speech = FakeSpeechInput(result: const SpeechUnavailable());
    await pumpWithSpeech(tester, speech);
    await tapVoice(tester);
    expect(find.text('语音不可用，请用键盘输入。'), findsOneWidget);
    expect(find.text('没听清，请再说一遍。'), findsNothing);
    expect(repo.locationCount, 0);

    // 没听清（与不可用是不同提示）。
    speech = FakeSpeechInput(result: const SpeechNoResult());
    await pumpWithSpeech(tester, speech);
    await tapVoice(tester);
    expect(find.text('没听清，请再说一遍。'), findsOneWidget);
    expect(find.text('语音不可用，请用键盘输入。'), findsNothing);
    expect(repo.linkCount, 0);
  });

  testWidgets('V5 话筒按钮在页面上可见可点（不注入语音也渲染）', (tester) async {
    // 按钮用默认实现也照常渲染；不点它就不触碰平台通道。
    await pumpApp(tester);
    expect(find.byKey(const Key('voice_button')), findsOneWidget);
    expect(find.byTooltip('语音输入'), findsOneWidget);
  });

  testWidgets('V6 不注入语音也可手动输入（回归，默认实现不被触碰）', (tester) async {
    await pumpApp(tester);
    await submit(tester, '梯子放阳台');
    expect(find.text(recorded('梯子', '阳台')), findsOneWidget);
    expect(repo.linkCount, 1);
  });

  testWidgets('V7 识别中 dispose 页面：cancel 被调用且 async 后不写库不异常',
      (tester) async {
    // DeepSeek 放行自查第4项：覆盖"正在听时退出页面"的生命周期边界。
    final speech = PendingSpeechInput();
    await pumpWithSpeech(tester, speech);

    // 点话筒 → listen() 挂起，_listening=true（识别进行中）。
    await tester.tap(find.byKey(const Key('voice_button')));
    await settle(tester);
    expect(speech.listenCount, 1, reason: '识别已启动且挂起中');

    // 识别未完成时卸载页面 → dispose 必须调 cancel（否则平台语音悬挂）。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(speech.cancelCount, 1, reason: 'dispose 应取消进行中的识别');

    // dispose 后平台才回调结果：mounted 护栏须拦住，不写库、不抛异常。
    // 若 _onVoicePressed 缺 `if (!mounted) return`，这里会抛
    // "setState() called after dispose" 令测试失败。
    speech.complete(const SpeechText('梯子放阳台'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(repo.locationCount, 0);
    expect(repo.linkCount, 0);
  });
}
