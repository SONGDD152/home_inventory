// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/inventory_repository.dart';
import '../data/item.dart';
import '../data/phrase_parser.dart';

/// 家庭仓储 APP 第一版界面：单页，单句式输入框（录入 + 查询共用）。
///
/// 范围边界（产品与技术负责人已确认，见 V1_ACCEPTANCE.md）：
///  * 交互为单入口：一个句式框——「<物品>放<位置>」录入、「<物品>在哪」查询；
///  * parsePhrase 纯函数解析三态，未识别走「没听懂」且零写入；
///  * 句式录入的位置若不存在，自动新建（由归一化结果驱动，经仓储 addLocation）；
///  * 单一归一化入口：名字一律经仓储边界 normalizeName，UI 不自行预处理；
///  * 三张表存储、不做删除/语音/多端同步；单人本地。
///
/// [repository] 由外部注入，便于测试注入内存实现（见 InventoryRepository）。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.repository, this.title = '家庭仓储'});

  final InventoryRepository repository;
  final String title;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _phraseController = TextEditingController();
  final TextEditingController _newLocationController = TextEditingController();

  String? _notice;
  ItemWithLocations? _result;
  bool _busy = false;

  // 七处冻结文案（逐字符合 V1_ACCEPTANCE.md，测试按字符串断言）。
  static const String _notUnderstood =
      '没听懂，请这样说："XX放YY"记位置，或"XX在哪"查位置。';
  static const String _emptyLocation = '位置名称不能为空。';

  static String _notFound(String item) => '没有找到「$item」的记录。';
  static String _recorded(String item, String location) =>
      '已记下：「$item」放在「$location」。';
  static String _alreadyRecorded(String item, String location) =>
      '「$item」已经在「$location」了。';
  static String _locationAdded(String location) => '已添加位置：「$location」。';

  @override
  void dispose() {
    _phraseController.dispose();
    _newLocationController.dispose();
    super.dispose();
  }

  /// 添加位置显式入口（D1 保留）。独立文本框、不经 parsePhrase。
  /// 位置名原文交给仓储 addLocation（仓储边界归一化），UI 不预处理值。
  Future<void> _addLocation() async {
    final name = _newLocationController.text;
    // 仅做空判断以贴合冻结文案「位置名称不能为空」；
    // 归一化由仓储边界负责，正常值不改、原文传入。
    if (name.trim().isEmpty) {
      _show(_emptyLocation);
      return;
    }
    setState(() => _busy = true);
    try {
      final id = await widget.repository.addLocation(name);
      if (!mounted) return;
      _newLocationController.clear();
      // 回显用仓储返回的归一化名（按 id 取），保证与入库值一致。
      final nameInDb = await _locationName(id);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = _locationAdded(nameInDb);
        _result = null;
      });
    } on ArgumentError {
      if (!mounted) return;
      // 归一化后为空等非空输入无法表达的问题，一律落到空位置名提示，
      // 不出现「失败/错误」措辞。
      setState(() {
        _busy = false;
        _notice = _emptyLocation;
        _result = null;
      });
    }
  }

  /// 句式主入口：parsePhrase 解析 → 三态分支。
  Future<void> _submitPhrase() async {
    final parsed = parsePhrase(_phraseController.text);

    if (parsed is ParseUnrecognized) {
      // 未识别：零写入，只提示「没听懂」。无"空名称"类提示。
      _show(_notUnderstood);
      return;
    }

    setState(() => _busy = true);
    try {
      if (parsed is ParseQuery) {
        await _handleQuery(parsed.item);
      } else if (parsed is ParseUpsert) {
        await _handleUpsert(parsed.item, parsed.location);
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

  Future<void> _handleQuery(String item) async {
    final found = await widget.repository.findByName(item);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = found;
      _notice = found == null ? _notFound(item) : null;
    });
  }

  Future<void> _handleUpsert(String item, String location) async {
    // 自动新建位置：由 parsePhrase 归一化的结果驱动，经仓储 addLocation
    // （仓储内部归一化 + 按名去重）。UI 不自建位置、不写旁路。
    final locationId = await widget.repository.addLocation(location);
    if (!mounted) return;
    final result =
        await widget.repository.upsertItemLocation(item, locationId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _notice = result.created
          ? _recorded(item, location)
          : _alreadyRecorded(item, location);
      _result = null;
    });
  }

  /// 按 id 取仓储中的归一化位置名，供显式添加成功文案回显。
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

  /// 多位置文案：动态模板，列出全部未软删位置，不取最近一次。
  String _multiLocationText(ItemWithLocations result) {
    final names = result.locations.map((l) => l.name).join('、');
    return '「${result.item.name}」在：$names（共${result.locations.length}处）。';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text('说一句，记下或查找',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('记：「梯子放阳台」　查：「梯子在哪」',
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
              onSubmitted: (_) => _busy ? null : _submitPhrase(),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('submit_button'),
              onPressed: _busy ? null : _submitPhrase,
              child: const Text('确定'),
            ),
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 8),
            const Text('管理位置',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('new_location_field'),
                    controller: _newLocationController,
                    decoration: const InputDecoration(
                      labelText: '新位置名称',
                      hintText: '例如：储物间',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  key: const Key('add_location_button'),
                  onPressed: _busy ? null : _addLocation,
                  child: const Text('添加位置'),
                ),
              ],
            ),
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
          ],
        ),
      ),
    );
  }
}
