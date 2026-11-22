// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/inventory_repository.dart';
import '../data/item.dart';
import '../data/phrase_parser.dart';
import 'backup_page.dart';
import 'item_list_page.dart';
import 'location_list_page.dart';

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
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  String? _notice;
  ItemWithLocations? _result;
  bool _busy = false;

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

  /// 挪位语义（V3.2）：同一物品再记新位置 = 移动，旧位置软删。
  Future<void> _handleUpsert(String item, String location, String rawText) async {
    final locationId = await widget.repository.addLocation(location);
    if (!mounted) return;
    final result = await widget.repository.moveItem(
      item,
      locationId,
      rawText: rawText,
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
    setState(() {
      _busy = false;
      _notice = notice;
      _result = null;
    });
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

  void _push(Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
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
              child: const Text(
                '家庭仓储布局',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
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
        // V3.3 导航收敛：入口统一为左上角三道杠；
        // V1 遗留的右上角列表图标已撤下（明细页经抽屉进入）。
        // V3.4 可见性修复：真机浅背景下默认前景色偏淡。
        // V3.4.1 修订（PM 视觉方向调整）：AppBar 反转为深色底
        //（colorScheme.primary 绿色）+ 亮色图标/标题（onPrimary），
        // 白配绿对比拉满，一眼可见；下方内容区保持浅色，深色顶栏
        // 压住视觉层次。
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        leading: IconButton(
          key: const Key('open_drawer'),
          tooltip: '菜单',
          iconSize: 28,
          color: Theme.of(context).colorScheme.onPrimary,
          icon: const Icon(Icons.menu),
          onPressed: _openDrawer,
        ),
      ),
      drawer: _buildDrawer(),
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
