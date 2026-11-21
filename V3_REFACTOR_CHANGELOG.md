# V3 交互说明重构 — 变更记录

日期：2026-11-21
基线：commit 755b329（V2 语音按钮）
状态：本地实现完成、待技术审核与项目经理放行后推 CI

## 一、来源与决策口径

依据《家庭仓储语音记查功能交互说明 v1.0》（2026-11-21，项目经理转开发）。
项目经理拍板四项：
1. 意图解析：端侧纯函数（离线、无隐私外泄，符合单人本地定位）。
2. 位置层级：单层（阳台/厨房抽屉）。
3. 语音快捷按钮：不保留，完全靠系统键盘话筒。
4. 数据同步：纯本地无同步。

## 二、核心变更

### 2.1 语音能力定位转向（推翻 V2 语音按钮块）
- 删除 `lib/data/speech_input.dart`（SpeechInput/PluginSpeechInput/三态结果）。
- UI 去掉 App 内话筒按钮、监听态、语音提示文案（「语音不可用」「没听清」）。
- 移除 `speech_to_text: ^7.5.0` 依赖（pubspec.yaml/lock）。
- AndroidManifest 删除 RECORD_AUDIO 权限与 RecognitionService queries。
- 删除 V1–V7 语音测试及 FakeSpeechInput/PendingSpeechInput 替身。
- 语音完全交由系统输入法键盘：点输入框唤起键盘、用户点键盘话筒转文字，App 只承接转写后的文本。

### 2.2 数据层（v4 → v5）
- `item.dart`：Location 加可选 `remark`；ItemLocation（对应文档 ItemRecord）加可选 `rawText`/`tags`；null 时 toMap 省略该列以兼容旧库。
- `inventory_database.dart`：version 4→5；onCreate 建表加三列；v5 迁移用 `ALTER TABLE ADD COLUMN`（幂等，探测列存在则跳过），对旧数据零破坏。
- 新增 API：`addLocation(name, {remark})`、`updateLocation(id, {name, remark})`、`deleteLocation(id)`（软删）、`upsertItemLocation(item, locationId, {rawText})`。
- 保留 V1 全部验收能力：多对多、软删除、归一化单一入口、名称唯一索引、幂等录入、v2→v3→v4 迁移链与失败回滚。

### 2.3 解析层（端侧纯函数扩展）
- 放置动词：放/搁/塞/摆 → 扩充 收/存/归。
- 查询词：保留「在哪」，新增 哪里/在哪儿/在哪里（后缀，长词优先）、找/有没有（前缀）。
- 显式前缀：「记:」「查:」强制意图（normalizeName 把全角冒号转半角，故代码用半角匹配，全角输入同样命中）。
- 保留全部 V1/V2 防线：语气词只剥一层、倒装只剥一层、动词数恰好 1、介词吞并防污染、出口归一化。
- 纯函数性质不变：只收 String、只调 normalizeName、不碰 DB/UI。

### 2.4 UI 层
- 标题「家庭仓储布局」；副标题「说一句，记下或查找」；示例「记「梯子放阳台」｜查「梯子在哪」」。
- 主输入框占位「说一句」；「确定」空输入禁用（文档验收场景 5）。
- 位置管理区占位「东西在哪里？」；新增/编辑/删除入口（数据层已支持，UI 保留添加入口）。
- 新文案（文档六）：没听懂「没听懂，试试"XX放阳台"或"XX在哪"」、记录成功「已记下：$item → $location」、未命中「暂未记录该物品：$item。」。
- 无 DIAG5/DIAG6/内部代号残留（验收场景 7 有测试断言）。

## 三、本地验证

- `flutter analyze`：**No issues found!**（补齐 flutter_lints 6.0.0 dev 依赖 + 6 处 @override，全绿）
- `flutter test --reporter expanded`：**91/91 All tests passed!**（本机口径，非 CI 证明）
  - 数据层 26（含 V3 remark/rawText/编辑删除/v4→v5 迁移 + v5 失败回滚）
  - 解析层 36（含 V3 新动词/查询词/显式前缀 + 找/存歧义锁定 3 条）
  - UI 层 29（含文档验收场景 2/3/4/5/7 + 语音弱提示）
- 冻结口径变化：V1 七处文案与 parsePhrase 模板按项目经理"立项重构"授权改写（见 2.3/2.4），非 V1 缺陷。

## 四、待审项

1. 文档 3.2 原「语音快捷按钮可选圆形」与整体链路「完全靠键盘语音」矛盾，按项目经理拍板"不保留"处理。
2. tags/remark 数据层支持、UI 无录入入口（文档只给字段、无 UI 规格，避免范围蔓延）。
3. QueryLog 文档标"可选"，本轮未实现。
4. v5 数据迁移脚本基于 ALTER TABLE；旧库中文乱码/超长名等边界沿用 v4 归一化清洗。
5. 端到端验收场景 1（切换输入法）、2（键盘话说记/查）依赖真机，需项目经理实测回填。

## 五、技术审核条件补齐（2026-11-21，有条件通过 → 4 项全补）

技术审核"有条件通过"，放行 CI 前 4 项已全部完成：

1. **语音弱提示**：UI 输入框下方常驻「语音由当前输入法处理」（key=voice_hint），widget 测试断言。对应文档第七章隐私披露。
2. **解析歧义测试**：新增 3 条锁定「找/存/收」作物品名的已知歧义——
   - 物品名以「找」开头 + 录入 → 被查询前缀误吞（`找找放阳台` → Query(找放阳台)）；
   - 物品名以放置动词「存/收/归」开头 + 录入 → 动词数≥2 判未识别（`存钱罐放阳台` 等）；
   - 对照：这些物品名在「在哪」后缀查询句里正常解析。
   - 按 C6/D4/D5 既有做法锁定表现、落档限制，不掩盖；彻底修复归 V2 口语扩展。
3. **v5 迁移事务与回滚预案**：三段 ALTER 在 onUpgrade 事务内（失败整体回滚）；新增 `forTesting` 专用失败注入钩子 `migrationV5FailureHook`（生产构造恒 null，符合 R2 硬闸）；补回滚测试验证失败时版本退回 4、已加的 remark 列撤销、旧数据完好、随后正常 v5 可补列恢复。
4. **flutter analyze 清警告**：补 flutter_lints 6.0.0 dev 依赖，修 6 处缺失 @override，`analyze` 从"include 找不到 + 6 info"变为 `No issues found!`。

**验证**：本地 + 推送目录（github_push_tmp）均 analyze `No issues found!` + test 91/91（本机口径，非 CI 证明）。推送目录清理了 4 个未跟踪的历史残留文件（lib 根级旧扁平结构，非本次改动）。CI（ci.yml）第 13 行含 `flutter analyze`——本次补强后 CI 的 analyze 步骤有 flutter_lints 规则且本地已验证全绿。

**状态**：待项目经理最终放行 → git commit + push → 取新 CI run 取证。发版前项目经理仍须真机实测切换输入法 + 键盘语音记查回填。
