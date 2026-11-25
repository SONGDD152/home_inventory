// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/inventory_database.dart';
import '../data/inventory_repository.dart';
import '../data/item.dart';
import '../data/normalize.dart';
import '../data/phrase_parser.dart';
import 'backup_page.dart';
import 'calibration_page.dart';
import 'item_list_page.dart';
import 'location_list_page.dart';
import 'loan_list_page.dart';

/// 家庭仓储 APP 界面（V3 交互说明）：单页，键盘语音 + 单句式输入框。
///
/// 语音能力完全交由系统输入法：点输入框唤起键盘、用户点键盘话筒转文字，
/// App 只承接"语音转文字后的"文本，做语义解析与仓储管理。不自建识别引擎、
/// 不渲染自定义录音面板。
///
/// 交互为单入口：一个句式框——「<物品>放<位置>」录入、「<物品>在哪」查询；
/// parsePhrase 纯函数解析三态，未识别走「没听懂」且零写入；
/// 归一化由仓储边界负责，UI 不自行预处理文本。
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.repository,
    this.title = '家庭仓储布局',
  });

  final InventoryRepository repository;
  final String title;

  @override
  State<HomePage> createState() => _HomePageState();
}

/// V3.5 五模块底栏导航骨架：一级模块枚举。
/// 仅仓储（storage）有真实功能；其余四个模块为产品规划中的占位，
/// 数据层/页面/业务逻辑待后续迭代逐个落地（详见 V35 方案简报事实①）。
enum _HomeModule {
  storage('仓储'),
  schedule('日程'),
  knowledge('知识库'),
  dining('餐饮'),
  wardrobe('衣橱');

  const _HomeModule(this.label);
  final String label;
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _phraseController = TextEditingController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  String? _notice;
  ItemWithLocations? _result;
  bool _busy = false;

  // V3.5 底栏当前模块（0=仓储，默认选中——唯一可用模块）。
  int _moduleIndex = 0;

  // V3 交互说明文案（替换 V1 冻结文案，逐字符合文档六）。
  // V3.4：_emptyLocation/_locationAdded 随首页手动添加入口撤下移除
  //（空名校验与「已添加」反馈由位置管理页承担）。
  static const String _notUnderstood =
      '没听懂，试试"XX放阳台"或"XX在哪"';

  static String _notFound(String item) => '暂未记录该物品：$item。';
  static String _recorded(String item, String location) =>
      '已记下：$item → $location';
  static String _moved(String item, String location, String previous) =>
      '已更新：$item → $location（原位置：$previous）';
  static String _alreadyRecorded(String item, String location) =>
      '「$item」已经在「$location」了。';

  @override
  void dispose() {
    _phraseController.dispose();
    super.dispose();
  }

  /// 句式主入口：parsePhrase 解析 → 三态分支。原文作为 rawText 落库。
  Future<void> _submitPhrase() async {
    final rawText = _phraseController.text;
    final parsed = parsePhrase(rawText);

    if (parsed is ParseUnrecognized) {
      // V3.7：未识别不再静默失败——若解析器有意图猜测，弹确认框展示
      // 「你是要借出还是归还？」并给出正确句式引导；无猜测仍提示「没听懂」。
      // 全程零写入，保留原文供用户编辑（元宝批复 + 建议）。
      if (parsed.guess != null && mounted) {
        await _showIntentConfirm(parsed.guess!);
      } else {
        _show(_notUnderstood);
      }
      return;
    }

    setState(() => _busy = true);
    try {
      if (parsed is ParseQuery) {
        await _handleQuery(parsed.item);
      } else if (parsed is ParseUpsert) {
        await _handleUpsert(parsed, rawText);
      } else if (parsed is ParseLend) {
        // V3.7 缺陷修复：说一句「借给张三1个梯子」直接落库，
        // 不必再进借出管理页手填三项（解析器早就能识别，缺的是落库分支）。
        await _handleLend(parsed);
      } else if (parsed is ParseReturn) {
        await _handleReturn(parsed);
      } else if (parsed is ParseDueChange) {
        // V3.9：改借期（「梯子借期改成5天」）。
        await _handleDueChange(parsed);
      } else if (parsed is ParseDiscard) {
        // V3.9：废弃（「梯子废弃了」）——借出中的先自动归还再转回收站。
        await _handleDiscard(parsed);
      } else if (parsed is ParseRestore) {
        // V3.9：恢复（「恢复梯子」）——同名则合并数量。
        await _handleRestore(parsed);
      } else if (parsed is ParseAmbiguous) {
        // V3.9：歧义（「梯子不要了放阳台」）——弹框让用户选意图，不替他猜。
        await _handleAmbiguous(parsed);
      }
      if (!mounted) return;
      _phraseController.clear();
    } on ArgumentError {
      if (!mounted) return;
      // 参数非法（如归一化后为空）也归为未识别，避免「失败/错误」措辞。
      setState(() {
        _busy = false;
        _notice = _notUnderstood;
        _result = null;
      });
    }
  }

  /// V3.7：未识别且解析器有猜测时，弹确认框展示意图并给句式引导。
  /// 选择后把示例句式填回输入框，用户点确定即可重新提交（零写入）。
  Future<void> _showIntentConfirm(String guess) async {
    final isLend = guess == 'lend';
    final hint = isLend
        ? '借给张三2个梯子'
        : '还了2个梯子';
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('intent_confirm_dialog'),
        title: const Text('没听懂，你是要——'),
        content: Text(
          isLend ? '借出物品吗？\n可这样说：$hint' : '归还物品吗？\n可这样说：$hint',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('intent_confirm_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('intent_confirm_use'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('用这个说法'),
          ),
        ],
      ),
    ).then((useExample) {
      if (useExample == true && mounted) {
        setState(() => _phraseController.text = hint);
      }
    });
  }

  Future<void> _handleQuery(String item) async {
    final found = await widget.repository.findByName(item);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = found;
      _notice = found == null ? _notFound(item) : null;
    });
  }

  /// 挪位语义（V3.2）：同一物品再记新位置 = 移动，旧位置软删。
  ///
  /// V3.10：贯通数量。
  ///  * [quantity] = 本次说的数量（覆盖 or 累加，由 [additive] 决定）。
  ///  * 无位置（累加语义「又多了2个梯子」）：**只改数量、不挪位**，
  ///    沿用物品原有位置关联。
  Future<void> _handleUpsert(ParseUpsert parsed, String rawText) async {
    final item = parsed.item;
    final location = parsed.location;
    final quantity = parsed.quantity;
    final additive = parsed.additive;

    // V3.10：无位置的累加表述——东西已经在某处，只加数量，不挪位。
    if (!parsed.hasLocation) {
      await _handleQuantityOnly(item, quantity, additive);
      return;
    }

    final locationId = await widget.repository.addLocation(location);
    if (!mounted) return;
    final result = await widget.repository.moveItem(
      item,
      locationId,
      rawText: rawText,
      quantity: quantity,
      additive: additive,
    );
    if (!mounted) return;
    final nameInDb = await _locationName(locationId);
    if (!mounted) return;
    String notice;
    if (result.previousLocations.isNotEmpty) {
      notice = _moved(item, nameInDb, result.previousLocations.join('、'));
    } else if (result.created) {
      notice = _recorded(item, nameInDb);
    } else {
      notice = _alreadyRecorded(item, nameInDb);
    }
    // V3.10：数量回显——说清现在家里有几个。
    if (quantity > 1 || result.quantityChanged) {
      notice = '$notice（现在 ${result.quantity} 个）';
    }
    setState(() {
      _busy = false;
      _notice = notice;
      _result = null;
    });
  }

  /// V3.10：只改数量、不挪位（句子里只有数量，没有位置）。
  ///
  /// 物品必须已经存在——没记录过的东西不能凭空出现。
  Future<void> _handleQuantityOnly(
      String item, int quantity, bool additive) async {
    final info = await widget.repository.getQuantityInfo(item);
    if (!mounted) return;
    final exists = await widget.repository.findByName(item);
    if (!mounted) return;
    if (exists == null) {
      setState(() {
        _busy = false;
        _notice = '还没记录过「$item」，先说一句「$item放阳台」再记数量。';
        _result = null;
      });
      return;
    }
    // 覆盖语义且不说「再/又」时，这是"纠正数量"。
    final newStock = additive ? info.stock + quantity : quantity;
    if (!additive && newStock == info.stock) {
      setState(() {
        _busy = false;
        _notice = '「$item」现在是 ${info.stock} 个，没变化。';
        _result = null;
      });
      return;
    }
    // 只改数量、不动位置——不能走 moveItem（那是挪位语义，
    // 会把物品的其他位置关联一并软删）。
    try {
      await widget.repository.setItemQuantity(item, newStock);
    } on ArgumentError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = e.message is String ? e.message : '记数量失败了。';
        _result = null;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _notice = additive
          ? '「$item」又添了 $quantity 个，现在是 ${info.stock + quantity} 个。'
          : '「$item」数量改成 $quantity 个。';
      _result = null;
    });
  }

  /// V3.7 缺陷修复：语音借出落库。
  /// 「借给张三1个梯子」→ lendItem，默认借期 3 天（解析器未给 days 时用默认）。
  ///
  /// V3.10（PM 拍板②）：借出数量超过实有的**拦截**并给出中文提示
  /// 「家里只有N个，可借M个」，不允许记负数。
  /// 拍板④：没记录过的东西不能直接借出，引导先录入。
  Future<void> _handleLend(ParseLend parsed) async {
    try {
      final loan = await widget.repository.lendItem(
        parsed.item,
        parsed.borrower,
        quantity: parsed.quantity,
        days: parsed.days,
      );
      if (!mounted) return;
      final days = parsed.days ?? InventoryDatabase.defaultLoanDays;
      final where = await _itemLocationSuffix(loan.itemName);
      if (!mounted) return;
      // V3.10：回显剩余可借数，用户能立刻知道账面对不对。
      final info = await widget.repository.getQuantityInfo(loan.itemName);
      if (!mounted) return;
      final rest = info.available > 0 ? '，还剩 ${info.available} 个在家' : '';
      setState(() {
        _busy = false;
        _notice = '已借出：${loan.itemName} → ${loan.borrowerName}'
            '（${loan.quantity} 个 · $days 天）$where$rest';
        _result = null;
      });
    } on ArgumentError catch (e) {
      // V3.10：借超 / 没记录过 —— 用友好中文说明，不弹技术错误。
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = e.message is String ? e.message : '借出没成功，什么都没改。';
        _result = null;
      });
    }
  }

  /// 物品当前位置标签（V3.8）。
  ///
  /// PM 真机反馈：借出/归还只显示物品名和借阅人，看不出东西放在哪儿。
  /// 取物品明细页同一份数据（当前未删位置），位置多时用「、」并列。
  /// 返回可直接拼在提示末尾的后缀，如「 · 在阳台」。
  Future<String> _itemLocationSuffix(String itemName) async {
    final all = await widget.repository.getAllItemsWithLocations();
    if (!mounted) return '';
    final key = normalizeName(itemName);
    final hit = all.where((i) => i.item.name == key).firstOrNull;
    if (hit == null) return ' · 位置未记录';
    final names = hit.locations.map((l) => l.name).toSet().toList()..sort();
    if (names.isEmpty) return ' · 位置未记录';
    return ' · 在${names.join('、')}';
  }

  /// V3.7 缺陷修复：语音归还落库。
  ///
  /// V3.8 重构（PM 真机反馈）：「还了1个梯子」没说是谁还的——
  /// 同一件东西两人各借一份时，按最早一笔静默记账会记到错的人头上。
  /// 现在分三种情形：
  ///  ① 句中指名（「张三还了1个梯子」「还了1个梯子给张三」）→ 精确命中那人的
  ///     未还清记录；同一人多笔时取最早一笔（元宝批复 FIFO 口径不变）。
  ///  ② 句中没指名且该物品只有一笔未还清 → 无歧义，直接还。
  ///  ③ 句中没指名且有多笔未还清 → 弹候选框让用户点是谁还的，
  ///     绝不静默记账；同时提示可说「还了1个梯子给张三」。
  Future<void> _handleReturn(ParseReturn parsed) async {
    final loans = await widget.repository.getAllLoans();
    if (!mounted) return;
    final key = normalizeName(parsed.item);
    final outstanding = loans
        .where((l) => l.itemName == key && !l.isReturned)
        .toList(growable: false);
    // getAllLoans 按借出时间倒序 → 逆序即最早借出在前（FIFO 展示顺序）。
    final fifo = outstanding.reversed.toList(growable: false);

    final named = parsed.borrower;
    if (named != null && named.isNotEmpty) {
      final mine =
          fifo.where((l) => l.borrowerName == named).toList(growable: false);
      if (mine.isEmpty) {
        // 指名的人没借这笔——不猜，把候选亮出来让用户改口或取消。
        setState(() {
          _busy = false;
          _notice = _noSuchBorrowerNotice(parsed.item, named, fifo);
          _result = null;
        });
        return;
      }
      await _doReturn(mine.first, parsed.quantity);
      return;
    }

    if (fifo.isEmpty) {
      setState(() {
        _busy = false;
        _notice = '没有借出的${parsed.item}可还。';
        _result = null;
      });
      return;
    }
    if (fifo.length == 1) {
      await _doReturn(fifo.first, parsed.quantity);
      return;
    }

    // 多笔未还清且句子没指名 → 弹候选让用户点。
    final picked = await _pickReturnBorrower(parsed.item, fifo);
    if (!mounted) return;
    if (picked == null) {
      setState(() {
        _busy = false;
        _notice = '已取消归还。';
        _result = null;
      });
      return;
    }
    await _doReturn(picked, parsed.quantity);
  }

  /// 执行归还并回显（沿用元宝批复①③口径：反馈带借阅人 + 数量 + 剩余）。
  Future<void> _doReturn(Loan hit, int? requestedQty) async {
    await widget.repository.returnLoan(hit.id!, quantity: requestedQty);
    if (!mounted) return;
    // 本次归还量：给定值=部分归还；未给=把该笔剩余一次还清。
    final qty = requestedQty ?? hit.quantity - hit.returnedQty;
    // 该笔借出归还后的剩余（基于归还前快照计算，含 0=已还清）。
    final remaining = hit.quantity - hit.returnedQty - qty;
    final left = remaining < 0 ? 0 : remaining;
    // V3.8：反馈带位置标签——PM 真机反馈「归还的物品没有位置标签」。
    final where = await _itemLocationSuffix(hit.itemName);
    if (!mounted) return;
    // V3.10：归还后家里有几个（账实对齐的直观体现）。
    final info = await widget.repository.getQuantityInfo(hit.itemName);
    if (!mounted) return;
    final stockText = '，家里现在 ${info.stock} 个';
    setState(() {
      _busy = false;
      // 元宝批复补充①③：反馈必须带借阅人（FIFO 命中谁一目了然，
      // 避免用户以为还的是李四、实际扣了张三账），且与借出文案对称。
      _notice = '已归还：${hit.itemName} → ${hit.borrowerName}'
          '（$qty 个 · 还剩 $left 个）$where$stockText';
      _result = null;
    });
  }

  /// 归还归属候选框：同一物品有多笔未还清时，让用户点是谁还的。
  /// 候选用 ListTile（大触控区、文字标签），无图标——避开 M3 吞色。
  Future<Loan?> _pickReturnBorrower(String item, List<Loan> candidates) async {
    return showDialog<Loan>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('return_picker_dialog'),
        title: Text('「$item」是谁还的？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text('这件东西有多笔没还，请点一下是谁还的。',
                  style: TextStyle(fontSize: 13, color: Color(0xff607d8b))),
              const SizedBox(height: 4),
              Text('也可以直接说：还了1个$item给张三',
                  style: TextStyle(fontSize: 13, color: Color(0xff607d8b))),
              const SizedBox(height: 8),
              for (final loan in candidates)
                ListTile(
                  key: Key('return_pick_${loan.borrowerName}_${loan.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(loan.borrowerName,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    '借出 ${_loanDate(loan.borrowedAt)} · 已还 ${loan.returnedQty}/${loan.quantity}',
                    style: const TextStyle(fontSize: 12.5, color: Color(0xff607d8b)),
                  ),
                  onTap: () => Navigator.of(context).pop(loan),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('return_picker_cancel'),
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// 指名的借阅人没有这笔未还清记录时的提示（列出真实候选，避免死路）。
  String _noSuchBorrowerNotice(String item, String named, List<Loan> candidates) {
    if (candidates.isEmpty) {
      return '没有借出的$item可还。';
    }
    final who = candidates.map((l) => l.borrowerName).toSet().join('、');
    return '没有借给「$named」的$item未还记录。\n'
        '「$item」现在借给：$who。可以改口说：还了1个$item给谁。';
  }

  // ============ V3.9 语音化第一批：废弃 / 恢复 / 改借期 ============

  /// 通用二次确认框（破坏性操作统一走这里）。
  ///
  /// 团队原则：破坏性操作必须二次确认——语音说的话不直接落库，
  /// 尤其"废弃"和"改借期"会改掉账，得让用户看见会发生什么再点头。
  Future<bool> _confirmAction(String title, String content,
      {String confirmLabel = '确定'}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('action_confirm_dialog'),
        title: Text(title),
        content: Text(content),
        actions: <Widget>[
          TextButton(
            key: const Key('action_confirm_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('action_confirm_ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// V3.9：语音废弃——「梯子废弃了」→ 从明细转入回收站。
  ///
  /// PM 拍板（2026-11-24）：借出中的物品**先自动归还再废弃**，
  /// 不是禁止。确认框里明说会先归还给谁，不搞黑箱。
  Future<void> _handleDiscard(ParseDiscard parsed) async {
    final key = normalizeName(parsed.item);
    final all = await widget.repository.getAllItemsWithLocations();
    if (!mounted) return;
    // V3.9.1 真机打回（PM 场景②）：精确优先，找不到再按词根兜底——
    // 历史脏数据把物品建成「梯子借」，用户说「梯子」也要能命中它。
    var hits =
        all.where((i) => i.item.name == key).toList(growable: false);
    if (hits.isEmpty) {
      hits = all.where((i) => itemNamesMatch(i.item.name, key)).toList(growable: false);
    }
    if (hits.isEmpty || hits.first.item.id == null) {
      final deleted = await widget.repository.getDeletedItems();
      if (!mounted) return;
      final inTrash = deleted
          .where((i) => i.item.name == key || itemNamesMatch(i.item.name, key))
          .firstOrNull;
      setState(() {
        _busy = false;
        _notice = inTrash != null
            ? '「${parsed.item}」已经在回收站里了。'
            : '没有找到「${parsed.item}」，没法废弃。';
        _result = null;
      });
      return;
    }
    // 同词根的其它记录（如历史脏名「梯子借」）是同一件东西的两条记录，
    // 一并处理掉，别让脏副本继续挂在明细里。
    final primary = hits.first;
    final targets = all
        .where((i) => hits.any((h) => h.item.id == i.item.id) ||
            itemNamesMatch(i.item.name, key))
        .toList(growable: false);
    final names = targets.map((t) => t.item.name).toSet().toList(growable: false);
    final extraNames =
        names.where((n) => n != primary.item.name).toList(growable: false);

    // 借出中的物品：先自动归还（PM 拍板）。
    // 按物品名匹配未还清借出（语音本来就是按名字说的，不依赖 item_id 一致性）。
    final loans = await widget.repository.getAllLoans();
    if (!mounted) return;
    final sameItem = loans
        .where((l) => itemNamesMatch(l.itemName, key) && !l.isReturned)
        .toList(growable: false);

    // V3.9.2（PM 真机复验新缺陷）：句中指名了借阅人时，**只处理他那一笔**。
    // 旧实现把同词根所有在借记录全量归还——用户说「借给王五的梯子废弃了」，
    // 却把李四、张三的账也一并清零，别人在借的记录被无辜清零，账乱了。
    // 无指名时才沿用全量归还（PM V3.9 拍板口径：借出中的物品废弃 → 先自动归还）。
    final wanted = parsed.borrower;
    var toReturn = sameItem;
    if (wanted != null) {
      final mine =
          sameItem.where((l) => l.borrowerName == wanted).toList(growable: false);
      if (mine.isEmpty) {
        final who = sameItem.map((l) => l.borrowerName).toSet().join('、');
        setState(() {
          _busy = false;
          _notice = sameItem.isEmpty
              ? '「${parsed.item}」现在没有借出去，没有要归还的记录。'
              : '「${parsed.item}」现在借给$who，没有$wanted的借出记录。';
          _result = null;
        });
        return;
      }
      if (mine.length == 1) {
        toReturn = mine;
      } else {
        // 同一借阅人多笔在借 → 弹候选问是哪一笔，不替他猜。
        final picked = await _pickDiscardLoan(mine, wanted);
        if (!mounted) return;
        if (picked == null) {
          setState(() {
            _busy = false;
            _notice = '已取消废弃，什么都没改。';
            _result = null;
          });
          return;
        }
        toReturn = <Loan>[picked];
      }
    }
    // 本次不动、仍留在「在借」里的记录（点名场景下的其他人）。
    final untouched = sameItem
        .where((l) => !toReturn.any((r) => r.id == l.id))
        .toList(growable: false);

    final who = toReturn.map((l) => l.borrowerName).toSet().join('、');
    // 可能同时命中干净名与历史脏名（"梯子"与"梯子借"），都摆出来，
    // 别让用户以为只处理了一条。
    final loanNames =
        toReturn.map((l) => l.itemName).toSet().toList(growable: false);
    final loanNameText = loanNames.length <= 1
        ? (loanNames.isEmpty ? parsed.item : loanNames.first)
        : loanNames.join('、');
    final extraNote = extraNames.isEmpty
        ? ''
        : '\n（另有一条历史记录「${extraNames.join('、')}」是同一件东西，会一起转入回收站）';

    // 指名时写明"只还这一笔、其余不动"；未指名时写明"全部自动归还"。
    final String body;
    if (wanted != null && toReturn.length == 1) {
      final hit = toReturn.first;
      final others = untouched
          .map((l) => l.borrowerName)
          .toSet()
          .where((n) => n != wanted)
          .toList(growable: false);
      final othersNote = others.isEmpty
          ? ''
          : '\n（${others.join('、')}借的那几笔不动，他们还借着。）';
      body = '「$loanNameText」借给$who（${hit.quantity - hit.returnedQty} 个）。\n'
          '会先归还$wanted，再转入回收站。$othersNote$extraNote\n确定吗？';
    } else if (toReturn.isEmpty) {
      body = '把「${parsed.item}」转入回收站？$extraNote\n之后可以在回收站里恢复。';
    } else {
      body = '「$loanNameText」现在借给$who。\n'
          '会先自动归还，再转入回收站。$extraNote\n确定吗？';
    }

    final confirmed = await _confirmAction(
      '废弃「${parsed.item}」',
      body,
      confirmLabel: '转入回收站',
    );
    if (!mounted) return;
    if (!confirmed) {
      setState(() {
        _busy = false;
        _notice = '已取消废弃，什么都没改。';
        _result = null;
      });
      return;
    }

    for (final loan in toReturn) {
      await widget.repository.returnLoan(
        loan.id!,
        quantity: loan.quantity - loan.returnedQty,
      );
    }
    for (final target in targets) {
      final targetId = target.item.id;
      if (targetId == null) continue;
      await widget.repository.deleteItem(targetId);
    }
    if (!mounted) return;
    final others = untouched
        .map((l) => l.borrowerName)
        .toSet()
        .where((n) => n != wanted)
        .toList(growable: false);
    setState(() {
      _busy = false;
      final untouchedNote = others.isEmpty ? '' : '，${others.join('、')}的借出没动';
      _notice = toReturn.isEmpty
          ? '已把「${parsed.item}」转入回收站。'
          : '已先归还给$who，再把「${parsed.item}」转入回收站$untouchedNote。';
      _result = null;
    });
  }

  /// 废弃候选框：同一借阅人多笔在借时让用户点是哪一笔
  /// （与改借期候选同一口径，不替用户猜）。
  Future<Loan?> _pickDiscardLoan(List<Loan> candidates, String borrower) async {
    return showDialog<Loan>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('discard_picker_dialog'),
        title: Text('废弃$borrower的哪一笔？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final loan in candidates)
                ListTile(
                  key: Key('discard_pick_${loan.borrowerName}_${loan.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('${loan.itemName} → ${loan.borrowerName}',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    '借出 ${_loanDate(loan.borrowedAt)} · 到期 ${_loanDate(loan.dueAt)}',
                    style: const TextStyle(
                        fontSize: 12.5, color: Color(0xff607d8b)),
                  ),
                  onTap: () => Navigator.of(context).pop(loan),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('discard_picker_cancel'),
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// V3.9：语音恢复——「恢复梯子」→ 从回收站回到明细。
  ///
  /// PM 拍板：明细里已有同名物品时**合并数量**（不再报错拒绝），
  /// 回显要说明"并进去了、现在共几个"。
  Future<void> _handleRestore(ParseRestore parsed) async {
    final key = normalizeName(parsed.item);
    final deleted = await widget.repository.getDeletedItems();
    if (!mounted) return;
    // V3.9.1：精确优先，找不到再按词根兜底（历史脏名「梯子借」）。
    var hit = deleted.where((i) => i.item.name == key).firstOrNull;
    hit ??= deleted.where((i) => itemNamesMatch(i.item.name, key)).firstOrNull;
    if (hit == null || hit.item.id == null) {
      setState(() {
        _busy = false;
        _notice = '回收站里没有「${parsed.item}」。';
        _result = null;
      });
      return;
    }
    final all = await widget.repository.getAllItemsWithLocations();
    if (!mounted) return;
    var live = all.where((i) => i.item.name == key).firstOrNull;
    live ??= all.where((i) => itemNamesMatch(i.item.name, key)).firstOrNull;
    final confirmed = await _confirmAction(
      '恢复「${parsed.item}」',
      live == null
          ? '把「${parsed.item}」恢复到物品明细？'
          : '明细里已经有一个「${parsed.item}」了。\n'
              '恢复会并进去（数量合起来）。\n确定吗？',
      confirmLabel: '恢复',
    );
    if (!mounted) return;
    if (!confirmed) {
      setState(() {
        _busy = false;
        _notice = '已取消恢复，什么都没改。';
        _result = null;
      });
      return;
    }
    final outcome = await widget.repository.restoreItem(hit.item.id!);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _notice = outcome.merged
          ? '已恢复「${outcome.itemName}」，并入明细里已有的同名物品'
              '（现有 ${outcome.totalQuantity} 个）。'
          : '已恢复「${outcome.itemName}」到物品明细。';
      _result = null;
    });
  }

  /// V3.9：语音改借期——「梯子借期改成5天」。
  ///
  /// 元宝补充③：已还清的记录不允许改借期，如实提示「这笔已还清，改不了」。
  /// 「缩短」本批不支持（没有催还机制，支持了也无效）。
  Future<void> _handleDueChange(ParseDueChange parsed) async {
    final loans = await widget.repository.getAllLoans();
    if (!mounted) return;
    var candidates =
        loans.where((l) => !l.isReturned).toList(growable: false);
    if (parsed.item != null) {
      final key = normalizeName(parsed.item!);
      final exact =
          candidates.where((l) => l.itemName == key).toList(growable: false);
      // V3.9.1 真机打回（PM 场景④）：兜底按词根匹配——历史脏数据把借出记录
      // 挂在「梯子借」上，用户说「梯子」也必须能找到那笔，否则改不了借期。
      candidates = exact.isNotEmpty
          ? exact
          : candidates
              .where((l) => itemNamesMatch(l.itemName, key))
              .toList(growable: false);
    }
    if (parsed.borrower != null) {
      candidates = candidates
          .where((l) => l.borrowerName == parsed.borrower)
          .toList(growable: false);
    }
    if (candidates.isEmpty) {
      // 元宝补充③：命中的其实是已还清记录 → 如实说改不了。
      final doneHit = loans.any((l) =>
          l.isReturned &&
          (parsed.item == null ||
              (l.itemName == normalizeName(parsed.item!) ||
                  itemNamesMatch(l.itemName, parsed.item!))) &&
          (parsed.borrower == null || l.borrowerName == parsed.borrower));
      setState(() {
        _busy = false;
        _notice = doneHit ? '这笔已还清，改不了。' : '没有找到可以改借期的借出记录。';
        _result = null;
      });
      return;
    }

    Loan? target;
    if (candidates.length == 1) {
      target = candidates.first;
    } else {
      target = await _pickDueLoan(candidates);
      if (!mounted) return;
      if (target == null) {
        setState(() {
          _busy = false;
          _notice = '已取消改借期，什么都没改。';
          _result = null;
        });
        return;
      }
    }
    final hit = target;

    // extendBy：在当前借期上追加；set：直接设为总天数。
    var days = parsed.days;
    if (parsed.mode == DueChangeMode.extendBy) {
      final currentDays = ((hit.dueAt - hit.borrowedAt) / 86400000).ceil();
      days = currentDays + parsed.days;
    }
    if (days < 1) days = 1;

    final confirmed = await _confirmAction(
      '改借期',
      '把「${hit.itemName}」（借给${hit.borrowerName}）的借期改成 $days 天？\n'
          '原到期 ${_loanDate(hit.dueAt)}。',
      confirmLabel: '改借期',
    );
    if (!mounted) return;
    if (!confirmed) {
      setState(() {
        _busy = false;
        _notice = '已取消改借期，什么都没改。';
        _result = null;
      });
      return;
    }
    await widget.repository.updateLoanDue(hit.id!, days);
    if (!mounted) return;
    final newDue = hit.borrowedAt + days * 86400000;
    setState(() {
      _busy = false;
      _notice = '已改借期：${hit.itemName} → ${hit.borrowerName}'
          '（$days 天，到期 ${_loanDate(newDue)}）';
      _result = null;
    });
  }

  /// 改借期候选框：多笔未还清时让用户点是哪一笔（与归还候选同一口径）。
  Future<Loan?> _pickDueLoan(List<Loan> candidates) async {
    return showDialog<Loan>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('due_picker_dialog'),
        title: const Text('改哪一笔的借期？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final loan in candidates)
                ListTile(
                  key: Key('due_pick_${loan.borrowerName}_${loan.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('${loan.itemName} → ${loan.borrowerName}',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    '借出 ${_loanDate(loan.borrowedAt)} · 到期 ${_loanDate(loan.dueAt)}',
                    style: const TextStyle(
                        fontSize: 12.5, color: Color(0xff607d8b)),
                  ),
                  onTap: () => Navigator.of(context).pop(loan),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('due_picker_cancel'),
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// V3.9：歧义处理——「梯子不要了放阳台」有两种理解，弹框让用户选。
  ///
  /// 元宝补充①：不强行选废弃，报歧义让用户点。
  Future<void> _handleAmbiguous(ParseAmbiguous parsed) async {
    final picked = await showDialog<ParseResult>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('ambiguous_dialog'),
        title: const Text('这句有两种理解'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(parsed.hint,
                  style: const TextStyle(
                      fontSize: 13.5, color: Color(0xff37474f))),
              const SizedBox(height: 8),
              for (final candidate in parsed.candidates)
                ListTile(
                  key: Key('ambiguous_pick_${candidate.runtimeType}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(_ambiguousLabel(candidate),
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  onTap: () => Navigator.of(context).pop(candidate),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('ambiguous_cancel'),
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (picked == null) {
      setState(() {
        _busy = false;
        _notice = '已取消，什么都没改。';
        _result = null;
      });
      return;
    }
    if (picked is ParseDiscard) {
      await _handleDiscard(picked);
    } else if (picked is ParseUpsert) {
      await _handleUpsert(picked, '');
    } else if (picked is ParseRestore) {
      await _handleRestore(picked);
    } else {
      setState(() {
        _busy = false;
        _notice = '没听懂，什么都没改。';
        _result = null;
      });
    }
  }

  /// 歧义候选项的展示文案。
  String _ambiguousLabel(ParseResult candidate) {
    if (candidate is ParseDiscard) {
      return '把「${candidate.item}」转入回收站（废弃）';
    }
    if (candidate is ParseUpsert) {
      return '把「${candidate.item}」放到${candidate.location}';
    }
    if (candidate is ParseRestore) {
      return '把「${candidate.item}」恢复到明细';
    }
    return '按这个理解';
  }

  /// 借出日期（本地显示，月/日）。
  String _loanDate(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.month}/${t.day}';
  }

  // V3.4：首页手动添加位置入口（_addLocation）撤下——手动添加能力
  // 统一收敛至抽屉 → 位置管理页（含备注录入、空名校验、错误兜底）。

  /// 按 id 取仓储中的归一化位置名，回显与入库一致。
  Future<String> _locationName(int id) async {
    final locations = await widget.repository.getAllLocations();
    return locations
            .where((l) => l.id == id)
            .map((l) => l.name)
            .firstOrNull ??
        '';
  }

  void _show(String message) {
    setState(() {
      _notice = message;
      _result = null;
    });
  }

  /// 多位置文案（V3 文档：展示物品所在位置）。
  String _multiLocationText(ItemWithLocations result) {
    final names = result.locations.map((l) => l.name).join('、');
    return '「${result.item.name}」在：$names（共${result.locations.length}处）。';
  }

  // ---------- 导航（V3.1 导航优化：抽屉为主动线，图标/文字为兜底） ----------

  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  /// 子页全屏路由（V3.5 修订单：全屏切换 + 返回栈正确——
  /// MaterialPageRoute 返回键回首页，底栏高亮不变）。
  void _push(Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  /// V3.10（PM 补充要求2）：打开「校准数量」清点页。
  ///
  /// 页面让用户照着实物清点「家里一共几个」，减掉借出去的在借数，
  /// 写回真正的在库数——真实家底只存在于用户脑子里，App 算不出来。
  /// 页面返回时带回结果文案，如实说明改了几件。
  Future<void> _openCalibration() async {
    final message = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => CalibrationPage(repository: widget.repository),
      ),
    );
    if (!mounted || message == null) return;
    setState(() {
      _notice = message;
      _result = null;
    });
  }

  /// V3.5：底栏切换一级模块。抽屉若已打开，仅切换内容不重复弹动画；
  /// 关闭态则切换后自动弹出——修订单原文「点击一级按钮 → 左侧菜单
  /// 仅展示该模块子菜单」，给占位模块即时可见反馈（真机缺陷修复：
  /// 此前只切状态不弹抽屉，叠加 ☰ 不可见导致占位模块零反馈）。
  void _selectModule(int index) {
    final scaffold = _scaffoldKey.currentState;
    final drawerWasOpen = scaffold?.isDrawerOpen ?? false;
    if (drawerWasOpen) {
      Navigator.of(context).pop();
    }
    setState(() => _moduleIndex = index);
    if (!drawerWasOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scaffoldKey.currentState?.openDrawer();
        }
      });
    }
  }

  /// 底栏一级模块图标（V3.5 方案简报）。
  IconData _moduleIcon(_HomeModule module) {
    switch (module) {
      case _HomeModule.storage:
        return Icons.inventory_2;
      case _HomeModule.schedule:
        return Icons.event_note;
      case _HomeModule.knowledge:
        return Icons.menu_book;
      case _HomeModule.dining:
        return Icons.restaurant;
      case _HomeModule.wardrobe:
        return Icons.checkroom;
    }
  }

  /// 占位模块子项（决策点①A：渲染「建设中」ListTile，
  /// 决策点③：点击仅提示，不进空白假页）。
  Widget _buildingTile(_HomeModule module) {
    return ListTile(
      key: Key('drawer_building_${module.name}'),
      leading: const Icon(Icons.construction),
      title: Text('${module.label}（建设中）'),
      subtitle: const Text('该模块规划中，敬请期待'),
      onTap: () {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            key: Key('building_snackbar_${module.name}'),
            content: Text('${module.label}模块建设中，敬请期待'),
          ),
        );
      },
    );
  }

  /// V3.8：句式格式标准卡片（输入框正下方）。
  ///
  /// PM 真机反馈：「如果借出语句有格式要求的话，把格式标准输入框下面」——
  /// 用户不知道借出/归还该怎么说，试着说失败还以为是 App 坏了。
  /// 这里把四类句式一次性列清（含数量与「是谁还的」的指名说法），
  /// 纯文字展示、无图标，规避 M3 主题吞色。
  Widget _buildSyntaxGuide() {
    return Container(
      key: const Key('phrase_syntax_guide'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xfff1f8f2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffc8e6c9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '怎么说（句式标准）',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xff1b5e20),
            ),
          ),
          const SizedBox(height: 6),
          _syntaxRow('放东西', '梯子放阳台｜3个梯子放阳台｜再放2个梯子'),
          _syntaxRow('查东西', '梯子在哪'),
          _syntaxRow('借出', '借给张三2个梯子｜张三借走了2个梯子｜梯子被张三借走了'),
          _syntaxRow('归还', '张三还了1个梯子｜还了1个梯子给张三'),
          // V3.9 语音化第一批：三个新意图的句式一并列进来，
          // 否则用户不知道能这么说。
          // V3.9.2：废弃句补指名说法——「借给王五的梯子废弃了」只动王五那笔账。
          _syntaxRow('废弃', '梯子废弃了｜借给王五的梯子废弃了'),
          _syntaxRow('恢复', '恢复梯子'),
          _syntaxRow('改借期', '梯子借期改成5天｜再借3天'),
          const SizedBox(height: 2),
          const Text(
            '借出/归还都建议带上人名；不说人名时，若同一件东西有多笔没还，'
            '会问你是谁还的。废弃/恢复/改借期会先弹确认框，点头才执行；'
            '废弃带人名时只处理那一个人的账，别人的借出不动。'
            '说「N个」是改数量，「再放N个」是再加N个。',
            style: TextStyle(fontSize: 12, color: Color(0xff607d8b)),
          ),
        ],
      ),
    );
  }

  /// 句式标准的一行（类别 + 示例）。用两个独立 Text（而非 RichText），
  /// 保证文本可被无障碍/自动化按字面检索。
  Widget _syntaxRow(String label, String samples) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$label：',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Color(0xff1b5e20),
            ),
          ),
          Expanded(
            child: Text(
              samples,
              style: const TextStyle(fontSize: 12.5, color: Color(0xff37474f)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      key: const Key('home_drawer'),
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: <Widget>[
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '家庭仓储布局',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  // V3.5：副标题随当前模块显示（审核意见 7）。
                  Text(
                    '${_HomeModule.values[_moduleIndex].label}模块',
                    key: Key('drawer_module_subtitle'),
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
            // V3.5：抽屉按 currentModule 渲染子菜单——仓储为真实四项，
            // 其余模块为「建设中」占位（不做假功能、不做弹窗式子菜单）。
            if (_moduleIndex == 0) ...<Widget>[
              ListTile(
                key: const Key('drawer_voice'),
                leading: const Icon(Icons.mic_none),
                title: const Text('语音记账'),
                subtitle: const Text('说一句记下 / 查（当前页）'),
                onTap: () => Navigator.of(context).pop(),
              ),
              ListTile(
                key: const Key('drawer_locations'),
                leading: const Icon(Icons.place_outlined),
                title: const Text('位置管理'),
                subtitle: const Text('位置列表、备注、增删改'),
                onTap: () {
                  Navigator.of(context).pop();
                  _push(LocationListPage(repository: widget.repository));
                },
              ),
              ListTile(
                key: const Key('drawer_items'),
                leading: const Icon(Icons.list_alt),
                title: const Text('物品明细'),
                subtitle: const Text('全部物品与存放位置，可搜索'),
                onTap: () {
                  Navigator.of(context).pop();
                  _push(ItemListPage(repository: widget.repository));
                },
              ),
              ListTile(
                key: const Key('drawer_backup'),
                leading: const Icon(Icons.backup_outlined),
                title: const Text('数据备份与恢复'),
                subtitle: const Text('导出 JSON / 从文件恢复'),
                onTap: () {
                  Navigator.of(context).pop();
                  _push(BackupPage(repository: widget.repository));
                },
              ),
              // V3.7：借出管理（元宝决策③A，排最后；不动五模块底栏）。
              ListTile(
                key: const Key('drawer_loans'),
                leading: const Icon(Icons.swap_horiz),
                title: const Text('借出管理'),
                subtitle: const Text('借出/归还/逾期提醒'),
                onTap: () {
                  Navigator.of(context).pop();
                  _push(LoanListPage(repository: widget.repository));
                },
              ),
              // V3.10（PM 补充要求2）：「校准数量」工具入口。
              // 老库的物品数量恒为 1（V3.7 引入后录入数量一直被丢弃），
              // 与真实家底对不上；真实家底只在用户脑子里，所以让用户
              // 照着实物清点「家里一共几个」，工具减掉在借数写回在库数。
              ListTile(
                key: const Key('drawer_calibrate'),
                leading: const Icon(Icons.tune),
                title: const Text('校准数量'),
                subtitle: const Text('照实物清点，把数量改准'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openCalibration();
                },
              ),
            ] else ...<Widget>[
              // V3.5 补丁（PM 2026-11-22）：占位项收敛——选中哪个
              // 非仓储模块，只渲染该模块自己的一条「建设中」占位项，
              // 与决策点①A「各渲染一个」口径一致。
              _buildingTile(_HomeModule.values[_moduleIndex]),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        // V3.3 导航收敛：入口统一为左上角三道杠；
        // V1 遗留的右上角列表图标已撤下（明细页经抽屉进入）。
        // V3.4.1：AppBar 反转为深色底 + 亮色标题（真机已验证生效）。
        // V3.5.1 真机缺陷修复：V3.4/V3.4.1 两轮通过 IconButton.color
        // 设色，widget 断言锁的是参数值，真机上 ☰ 均不渲染——
        // 本轮把颜色/尺寸直接写死在 Icon 本体上，绕过 M3 样式
        // 继承链；白色 + 深绿底对比最大。
        leading: IconButton(
          key: const Key('open_drawer'),
          tooltip: '菜单',
          iconSize: 28,
          color: Colors.white,
          icon: const Icon(Icons.menu, size: 28, color: Colors.white),
          onPressed: _openDrawer,
        ),
      ),
      drawer: _buildDrawer(),
      // V3.5 五模块底栏（决策点②：浅色底深色图标，与内容区一致、
      // 与深色 AppBar 上下呼应；fixed 类型为 >3 项必需，避免
      // shifting 折叠文字）。仓储默认选中（唯一可用模块）。
      bottomNavigationBar: BottomNavigationBar(
        key: const Key('home_bottom_nav'),
        currentIndex: _moduleIndex,
        type: BottomNavigationBarType.fixed,
        onTap: _selectModule,
        items: <BottomNavigationBarItem>[
          for (final module in _HomeModule.values)
            BottomNavigationBarItem(
              icon: Icon(_moduleIcon(module)),
              label: module.label,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text('说一句，记下或查找',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('记「梯子放阳台」｜查「梯子在哪」',
                style: TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 8),
            TextField(
              key: const Key('phrase_field'),
              controller: _phraseController,
              decoration: const InputDecoration(
                labelText: '说一句',
                hintText: '例如：梯子放阳台',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}), // 刷新「确定」禁用态
              onSubmitted: (_) => _busy ? null : _submitPhrase(),
            ),
            const SizedBox(height: 8),
            // V3.8：句式格式标准常驻输入框正下方（PM 真机反馈：
            // 「如果借出语句有格式要求的话，把格式标准输入框下面」）。
            // 静态展示四类句式，纯文字无图标，避开 M3 吞色。
            _buildSyntaxGuide(),
            const SizedBox(height: 4),
            // 技术审核条件①/文档第七章：隐私与准确率由输入法决定，弱提示常驻。
            // V3.3：文案去技术味（口径不变：12px 灰色、常驻展示）。
            const Text('语音由系统输入法处理',
                key: Key('voice_hint'),
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            // V3.4.1 修订（P1 首屏补内容）：轻量示例引导，让用户
            // 一眼知道怎么用；与合规提示分开，纯静态展示。
            const Text('试试说：梯子放阳台，或：梯子在哪',
                key: Key('sample_hint'),
                style: TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('submit_button'),
              onPressed: (_busy || _phraseController.text.trim().isEmpty)
                  ? null
                  : _submitPhrase,
              child: const Text('确定'),
            ),
            const SizedBox(height: 12),
            // V3.4：首页撤「管理位置」整块（标题/输入框/添加按钮/分隔线），
            // 查询与记录统一走顶部「说一句」，手动添加走抽屉 → 位置管理。
            // 首页收口三层：语音主入口 + 「已记下/已更新」提示展示 + 底部引导文字。
            if (_notice != null) ...[
              const SizedBox(height: 12),
              Text(_notice!, key: const Key('notice')),
            ],
            if (_result != null) ...[
              const SizedBox(height: 8),
              Text(_multiLocationText(_result!),
                  key: const Key('result_line'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              for (final location in _result!.locations)
                ListTile(
                  key: Key('result_location_${location.id}'),
                  leading: const Icon(Icons.place_outlined),
                  title: Text(location.name),
                ),
            ],
            // V3.3 导航收敛：底部兜底「打开菜单」按钮已撤下（入口统一
            // 左上角三道杠），原位置保留一行静态引导文字——纯提示、
            // 无任何点击响应（Text 无手势），防「入口看不到」复发。
            const SizedBox(height: 16),
            const Text(
              '管理物品 / 位置 / 备份：点左上角 ☰ 菜单',
              key: Key('home_menu_hint'),
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
