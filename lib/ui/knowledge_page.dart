// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/knowledge_database.dart';

/// V4.3（+37 知识库功能）：知识系统页（顶栏第四栏的主体）。
///
/// PM 终审版（构想简报 + 开工回执七点）锁死口径：
/// * **三个页签**：今日学习摘要（时间线）／知识系统（树视图）／创作表达；
/// * 树三层封顶：学科 → 主题 → 条目；成熟度三档手动标
///   （🟤青果 🟡半熟 🔴熟果，app 不自动算）；
/// * 每条强制「一句话核心」——core_summary 为空不让保存
///   （对抗遗忘的防线，说不出来就是没消化）；
/// * 创作表达 = 学科根「创作表达」下 4 个系统预置主题
///   （写作手法拆解 / 情景描写积累 / 素材本 / 我的写作练习），
///   统一走 knowledge_entries 主表，模板特有字段进 knowledge_entry_meta
///   （键值对，模板标识 `_template`：technique / scene / material / practice）；
///   四主题可改名不可删；新建条目先选模板，表单按模板动态渲染；
/// * 写作练习（practice）成熟度固定 🔴熟果不给用户改（写完即完成，
///   不参与青果/半熟统计），字数自动统计只读；
/// * 起步原则：先粗后细、条目攒 10 条再分叉、每天一条——UI 不做分叉阻拦，
///   只在空态引导里体现。
///
/// 不做清单：不自动算成熟度、不自动生成一句话核心、不跨域混写
///（知识只写 knowledge.db）、不进顶栏/底栏之外的任何栏位。
class KnowledgePage extends StatefulWidget {
  const KnowledgePage({super.key, required this.store});

  /// 知识库读写口（组合根注入；本页不持仓储、不碰 life/work）。
  final KnowledgeDatabase store;

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController =
      TabController(length: 3, vsync: this);

  /// 搜索关键词（树视图页签）。
  String _searchQuery = '';

  /// 时间线缓存（今日学习摘要页签）。
  List<Map<String, Object?>>? _timeline;

  /// 学科根缓存（树视图页签）。
  List<Map<String, Object?>>? _subjects;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final dayStart = DateTime.now();
    final start = DateTime(dayStart.year, dayStart.month, dayStart.day);
    final end = start.add(const Duration(days: 1));
    final timeline = await widget.store.timeline(
      dayStartMs: start.millisecondsSinceEpoch,
      dayEndMs: end.millisecondsSinceEpoch,
    );
    final subjects = await widget.store.subjects();
    if (!mounted) return;
    setState(() {
      _timeline = timeline;
      _subjects = subjects;
      _loading = false;
    });
  }

  // ---------- 成熟度 ----------

  static String _maturityLabel(int? m) {
    if (m == 2) return '🔴熟果';
    if (m == 1) return '🟡半熟';
    return '🟤青果';
  }

  // ---------- 通用小组件 ----------

  Widget _emptyHint(String text) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey)),
        ),
      );

  SnackBar _snack(String text) => SnackBar(content: Text(text));

  void _showError(Object e) {
    if (!mounted) return;
    final msg = e is ArgumentError ? '${e.message}' : '$e';
    ScaffoldMessenger.of(context).showSnackBar(_snack(msg));
  }

  /// 单行信息（详情/表单共用）：标题加粗 + 内容；内容空则整行不渲染
  ///（详情页空字段不占位不留空行——PM 终审口径）。
  List<Widget> _infoRows(List<(String, String?)> rows) {
    final out = <Widget>[];
    for (final (label, value) in rows) {
      final v = (value ?? '').trim();
      if (v.isEmpty) continue;
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: RichText(
          text: TextSpan(
            style: DefaultTextStyle.of(context)
                .style
                .copyWith(fontSize: 14.5, height: 1.5),
            children: <TextSpan>[
              TextSpan(
                text: '$label：',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              TextSpan(text: v),
            ],
          ),
        ),
      ));
    }
    return out;
  }

  /// 详情页行定义：固定两行 + 模板字段按定义序（空字段不占位不留空行）。
  List<(String, String?)> _detailRows(
      Map<String, Object?>? entry,
      Map<String, String> meta,
      String? template) {
    final fields = template == null
        ? const <(String, String, bool)>[]
        : _templateFields[template] ?? const <(String, String, bool)>[];
    return <(String, String?)>[
      ('来源', entry?['source'] as String?),
      ('一句话核心', entry?['core_summary'] as String?),
      // 模板字段按定义序分行。
      for (final (label, key, _) in fields) (label, meta[key]),
    ];
  }

  // ---------- 页签①：今日学习摘要（时间线） ----------

  Widget _buildTimelineTab() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _timeline ?? const <Map<String, Object?>>[];
    if (items.isEmpty) {
      return _emptyHint('今天还没捞。\n每天一条，从一句话核心开始。');
    }
    return ListView.builder(
      key: const Key('knowledge_timeline_list'),
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final title = item['title'] as String? ?? '';
        final source = item['source'] as String?;
        final core = item['core_summary'] as String? ?? '';
        final m = item['maturity'] as int?;
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            key: Key('knowledge_timeline_item_$index'),
            title: Text('$title  ${_maturityLabel(m)}'),
            subtitle: core.isEmpty ? null : Text(core, maxLines: 2),
            trailing: (source ?? '').isEmpty
                ? null
                : Text(source!, style: const TextStyle(fontSize: 12)),
            onTap: () => _openEntryDetail(item['node_id'] as int),
          ),
        );
      },
    );
  }

  // ---------- 页签②：知识系统（树视图） ----------

  Widget _buildTreeTab() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: TextField(
            key: const Key('knowledge_search_field'),
            decoration: const InputDecoration(
              hintText: '搜标题 / 一句话核心 / 来源',
              prefixIcon: Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _searchQuery = v),
          ),
        ),
        Expanded(
          child: _searchQuery.trim().isEmpty
              ? _buildSubjectTree()
              : _buildSearchResults(),
        ),
      ],
    );
  }

  Widget _buildSubjectTree() {
    final subjects = _subjects ?? const <Map<String, Object?>>[];
    if (subjects.isEmpty) {
      return _emptyHint('还没在这棵树上结果，去添加第一条。');
    }
    return ListView.builder(
      key: const Key('knowledge_tree_list'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: subjects.length,
      itemBuilder: (context, index) {
        final subject = subjects[index];
        return _SubjectTile(
          store: widget.store,
          node: subject,
          onChanged: _reload,
          onOpenEntry: _openEntryDetail,
          onAddEntry: _showAddEntrySheet,
        );
      },
    );
  }

  Future<List<Map<String, Object?>>> _runSearch() async {
    final q = _searchQuery.trim();
    final entries = await widget.store.searchEntries(q);
    final nodes = await widget.store.searchNodes(q);
    return <Map<String, Object?>>[...nodes, ...entries];
  }

  Widget _buildSearchResults() {
    return FutureBuilder<List<Map<String, Object?>>>(
      future: _runSearch(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snap.data!;
        if (rows.isEmpty) return _emptyHint('没有命中的条目。');
        return ListView.builder(
          key: const Key('knowledge_search_results'),
          padding: const EdgeInsets.all(12),
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            final isEntry = row.containsKey('core_summary');
            final title = row['title'] as String? ?? '';
            final type = row['node_type'] as String? ?? '';
            final m = row['maturity'] as int?;
            final core = row['core_summary'] as String?;
            return ListTile(
              key: Key('knowledge_search_row_$index'),
              leading: Icon(isEntry ? Icons.sticky_note_2_outlined : null,
                  size: 20),
              title: Text(
                isEntry ? '$title  ${_maturityLabel(m)}' : '$title（${_typeLabel(type)}）',
              ),
              subtitle: (core ?? '').isEmpty ? null : Text(core!, maxLines: 1),
              onTap: () {
                if (isEntry) {
                  _openEntryDetail(row['node_id'] as int);
                }
              },
            );
          },
        );
      },
    );
  }

  static String _typeLabel(String type) {
    if (type == 'subject') return '学科';
    if (type == 'topic') return '主题';
    return '条目';
  }

  // ---------- 页签③：创作表达 ----------

  static const List<(String, String, String)> _templates = <(String, String, String)>[
    ('technique', '写作手法拆解', '读到让拍案的手法，记下原文与为什么惊叹'),
    ('scene', '情景描写积累', '好画面存下来，标注氛围，想写时拿来化用'),
    ('material', '素材本', '观察到的、记住的、将来能用的'),
    ('practice', '我的写作练习', '每天一条，写完即熟果'),
  ];

  static String _templateName(String key) {
    for (final (k, name, _) in _templates) {
      if (k == key) return name;
    }
    return key;
  }

  Widget _buildCreativeTab() {
    return FutureBuilder<List<Map<String, Object?>>>(
      future: _loadCreativeTopics(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final topics = snap.data!;
        return ListView(
          key: const Key('knowledge_creative_list'),
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            const Text('选一个模板开始记',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            ..._templates.map(_templateCard),
            const SizedBox(height: 16),
            const Divider(),
            const Text('已记录', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            if (topics.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('还没有创作条目。',
                    style: TextStyle(color: Colors.grey)),
              )
            else
              ...topics.map(_creativeEntryTile),
          ],
        );
      },
    );
  }

  /// 创作区已记录条目：4 个系统主题下的全部条目混排（learned_at 倒序）。
  Future<List<Map<String, Object?>>> _loadCreativeTopics() async {
    final subjects = await widget.store.subjects();
    Map<String, Object?>? creative;
    for (final s in subjects) {
      if (s['title'] == '创作表达') creative = s;
    }
    if (creative == null) return const <Map<String, Object?>>[];
    final topics = await widget.store
        .childrenOf(creative['id'] as int);
    final all = <Map<String, Object?>>[];
    for (final topic in topics) {
      final entries = await widget.store
          .entriesOfTopic(topic['id'] as int);
      for (final e in entries) {
        all.add(<String, Object?>{
          ...e,
          'topic_title': topic['title'],
        });
      }
    }
    all.sort((a, b) {
      final ta = a['learned_at'] as int? ?? 0;
      final tb = b['learned_at'] as int? ?? 0;
      return tb.compareTo(ta);
    });
    return all;
  }

  Widget _templateCard((String, String, String) t) {
    final (key, name, desc) = t;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        key: Key('knowledge_template_$key'),
        title: Text(name),
        subtitle: Text(desc, style: const TextStyle(fontSize: 12.5)),
        trailing: const Icon(Icons.add_circle_outline),
        onTap: () => _showCreateTemplateEntry(key),
      ),
    );
  }

  Widget _creativeEntryTile(Map<String, Object?> e) {
    final title = e['title'] as String? ?? '';
    final template = e['template'] as String?;
    final topic = e['topic_title'] as String? ?? '';
    final core = e['core_summary'] as String? ?? '';
    final m = e['maturity'] as int?;
    return ListTile(
      key: Key('knowledge_creative_${e['node_id']}'),
      title: Text('${_templateName(template ?? '')}·$title'
          '${template == 'practice' ? '' : '  ${_maturityLabel(m)}'}'),
      subtitle: core.isEmpty ? Text(topic) : Text(core, maxLines: 1),
      onTap: () => _openEntryDetail(e['node_id'] as int),
    );
  }

  // ---------- 表单 / 详情 ----------

  /// 新建普通条目（树视图里挂到某主题；模板=null = 自由条目）。
  Future<void> _showAddEntrySheet(int topicId) async {
    await _showEntryForm(topicId: topicId, template: null);
  }

  /// 创作区新建模板条目：先选模板卡片进来，直接落对应主题。
  Future<void> _showCreateTemplateEntry(String template) async {
    final topics = await _findCreativeTopics();
    final index = _templates.indexWhere((t) => t.$1 == template);
    if (index < 0 || index >= topics.length) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(_snack('创作表达主题缺失，请先重启应用完成初始化'));
      }
      return;
    }
    await _showEntryForm(
        topicId: topics[index]['id'] as int, template: template);
  }

  Future<List<Map<String, Object?>>> _findCreativeTopics() =>
      widget.store.creativeTopics();

  /// 模板字段定义（回执第 7 点锁死；带 * 为必填）。
  static const Map<String, List<(String, String, bool)>> _templateFields =
      <String, List<(String, String, bool)>>{
    'technique': <(String, String, bool)>[
      ('书名', 'book', false),
      ('作者', 'author', false),
      ('手法', 'technique', false),
      ('原文位置（页码或章节）', 'position', false),
      ('摘录', 'excerpt', true),
      ('为什么惊叹', 'why_amazing', false),
      ('我能怎么用', 'how_to_use', false),
    ],
    'scene': <(String, String, bool)>[
      ('来源', 'source', false),
      ('描写段落', 'paragraph', false),
      ('氛围（词）', 'mood', false),
      ('我能怎么化用', 'how_to_use', false),
    ],
    'material': <(String, String, bool)>[
      ('观察到的', 'observed', true),
      ('为什么记住', 'why_remember', false),
      ('可用场景', 'use_case', false),
    ],
    'practice': <(String, String, bool)>[
      ('写了什么', 'written', true),
      ('感觉', 'feeling', false),
      ('下次改进', 'improve', false),
    ],
  };

  /// 新增/编辑条目表单。
  ///
  /// [template] 非空 = 创作区模板条目：表单动态渲染模板字段；
  /// practice 成熟度固定 🔴 且字数自动统计（只读）。
  /// [existingNodeId] 非空 = 编辑模式（读详情回填）。
  Future<void> _showEntryForm({
    required int topicId,
    required String? template,
    int? existingNodeId,
  }) async {
    Map<String, Object?>? detail;
    Map<String, String> existingMeta = const <String, String>{};
    if (existingNodeId != null) {
      detail = await widget.store.entryDetail(existingNodeId);
      if (detail != null) {
        existingMeta =
            (detail['meta'] as Map<String, String>?) ?? const <String, String>{};
      }
    }
    final node = detail?['node'] as Map<String, Object?>?;
    final entry = detail?['entry'] as Map<String, Object?>?;
    if (!mounted) return;

    final titleCtrl = TextEditingController(
        text: node?['title'] as String? ?? '');
    final sourceCtrl = TextEditingController(
        text: entry?['source'] as String? ?? '');
    final coreCtrl = TextEditingController(
        text: entry?['core_summary'] as String? ?? '');
    final metaCtrls = <String, TextEditingController>{};
    var maturity = (node?['maturity'] as int?) ?? 0;
    if (template == 'practice') maturity = 2; // 写完即熟果，锁死。
    final metaFields = template == null
        ? const <(String, String, bool)>[]
        : _templateFields[template] ?? const <(String, String, bool)>[];
    for (final (_, key, _) in metaFields) {
      metaCtrls[key] = TextEditingController(
          text: existingMeta[key] ?? '');
    }
    var learnedAt = (entry?['learned_at'] as int?) ??
        DateTime.now().millisecondsSinceEpoch;

    final ok = await showModalBottomSheet<Object?>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            Widget metaForm() => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final (label, key, required_) in metaFields) ...<Widget>[
                      TextField(
                        key: Key('knowledge_meta_$key'),
                        controller: metaCtrls[key],
                        maxLines: (key == 'excerpt' ||
                                key == 'paragraph' ||
                                key == 'written' ||
                                key == 'observed')
                            ? 4
                            : 1,
                        decoration: InputDecoration(
                          labelText: required_ ? '$label *' : label,
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    // 写作练习：字数自动统计（只读）。
                    if (template == 'practice')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: metaCtrls['written']!,
                          builder: (context, value, _) => Text(
                            '字数：${value.text.characters.length}（自动统计）',
                            style: const TextStyle(
                                fontSize: 12.5, color: Colors.grey),
                          ),
                        ),
                      ),
                  ],
                );

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom:
                    MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      existingNodeId == null
                          ? (template == null
                              ? '新建条目'
                              : '新建·${_templateName(template)}')
                          : '编辑条目',
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('knowledge_entry_title'),
                      controller: titleCtrl,
                      decoration: const InputDecoration(
                        labelText: '标题 *',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (template == null) ...<Widget>[
                      TextField(
                        key: const Key('knowledge_entry_source'),
                        controller: sourceCtrl,
                        decoration: const InputDecoration(
                          labelText: '来源（书名 / 作者 / 链接）',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    TextField(
                      key: const Key('knowledge_entry_core'),
                      controller: coreCtrl,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: '一句话核心 *（说不出来就是没消化）',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    // 成熟度三档（practice 锁死 🔴）。
                    if (template != 'practice')
                      Row(
                        children: <Widget>[
                          const Text('成熟度：'),
                          const SizedBox(width: 8),
                          for (var m = 0; m < 3; m++)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(_maturityLabel(m)),
                                selected: maturity == m,
                                onSelected: (_) =>
                                    setSheet(() => maturity = m),
                              ),
                            ),
                        ],
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('成熟度：${_maturityLabel(2)}（写完即完成，固定熟果）',
                            style: const TextStyle(
                                fontSize: 13, color: Colors.grey)),
                      ),
                    const SizedBox(height: 6),
                    // 学习日期（默认今天；编辑模式只读展示，改动少）。
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: <Widget>[
                          const Text('学习日期：',
                              style: TextStyle(fontSize: 13.5)),
                          TextButton(
                            key: const Key('knowledge_entry_learned_date'),
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate:
                                    DateTime.fromMillisecondsSinceEpoch(
                                        learnedAt),
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2100),
                              );
                              if (picked != null) {
                                setSheet(() {
                                  learnedAt = DateTime(picked.year,
                                          picked.month, picked.day)
                                      .millisecondsSinceEpoch;
                                });
                              }
                            },
                            child: Text(_dateLabel(learnedAt)),
                          ),
                        ],
                      ),
                    ),
                    if (template != null) ...<Widget>[
                      const Divider(),
                      metaForm(),
                    ],
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        if (existingNodeId != null &&
                            (node?['is_system'] as int? ?? 0) != 1)
                          TextButton(
                            key: const Key('knowledge_entry_delete'),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('删除这条？'),
                                  // V4.3.1：文案统一 PM 口径（+38 补丁一）。
                                  content: const Text(
                                      '删除后从知识树隐藏，数据保留在本地备份，不可在界面恢复。'),
                                  actions: <Widget>[
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('取消'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('删除'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true &&
                                  context.mounted) {
                                Navigator.pop(context, 'delete');
                              }
                            },
                            child: const Text('删除',
                                style: TextStyle(color: Colors.red)),
                          ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          key: const Key('knowledge_entry_save'),
                          onPressed: () {
                            if (titleCtrl.text.trim().isEmpty ||
                                coreCtrl.text.trim().isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  _snack('标题和一句话核心都要填——说不出来就是没消化'));
                              return;
                            }
                            Navigator.pop(context, 'save');
                          },
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (ok == null) return; // 取消。
    try {
      final meta = <String, String>{};
      if (template != null) meta['_template'] = template;
      for (final (label, key, required_) in metaFields) {
        final v = metaCtrls[key]!.text.trim();
        if (required_ && v.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(_snack('「$label」是必填项'));
          }
          return;
        }
        if (v.isNotEmpty) meta[key] = v;
      }
      if (existingNodeId != null) {
        if (ok == 'delete') {
          await widget.store.deleteNode(existingNodeId);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(_snack('已进回收站'));
          }
        } else {
          await widget.store.updateEntry(
            existingNodeId,
            title: titleCtrl.text.trim(),
            source: template == null ? sourceCtrl.text.trim() : null,
            coreSummary: coreCtrl.text.trim(),
            learnedAt: learnedAt,
            meta: template == null ? null : meta,
          );
          if (template != null && template != 'practice') {
            await widget.store.setMaturity(existingNodeId, maturity);
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(_snack('已保存'));
          }
        }
      } else {
        await widget.store.addEntry(
          topicId,
          title: titleCtrl.text.trim(),
          source: template == null ? sourceCtrl.text.trim() : null,
          coreSummary: coreCtrl.text.trim(),
          learnedAt: learnedAt,
          maturity: template == 'practice' ? 2 : maturity,
          template: template,
          meta: meta,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(_snack('已记下，每天一条'));
        }
      }
    } catch (e) {
      _showError(e);
    }
    await _reload();
    if (mounted) setState(() {}); // 创作区 FutureBuilder 刷新。
  }

  static String _dateLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  /// 条目详情（按模板分行显示，空字段不占位不留空行）。
  Future<void> _openEntryDetail(int nodeId) async {
    final detail = await widget.store.entryDetail(nodeId);
    if (!mounted) return;
    if (detail == null) {
      ScaffoldMessenger.of(context).showSnackBar(_snack('条目不存在或已删除'));
      return;
    }
    final node = detail['node'] as Map<String, Object?>;
    final entry = detail['entry'] as Map<String, Object?>?;
    final meta = detail['meta'] as Map<String, String>? ?? const {};
    final template = entry?['template'] as String?;
    final learnedAt = entry?['learned_at'] as int?;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(node['title'] as String? ?? ''),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Wrap(
                spacing: 8,
                children: <Widget>[
                  if (template != null)
                    Chip(
                      label: Text(_templateName(template),
                          style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                    ),
                  Chip(
                    label: Text(
                        _maturityLabel(node['maturity'] as int?),
                        style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                  ),
                  if (learnedAt != null)
                    Chip(
                      label: Text(_dateLabel(learnedAt),
                          style: const TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              ..._infoRows(_detailRows(entry, meta, template)),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('knowledge_detail_edit'),
            onPressed: () {
              Navigator.pop(context);
              _showEntryForm(
                topicId: node['parent_id'] as int,
                template: template,
                existingNodeId: nodeId,
              );
            },
            child: const Text('编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ---------- 主体 ----------

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: <Widget>[
          TabBar(
            key: const Key('knowledge_tabs'),
            controller: _tabController,
            tabs: const <Widget>[
              Tab(
                key: Key('knowledge_tab_timeline'),
                icon: Icon(Icons.today_outlined),
                text: '今日学习',
              ),
              Tab(
                key: Key('knowledge_tab_tree'),
                icon: Icon(Icons.account_tree_outlined),
                text: '知识系统',
              ),
              Tab(
                key: Key('knowledge_tab_creative'),
                icon: Icon(Icons.edit_note_outlined),
                text: '创作表达',
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: <Widget>[
                _buildTimelineTab(),
                _buildTreeTab(),
                _buildCreativeTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 树视图里的学科块：学科名 + 果实数标记，展开显示主题。
class _SubjectTile extends StatelessWidget {
  const _SubjectTile({
    required this.store,
    required this.node,
    required this.onChanged,
    required this.onOpenEntry,
    required this.onAddEntry,
  });

  final KnowledgeDatabase store;
  final Map<String, Object?> node;
  final Future<void> Function() onChanged;
  final Future<void> Function(int) onOpenEntry;
  final Future<void> Function(int) onAddEntry;

  static const Color _highlight = Color(0xFF2E7D32);

  Future<Map<String, int>> _count() =>
      store.fruitCountOf(node['id'] as int);

  Future<void> _confirmRename(BuildContext context) async {
    final ctrl =
        TextEditingController(text: node['title'] as String? ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('改个名字'),
        content: TextField(
          key: const Key('knowledge_rename_field'),
          controller: ctrl,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      try {
        await store.updateNodeTitle(node['id'] as int, ctrl.text.trim());
        await onChanged();
      } catch (e) {
        final msg = e is ArgumentError ? '${e.message}' : '$e';
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
      }
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除学科「${node['title']}」？'),
        content: const Text('整棵子树进回收站，恢复前不进搜索与日报。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await store.deleteNode(node['id'] as int);
        await onChanged();
      } catch (e) {
        final msg = e is ArgumentError ? '${e.message}' : '$e';
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = node['title'] as String? ?? '';
    final isCreative = title == '创作表达';
    return FutureBuilder<Map<String, int>>(
      future: _count(),
      builder: (context, snap) {
        final c = snap.data;
        final badge = c == null || c['total'] == 0
            ? ''
            : '（${c['unripe']}🟤 ${c['half']}🟡 ${c['ripe']}🔴）';
        return ExpansionTile(
          key: Key('knowledge_subject_${node['id']}'),
          title: Row(
            children: <Widget>[
              Expanded(child: Text('$title $badge')),
              PopupMenuButton<String>(
                onSelected: (action) async {
                  if (action == 'rename') {
                    await _confirmRename(context);
                  } else if (action == 'delete') {
                    await _confirmDelete(context);
                  }
                },
                itemBuilder: (context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                      value: 'rename', child: Text('改名')),
                  if (!isCreative)
                    const PopupMenuItem<String>(
                        value: 'delete', child: Text('删除学科')),
                ],
              ),
            ],
          ),
          children: <Widget>[
            _TopicList(
              store: store,
              parentId: node['id'] as int,
              onChanged: onChanged,
              onOpenEntry: onOpenEntry,
              onAddEntry: onAddEntry,
              creativeFixed: isCreative,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: Key('knowledge_add_topic_${node['id']}'),
                  onPressed: () async {
                    final ctrl = TextEditingController();
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text('在「$title」下建主题'),
                        content: TextField(
                          controller: ctrl,
                          decoration: const InputDecoration(
                              hintText: '主题名（条目攒到 10 条再分叉）'),
                        ),
                        actions: <Widget>[
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(context, false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(context, true),
                            child: const Text('建'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true && ctrl.text.trim().isNotEmpty) {
                      try {
                        await store.addTopic(
                            node['id'] as int, ctrl.text.trim());
                        await onChanged();
                      } catch (e) {
                        final msg = e is ArgumentError
                            ? '${e.message}'
                            : '$e';
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(
                                  content: Text(msg)));
                        }
                      }
                    }
                  },
                  icon: const Icon(Icons.add, size: 18, color: _highlight),
                  label: const Text('新建主题',
                      style: TextStyle(color: _highlight)),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 学科下的主题列表：展开显示条目；条目行点击开详情。
class _TopicList extends StatelessWidget {
  const _TopicList({
    required this.store,
    required this.parentId,
    required this.onChanged,
    required this.onOpenEntry,
    required this.onAddEntry,
    required this.creativeFixed,
  });

  final KnowledgeDatabase store;
  final int parentId;
  final Future<void> Function() onChanged;
  final Future<void> Function(int) onOpenEntry;
  final Future<void> Function(int) onAddEntry;
  final bool creativeFixed;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, Object?>>>(
      future: store.childrenOf(parentId),
      builder: (context, snap) {
        final topics = snap.data ?? const <Map<String, Object?>>[];
        if (topics.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('还没有主题。条目攒到 10 条再分叉，先粗后细。',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          );
        }
        return Column(
          children: <Widget>[
            for (final topic in topics)
              _TopicTile(
                store: store,
                node: topic,
                onChanged: onChanged,
                onOpenEntry: onOpenEntry,
                onAddEntry: onAddEntry,
                creativeFixed: creativeFixed,
              ),
          ],
        );
      },
    );
  }
}

class _TopicTile extends StatelessWidget {
  const _TopicTile({
    required this.store,
    required this.node,
    required this.onChanged,
    required this.onOpenEntry,
    required this.onAddEntry,
    required this.creativeFixed,
  });

  final KnowledgeDatabase store;
  final Map<String, Object?> node;
  final Future<void> Function() onChanged;
  final Future<void> Function(int) onOpenEntry;
  final Future<void> Function(int) onAddEntry;
  final bool creativeFixed;

  /// V4.3.1（+38 补丁一）：删除主题。
  ///
  /// +37 真机打回硬伤一：主题行没有任何删除入口（deleteNode 接口做了，
  /// 界面没画——「方法存在≠接线存在」复发）。现在主题行右侧加 ⋮，
  /// 菜单含「删除主题」：
  ///  * 有子条目 → 拦住并提示「先清空或转移子条目」，不删；
  ///  * 空主题 → 二次确认（PM 口径文案）→ 软删进回收站（数据留底，
  ///    不物理删，红线照旧）。
  Future<void> _confirmDeleteTopic(BuildContext context) async {
    final title = node['title'] as String? ?? '';
    if (creativeFixed) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('创作表达下的四个主题是系统预置，不可删')));
      return;
    }
    final entries =
        await store.childrenOf(node['id'] as int);
    if (!context.mounted) return;
    if (entries.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('先清空或转移子条目，再删主题')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('knowledge_delete_confirm_dialog'),
        title: Text('删除主题「$title」？'),
        content: const Text('删除后从知识树隐藏，数据保留在本地备份，不可在界面恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('knowledge_delete_confirm_ok'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await store.deleteNode(node['id'] as int);
      await onChanged();
    } catch (e) {
      final msg = e is ArgumentError ? '${e.message}' : '$e';
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  /// V4.3.1（+38 补丁一）：删除条目（树内长按入口）。
  /// 条目无子节点，直接二次确认后软删。
  Future<void> _confirmDeleteEntry(
      BuildContext context, Map<String, Object?> entry) async {
    final title = entry['title'] as String? ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('knowledge_delete_confirm_dialog'),
        title: Text('删除条目「$title」？'),
        content: const Text('删除后从知识树隐藏，数据保留在本地备份，不可在界面恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('knowledge_delete_confirm_ok'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await store.deleteNode(entry['id'] as int);
      await onChanged();
    } catch (e) {
      final msg = e is ArgumentError ? '${e.message}' : '$e';
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = node['title'] as String? ?? '';
    return FutureBuilder<List<Map<String, Object?>>>(
      future: store.childrenOf(node['id'] as int),
      builder: (context, snap) {
        final entries = snap.data ?? const <Map<String, Object?>>[];
        return ExpansionTile(
          key: Key('knowledge_topic_${node['id']}'),
          title: Row(
            children: <Widget>[
              Expanded(child: Text('$title（${entries.length} 条）')),
              // V4.3.1（+38 补丁一）：主题行右侧 ⋮ → 删除主题（+37 硬伤一返工）。
              PopupMenuButton<String>(
                key: Key('knowledge_topic_menu_${node['id']}'),
                onSelected: (action) async {
                  if (action == 'delete') {
                    await _confirmDeleteTopic(context);
                  }
                },
                itemBuilder: (context) => const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                      value: 'delete', child: Text('删除主题')),
                ],
              ),
            ],
          ),
          children: <Widget>[
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('还没在这棵树上结果，去添加第一条。',
                      style: TextStyle(
                          color: Colors.grey.shade600, fontSize: 13)),
                ),
              )
            else
              for (final entry in entries)
                ListTile(
                  key: Key('knowledge_entry_${entry['id']}'),
                  dense: true,
                  leading: const Icon(Icons.sticky_note_2_outlined,
                      size: 18),
                  title: Text(
                    '${entry['title']}  ${entry['maturity'] == 2 ? '🔴' : entry['maturity'] == 1 ? '🟡' : '🟤'}',
                    style: const TextStyle(fontSize: 14),
                  ),
                  onTap: () => onOpenEntry(entry['id'] as int),
                  // V4.3.1（+38 补丁一）：长按条目 → 删除（+37 硬伤一返工）。
                  onLongPress: () => _confirmDeleteEntry(context, entry),
                ),
            if (!creativeFixed)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => onAddEntry(node['id'] as int),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('加条目',
                        style: TextStyle(fontSize: 13)),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
