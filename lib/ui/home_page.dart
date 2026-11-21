// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/inventory_repository.dart';
import '../data/item.dart';
import '../data/phrase_parser.dart';
import 'item_list_page.dart';

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

class _HomePageState extends State<HomePage> {
  final TextEditingController _phraseController = TextEditingController();
  final TextEditingController _newLocationController = TextEditingController();

  String? _notice;
  ItemWithLocations? _result;
  bool _busy = false;

  // V3 交互说明文案（替换 V1 冻结文案，逐字符合文档六）。
  static const String _notUnderstood =
      '没听懂，试试"XX放阳台"或"XX在哪"';
  static const String _emptyLocation = '位置名称不能为空。';

  static String _notFound(String item) => '暂未记录该物品：$item。';
  static String _recorded(String item, String location) =>
      '已记下：$item → $location';
  static String _alreadyRecorded(String item, String location) =>
      '「$item」已经在「$location」了。';
  static String _locationAdded(String location) => '已添加位置：「$location」。';

  @override
  void dispose() {
    _phraseController.dispose();
    _newLocationController.dispose();
    super.dispose();
  }

  /// 句式主入口：parsePhrase 解析 → 三态分支。原文作为 rawText 落库。
  Future<void> _submitPhrase() async {
    final rawText = _phraseController.text;
    final parsed = parsePhrase(rawText);

    if (parsed is ParseUnrecognized) {
      // 未识别：零写入，只提示「没听懂」，保留原文供用户编辑。
      _show(_notUnderstood);
      return;
    }

    setState(() => _busy = true);
    try {
      if (parsed is ParseQuery) {
        await _handleQuery(parsed.item);
      } else if (parsed is ParseUpsert) {
        await _handleUpsert(parsed.item, parsed.location, rawText);
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

  Future<void> _handleUpsert(String item, String location, String rawText) async {
    final locationId = await widget.repository.addLocation(location);
    if (!mounted) return;
    final result = await widget.repository.upsertItemLocation(
      item,
      locationId,
      rawText: rawText,
    );
    if (!mounted) return;
    final nameInDb = await _locationName(locationId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _notice = result.created
          ? _recorded(item, nameInDb)
          : _alreadyRecorded(item, nameInDb);
      _result = null;
    });
  }

  /// 添加位置显式入口，可选备注暂不提供录入（文档字段数据层已支持）。
  Future<void> _addLocation() async {
    final name = _newLocationController.text;
    if (name.trim().isEmpty) {
      _show(_emptyLocation);
      return;
    }
    setState(() => _busy = true);
    try {
      final id = await widget.repository.addLocation(name);
      if (!mounted) return;
      _newLocationController.clear();
      final nameInDb = await _locationName(id);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = _locationAdded(nameInDb);
        _result = null;
      });
    } on ArgumentError {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = _emptyLocation;
        _result = null;
      });
    }
  }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: <Widget>[
          IconButton(
            key: const Key('open_item_list'),
            tooltip: '物品明细',
            icon: const Icon(Icons.list),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ItemListPage(repository: widget.repository),
              ),
            ),
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
            const SizedBox(height: 4),
            // 技术审核条件①/文档第七章：隐私与准确率由输入法决定，弱提示常驻。
            const Text('语音由当前输入法处理',
                key: Key('voice_hint'),
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('submit_button'),
              onPressed: (_busy || _phraseController.text.trim().isEmpty)
                  ? null
                  : _submitPhrase,
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
                      labelText: '东西在哪里？',
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
