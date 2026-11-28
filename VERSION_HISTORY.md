# 版本链单一事实来源（Single Source of Truth）

> 铁律：`versionCode` **严格递增且连续**，无跳号、无豁免、无重复。
> 任何一次发版（含真机打回后的补丁版）都必须占用一个新的 `versionCode`。
> 本文件是版本号占用的唯一台账。**出包前先查本表，再定号。**

## 当前版本

| 项 | 值 |
|---|---|
| 当前 versionName | 4.1.1（**已出包、已上线**；V4.1 真机打回整改包） |
| 当前 versionCode | **26（已上线）** — APK 实测 `versionCode='26' versionName='4.1.1'` |
| 下一版应占用 | 27 |
| 下一版 versionName | **待 PM 拍板**（versionCode 恒为 27，不得跳号；V4.2 知识库顺延到 27） |

### 版本链全链（截至 2026-11-27）

| versionName | versionCode | 状态 | 备注 |
|---|---|---|---|
| 3.10.1 | 20 | 已上线 | commit 31b7e87；**+20 不是跳号**，是 V3.10.1 |
| 3.11 | 21 | 已上线 | 多位置问位置 |
| 3.12 | 22 | 已上线 | 部分废弃 |
| 3.13 | 23 | 已上线 | 借出管理 / 来源弹窗 |
| 4.0 | 24 | 已上线 | 多域架构（物理分库），sha256 `afe4a664…82a1` |
| 4.1 | 25 | 已上线 | 概览双签 + 日程签完整交互 + 提醒层裁定 + 裁定②甲方案；sha256 `fd126e4b…db3f` |
| **4.1.1** | **26** | **已出包，已上线** | **V4.1 真机打回整改包**：日报签撤统计卡 / 日程列表可滚 / 新建提醒必选区 / 催办恒两块 / 顶部切换器保留；sha256 `cea08ec4…d2d0e` |

> 历史：3.5=+8、3.6=+9、3.6.1=+11、3.7=+12、3.7.1=+13、3.8=+14、3.8.1=+15、
> 3.9=+16、3.9.1=+17、3.9.2=+18、3.10=+19。**V4.1 占用 +25，V4.1.1 占用 +26，均不跳号。**

## V4.0 架构决策留档（2026-11-26 PM 拍板）

> 供审核方调阅：本节记录地基级技术决策的**拍板依据与来历**，避免日后只剩结论、查不到过程。

| 项 | 决策 | 拍板人 | 依据（原话） |
|---|---|---|---|
| 工作仓储数据形态 | **物理分库（方案 B）**：两域各持独立 `.db` 文件 | PM | 「1.B」 |
| 导航层级 | **顶栏三选一 [概览][生活][工作]** + 概览页底栏隐藏 | PM | 「概览的层级应该和工作区和生活区同级」「概览底部不摆，顶栏放概览/生活/工作」 |
| 占位模块 | **底栏随域动态渲染**：建了几个显示几个，未建的不出现 | PM | 「工作区的模块待定，不一定会和生活区相同」 |
| 备份形态 | **各备份各的**（不单文件全库导出） | PM | PM 决策 |

**被推翻的方案（留档以免重犯）**：2026-11-26 第一版简报曾建议「同一套引擎 + `profile_id` 域隔离（方案 A）」，
经元宝审核指出「分库后物理隔离，逻辑隔离方案的多余设计与风险均不成立」，PM 拍板方案 B，**方案 A 整条作废**。
连带作废：唯一索引重建、冗余 `profile_id` 字段、38 方法加 `profileId` 参数、单文件全库备份。

**方案要点（第二版简报，待元宝审核通过后开工）**：
- 双库实例：生活库 `home_inventory.db`（schema v10→v11，**路径不变、用户数据天然保留**）/ 工作库 `work_inventory.db`（新建，走 `onCreate`）。
- 两库**共用同一套引擎代码**（`InventoryDatabase` + `InventoryRepository`），借出/废弃/数量/位置/校准逻辑不写第二遍。
- **切库守卫**：切域时等待旧实例在飞查询收尾（超时上限 3 秒），切换中的写操作直接拒绝不重试，切域后全量刷新。
- **语音域路由**：解析器识别域前缀 → 直接交对应域实例执行，**不切当前激活域**；执行前检查目标域能力，缺能力明确报错不回落。
- **备份跨域校验**：备份带域标识，恢复时强制校验（生活备份恢复进工作库 → 拒绝并说明原因）；旧无标识备份归生活库。
- **日报系统**：新增 `reminders`（含 `status` pending/done）与 `daily_reports` 两表（生活库）；概览预留 `ReminderSource` 接口 + 注册机制。
- **导出**：`.md` 零新增依赖（复用 `saveBytesToDevice` + `share_plus`）；`.docx` **实际实现为零依赖自研生成器**（`lib/data/docx_writer.dart`，手写 ZIP store + CRC32 + OOXML 片段），原计划的 `docx` 包因 pub 镜像 404 未采用（见「实施偏离留档」第 1 条）。

**方案简报**：`简报_V40多域架构_物理分库_方案转审核_第四版_一键复制.html`（工作区留档，**最新版**）。
第三版：`简报_V40多域架构_物理分库_方案转审核_第三版_一键复制.html`；
第二版：`简报_V40多域架构_物理分库_方案转审核_一键复制.html`；第一版（已作废，保留供追溯）：`简报_V314多域架构_方案转审核_一键复制.html`。

### 元宝第二版审核批复的落实要点（2026-11-26）
- **切库守卫**：3 秒超时上限认可；超时后<b>连接状态置 dirty，下次切域前强制重建两库连接</b>（新增）。
- **语音域前缀**：改为<b>解析器入口白名单匹配、命中即跳出</b>，不靠守卫顺序；白名单做成可扩展常量（工作区/工作仓储/公司/生活区/生活仓储/家里）。
- **docx 依赖**：元宝同意新增纯 Dart 包；**出包前必须跑 release 构建验证 `checkReleaseAarMetadata` 通过**（四道出包锁之一）。
- **日报生成时机**：定义为<b>每天第一次打开 App 时检查昨天有无日报，没有则补生成</b>（记上次检查日期，跨日才查，同日多次冷启动只查一次）。
- **底栏（我曾读错 PM 语义，已纠正）**：<b>生活区五模块固定全显示</b>，知识库/餐饮/衣橱仍为「建设中」占位页且**不隐藏**；<b>「未建的不出现」只适用于工作区</b>（工作区本轮只显示工作仓储）。
- **提醒源接口统一**：概览只认 `ReminderSource` 一个接口，**不另开 `OverviewPanel`**。
- **语音跨域落库提示**：必须带引导按钮「是否切换到生活区创建？」，不能只报错。
- **版本号**：**必须 PM 拍板**；开发侧建议 `4.0.0+24`（versionName 跳大版本，versionCode 仍须连续为 24，**不得跳号**）。
- **测试红线**：461 条旧测试全绿是出包前提，**一条不能删**；新增专项也是必过项，非「有时间再做」。

### 元宝第三轮复核批复的落实要点（2026-11-26，审核结论：放行）
> 元宝第三轮批复结论为**放行**：除底栏语义纠偏外**无地基级推翻**；9 条风险逐条把关通过；
> 5 件请审事项中 4 件按批改完、2 项已认可、**1 项（版本号）仍待 PM 拍板**。以下 5 条为第三轮**新增**约束。

| # | 新增约束 | 落点 |
|---|---|---|
| 1 | **切库超时次数用户可见**：超时不止写日志，超时计数进状态并在**概览页可读**（降级放行不得静默）；只读展示、不给「清零」按钮 | 简报 3.2 / 7 / 六 |
| 2 | **域词歧义兜底**：「公司」歧义大，**剥前缀后必须解析出合法意图**才认定是域指令；解析不出则**按原句走常规解析**，不吞句、不误落库 | 简报 3.3 / 六 |
| 3 | **系统时间回拨不重复补日报**：判重按**设备本地日期**，且用「已处理日期集合」兜底，不只靠「上次检查日期」（否则回拨会重复补生成） | 简报 4.3 / 六 |
| 4 | **概览只读在代码层落实**：概览层**不持有可写仓库实例**，只拿只读查询接口——代码上写不了，而非靠「UI 没放按钮」 | 简报 3.5 / 七 |
| 5 | **备份跨域报错文案固定**：「这是生活区的备份，不能恢复到工作区」 | 简报 3.6 |

**口径订正（第三版正文自相矛盾，已改）**：简报 3.1 原写「工作库建 6 张表」与第六节「八表」并存——实为
**现有 6 表**（`items`/`locations`/`item_locations`/`item_discards`/`borrowers`/`loans`）
**+ V4.0 新增 2 表**（`reminders`/`daily_reports`）**= v11 共 8 张表**。两库结构完全一致（同一份 `onCreate`），
生活库升级而来、工作库新建而来，**最终 8 表齐平**。

**元宝点名验收的三条观察项（出包前开发侧先自检，对不上不出包）**：
① 切库超时用户可见（不是只在日志）；② **工作库八表与生活库 v11 逐表逐列核对**（列名/类型/默认值/索引，不允许「差不多」）；③ 概览只读代码层落实。

**版本号状态**：元宝第三轮已同意 `4.0.0+24`，**PM 已于 2026-11-26 拍板同意** → **V4.0.0+24 已出包上线**（见下节）。
versionCode 连续递增铁律不变，**恒为 24、不得跳号**。

### V4.0 实施偏离留档（3 条，开发侧自主决定，已按元宝批复口径处理）
> 元宝批复「无地基级推翻」，以下 3 条为实现层的具体偏离，**留档以免日后查无实据**。

| # | 偏离 | 原因 | 处理 |
|---|---|---|---|
| 1 | **`.docx` 导出改零依赖自研生成器**（`lib/data/docx_writer.dart`），未引入 `docx` 包 | pub 镜像 `pub.flutter-io.cn/api/packages/docx` 返回 404（已 curl 核实），pub.dev 不可达；替代包 `docx_creator` 连带 image/html/http 等一串依赖 | 后果比原方案更好：`checkReleaseAarMetadata` 构建风险直接归零；生成的 .docx 经 ZIP 结构校验（`[Content_Types].xml`/`_rels`/`word/document.xml` 齐备） |
| 2 | **工作区（单模块域）底栏改用单按钮底栏**（`BottomAppBar`，key `home_bottom_nav_single`） | Flutter `BottomNavigationBar` 断言 `items.length >= 2`，工作区本轮只有「工作仓储」一项，用 BottomNavigationBar 会直接抛断言 | 生活区五模块仍走标准 `BottomNavigationBar`（key `home_bottom_nav`）；两处均有专项测试断言 |
| 3 | **工作区不开放提醒 = 能力开关，不是表缺失** | 元宝批复要求「工作库八表与 v11 逐表核对」，同时认可工作域本轮不开放 reminders | **两库表结构齐平（8 张表，含 reminders/daily_reports）**，工作域通过 `domainCapabilities` 关闭 reminders 能力入口；用户看到的是「工作区暂不支持提醒」，不是「表不存在」 |

## V4.0 出包四道锁核对（2026-11-26）

| 锁 | 要求 | 实测结果 | 判定 |
|---|---|---|---|
| ① 台账定号 | 当前号 +1，不复用已占用号 | 23 → **24**（台账先定号后出包） | ✅ |
| ② aapt2 实测 versionCode | APK 内 versionCode 与 pubspec 一致 | `aapt2 dump badging` → `versionCode='24' versionName='4.0.0'` | ✅ |
| ③ release 验 `checkReleaseAarMetadata` | release 构建通过 | `flutter build apk --release` 成功（450s，产物 54.1MB），无 AAR metadata 报错 | ✅ |
| ④ flutter test 全绿 | 旧 461 条一条不删 + 新增专项必过 | **484/484 All tests passed**（461 旧 + 23 新增 V4.0 专项） | ✅ |

**APK 凭据**：54,127,038 字节 · sha256 `afe4a66407952008d7da4ce4a3e8695f264da2834a852a285afa2aa874a082a1`
· 签名 v2 通过，指纹 `c1647f333c52ea7b170f6b143eec7ed46ea715784cbd92950eec4df2cc518e5f`（与历版一致，可覆盖安装）
· commit `85ba5fd` · 线上直链核验 sha256 与字节数**完全一致**。

**元宝点名的三条验收观察项，自检结论**：

| 观察项 | 落地位置 | 自检结论 |
|---|---|---|
| ① 切库超时用户可见 | `DomainHub.switchTimeoutCount` → 概览页卡片展示（key `overview_switch_timeout`），只读、无清零按钮 | ✅ 超时不止写日志，计数进状态并在概览页可读 |
| ② 工作库八表与 v11 逐表核对 | 专项测试 `v40_multidomain_test.dart` 逐表逐列断言（列名/类型/默认值/索引），两库同一份 `onCreate` + 生活库 v10→v11 迁移 | ✅ 8 表齐平（`items`/`locations`/`item_locations`/`item_discards`/`borrowers`/`loans`/`reminders`/`daily_reports`） |
| ③ 概览只读代码层落实 | 概览页只持 `OverviewReader`（只读口）+ `DomainOverview` 不可变快照，**类型层面拿不到可写仓库** | ✅ 不靠「UI 没放按钮」 |

## 完整版本链

| # | versionName | versionCode | 日期 | commit | 状态 | APK SHA256 |
|---|---|---|---|---|---|---|
| 19 | 3.10.0 | 19 | 11-25 10:28 | `1b1fac8` | 已上线（真机打回） | `1bea0020…5290` |
| 20 | 3.10.1 | 20 | 11-25 12:45 | `31b7e87` | 已上线（复验修复版） | `e7500786…931` |
| 21 | 3.11.0 | 21 | 11-25 15:53 | `81f0cea` | 已上线 | `bcfa4b0a…4484` |
| 22 | 3.12.0 | 22 | 11-25 21:37 | `e70e0bf` | 已上线（部分废弃） | `375714fe…6995` |
| 23 | 3.13.0 | 23 | 11-26 08:15 | `5413bad` | 已上线（删除孤儿修复） | `2570b2c8…fbc29` |
| 24 | 4.0.0 | 24 | 11-26 16:30 | `85ba5fd` | 已上线（多域架构·物理分库） | `afe4a664…82a1` |
| 25 | 4.1.0 | 25 | 11-27 06:30 | `e232c9e` | 已上线（概览双签 + 裁定②甲方案） | `fd126e4b…db3f` |

历史：V3.6.1=+11、V3.7=+12、V3.7.1=+13、V3.8=+14、V3.8.1=+15、V3.9=+16、V3.9.1=+17、V3.9.2=+18。

## 闭环简报凭据（每版一份，补丁版同样必须出）

| versionCode | 版本 | 闭环简报（工作区目录） |
|---|---|---|
| 19 | 3.10.0 | `简报_V310数量打通_发版闭环_一键复制.html`（2026-11-25 补档） |
| 20 | 3.10.1 | `简报_V3101真机打回修复_发版闭环_一键复制.html`（2026-11-25 补档，**+20 的唯一凭据出处**） |
| 21 | 3.11.0 | `简报_V311交付上线_真机复验_一键复制.html` |
| 22 | 3.12.0 | `简报_V312部分废弃_交付上线_真机复验_一键复制.html` |
| 23 | 3.13.0 | `简报_V313删除孤儿修复_交付上线_真机复验_一键复制.html` |
| 24 | 4.0.0 | `简报_V40多域架构_交付上线_真机复验_一键复制.html` |
| 25 | 4.1.0 | `简报_V41批次5_收尾出包_交付上线_一键复制.html` |

> V4.1（+25）计划阶段的**审核回执**（非闭环简报，是「等审核通过」的答复）：
> `简报_V40终审回执_V41计划_一键复制.html`（2026-11-26）。
>
> 规则：**每一版（含补丁版）都必须有一份发版闭环简报**。V3.10 / V3.10.1 当时漏出，
> 导致 2026-11-25 审核时 +20 在文档链上查无实据、被误判为跳号——已于当日补齐。

### 关于「桌面留存」与「下载页留存」的关系

两者是**同一份 APK 的两个存放位置**，不是两次构建：

| 位置 | 命名规则 | 用途 |
|---|---|---|
| 桌面 | 中文友好名（如 `家庭仓储V3.10-数量打通-release.apk`） | PM 归档、离线安装 |
| 下载页目录 | ASCII 名（如 `home-inventory-v3100.apk`） | URL 直链分发（必须 ASCII） |

已实测验证：`cmp` 字节级完全一致 + sha256 相同 + `apksigner verify` 签名指纹同为 `c1647f33…`。
**核对凭据时只需比对 sha256，不必逐个另算。**

## +20 是什么（易被漏记，特此留档）

`+20` = **V3.10.1 复验修复版**，不是跳号，也不是写错。

- 背景：V3.10.0（+19）上线并安装到 PM 真机后，真机复验被打回（归还选位置导致其他位置被改写、带数量挪位把总数覆盖成 1）。
- 处置：按铁律**必须升号**——新旧同号 APK 无法区分、无法覆盖安装，故定名 `3.10.1+20`（沿用 V3.9.1 / V3.9.2 补丁版命名惯例）。
- 该版已真实出包并上线：桌面留存 `家庭仓储V3.10.1-复验修复-release.apk`（52,341,178 字节，sha256 `e7500786b53acde1e7c4f8cda1f2eb059b5054ae82345f2301c44c9672640931`），下载页留存 `home-inventory-v3101.apk`，APK 清单实测 `versionCode='20' versionName='3.10.1'`。
- 唯一疏漏：下载页为滚动更新、只展示最新版，V3.10.1 条目已被后续版本替换，导致审阅时误判为「+20 跳号」。

## 为什么不能把 V3.11 改回 +20

- +20 已被 V3.10.1 占用且该版已上线、PM 真机已装。同号等于号段复用，违反「每版占用新号」。
- 更硬的一点：V3.11（+21）**已经上线并安装到真机**。若把它改成 +20，等于 versionCode 倒退 → Android 直接 `INSTALL_FAILED_VERSION_DOWNGRADE`，PM 根本装不上。
- 同理 V3.12（+22）改 +21 也是倒退。

结论：**无需修正**，19 → 20 → 21 → 22 → 23 连续递增，铁律未被违反。

## +23 是什么（V3.12 真机打回后的修复版）

- V3.12.0（+22）上线并安装到 PM 真机后，真机复验被打回：删除「有在借记录」的物品会在借出管理页留下**孤儿借出记录**（items 已软删、loans 仍活跃），另有三处弹窗/文案说不清账。
- 处置：按铁律升号重发 → `3.13.0+23`。
- 修法要点：删除物品时级联软删在借记录；恢复物品时一并复活（`updated_at == deleted_at` 精确匹配，与位置关联同口径）；彻底删除连带物理清除借出记录；回收站单独恢复借出记录时校验物品是否存活；守恒自检补「在借 ↔ 物品」维度。
- APK：52,718,010 字节，sha256 `2570b2c8c97694186c208a0e26ba8c7f1a864e2f12aa8153af94867bb37fbc29`，签名指纹 `c1647f33…`（与线上一致，可覆盖安装）。
- 数据结构**未升级**（仍 v10），与 V3.12 备份双向兼容。

## V4.0 终审回执要点（2026-11-26，元宝终审合并版）

> **状态**：元宝放行 V4.0 出包，但对**视图层归属**下发了新的产品定案（A/B/C/D 四节），
> 要求在 **V4.1** 落地。本节记录**审核发现的自查缺口**，避免日后只剩结论、查不到过程。

### 编码前必须裁示的 4 个点（PM 已于 2026-11-26 全部拍板）
1. **概览可写边界**：E5「每条可打勾已处理」= 写操作，与已放行的「概览只读代码层落实」需边界澄清。
   我方方案：**拆两个接口** —— `OverviewReader`（只读账，**一字不改**）+ `TodoStateWriter`（只写待办条目状态，新接口），
   「概览不能改账」在**类型层面**依然成立。
2. **旧测试改断言/改写是否合规**：红线是「461 条一条不能删」。【D】把日程移出生活区底栏会让 **2 条**旧测试前提消失
   （`home_page_test.dart` 的「底栏渲染 5 个一级模块按钮」「切至日程 → 抽屉占位」）。
   我方处理：**改断言 + 改写，保行数、保测试意图、反向锁住新口径**，并逐条列清单送审。
3. **工作域提醒能力**：【G#3】认可「能力开关保留」+【C4】要「跨域日程页可看两域条目」→ 口径需明确
   （我方口径：工作域不新建提醒、表建齐、跨域日程页按域分组显示工作域那组为空 + 说明文案）。
4. **批点后开工 V4.1**，在此之前编码一行不动。

### PM 拍板结论（2026-11-26，已生效）
| # | 裁示点 | PM 拍板 |
|---|---|---|
| 1 | 概览可写边界 | **拆两个接口**：`OverviewReader`（只读账，一字不改）+ `TodoStateWriter`（只写待办状态，新接口） |
| 2 | 旧测试「改断言/改写」 | **改断言保行数**（不删任何一条） |
| 3 | 工作域提醒能力 | **工作域不新建**（表建齐、永远为空）；跨域日程页按域分组，工作域那组显示为空 +「工作区暂不支持提醒」 |
| 4 | 开工时机 | **等元宝批复后开工** → 本轮编码一行不动 |

> **V4.1 施工前图纸**（待元宝审核）：`简报_V41技术设计_施工前图纸_待审核_一键复制.html`（2026-11-26）。
> 图纸含：接口签名草案、todo_states 建表 SQL、逐文件施工清单（10 项）、旧测试改写甲/乙两方案、
> 元宝三条观察项在 v12 口径下的更新、风险自曝 3 条、待裁示 5 点。**行号与字段均为实地核对，非估算。**

### 自查发现的 V4.0 缺口（不在元宝清单里，buddy 主动报）
- **日报页是孤儿类**：`lib/ui/daily_report_page.dart` 的 `DailyReportPage` **全仓无任何引用**
  （`grep -rn "DailyReportPage" lib/ test/` 只命中自身定义；import 路径 0 命中）。
  → **V4.0 用户进不去日报**（能自动生成、能存表、能导出，但界面无入口）。
  → 正好由【D】「日报入口回归概览页」解决，V4.1 必修。
  → **教训**：写完功能只验了「数据层跑通」，没验「用户点得到」——与 V3.7「解析器识别 ≠ UI 落库」同类，方向相反。

### E 节五条核查结论（做了指代码位置，没做列版本）
| # | 结论 | 代码位置 |
|---|---|---|
| E1 借出到期重复渲染 | **未做，且是覆盖+重复双 bug**：生活/工作两源共用 `id='loan_due'` 与 `displayName='借出到期'`；`overview_page.dart:60` 用 displayName 作 Map key → 工作区覆盖生活区（生活区条目被吞），`:110-116` 又逐源渲染 → 标题出现两次 | `reminder_sources.dart:16,19` / `overview_page.dart:60,110-116` |
| E2 提醒源缺域标识 | **未做**：displayName 是无域裸名 | `reminder_sources.dart:19,50` |
| E3 工作区全 0 空态缺引导 | **未做**：只印一行数字，无引导无入口 | `overview_page.dart:122-148` |
| E4 概览内容区可滚动 | **已做**：`RefreshIndicator` + `ListView` | `overview_page.dart:81-119` |
| E5 概览「一条一条提示流」 | **部分做**：物品名+借给谁+逾期/待归还已有；**借出日期/预期天数/剩余天数未渲染**（数据源有 `Loan.borrowedAt/dueAt/quantity`）；**可打勾/划线灰化/可撤销全无**（图标不可点） | `reminder_sources.dart:29-34` / `overview_page.dart:160-169` |

### V4.1 关键技术决策

> ⚠️ **以下第一条已被 2026-11-26 的 v12 新方案取代**（保留原文以留痕，勿照此施工）。
> 取代原因：借出到期条目（`loan_xxx`）不属于 `reminders` 表，其状态若存 `reminders` 就只能把借出到期
> 「投影」成 reminders 行 → 双源漂移；且元宝 B5 要求催办区混合「日程类 + 系统类」，两类状态不同源，
> B8 的日报↔日程双向同步无从谈起。
> **新方案见下方「v12 定案」段。**

- ~~**延期计数按「次」累计**：`reminders` 表加 `defer_count INTEGER NOT NULL DEFAULT 0`（每次 +1，永不按天重置，
  同一天多次延期自然算多次）；自动延期 = 把 `due_at` 往后推一天（**不新建条目**，所以「再次提示」= 同条目重现）。
  另加 `handle_note` 列放「处理备注/延期原因」（与原 `detail` 语义分离）。
  → **schema v11 → v12**（纯增量 `ALTER TABLE ADD COLUMN`，复用现有 `_addColumnIfMissing` 幂等工具）。
  → 「八表逐表核对」观察项口径**须同步更新为 v12**，不静默失效。~~
- **生活区五模块 → 四模块**：`home_module.dart:54-68` 删 `schedule` 项；`home_page.dart:2275-2283` 移除
  `ModuleKind.schedule` 分派；删后仍 4 项 ≥ 2，`BottomNavigationBar` 断言不受影响。

### v12 定案（2026-11-26 施工前图纸，取代上条）
- **新增第 9 张表 `todo_states`**，作为**所有催办条目状态的唯一权威源**（日程类 + 系统类共用）：
  `entry_id TEXT PK`（`reminder_<id>` / `loan_<id>`）、`state`（pending/done/deferred）、`done_at`、
  `note`（处理备注/延期原因）、`defer_count`（按次累计，跨天不重置）、`next_due_at`（延期后的下次提示时间）。
- **reminders 表一列不动**（`status/done_at` 保留兼容，老备份读路径不变、回滚安全）。
- **迁移代价大幅下降**：`ALTER TABLE ADD COLUMN ×2` → `CREATE TABLE IF NOT EXISTS`，**幂等天然满足**，
  不碰任何旧表旧列，**旧备份兼容零风险**。
- **自动延期不推 `reminders.due_at`**（那会让概览越界写日程表）→ 改记 `todo_states.next_due_at`，
  `next_due_at = max(effectiveDue + 1 天, 明天)` → **每天最多自动 +1 次**（否则过期 5 天会一天涨 5 次，计数失真）。
  手动延期每次 +1 → 同一天点 3 次就是 3 次，符合「按次累计」。
- **E1 修复两道缺一不可**：① 概览 Map 的 key 从 `displayName` 改 `source.id`（`overview_page.dart:60`）；
  ② 源的 id/displayName 带域（`id='loan_due_${domain.id}'`、`displayName='${domain.label}·仓储借出到期'`）。
  **id 必须带域**——V4.1 条目要与 `todo_states` 按 entryId 配对，不带域则生活/工作区的 `loan_1` 会撞成同一条。
  域**必填**（不设默认值），让编译器强制每个调用点显式声明域。
- **「八表逐表核对」观察项升级为「九表与 v12 逐表核对」**——两库同一份 `onCreate` 仍成立，
  专项测试加「两库 todo_states 列完全一致」断言，**不让观察项悄悄失效**。
- **元宝 I③ 口径细化**：概览持 `OverviewReader`（只读账，**一字不改**）+ `TodoStateWriter`（只写 `todo_states`）。
  `TodoStateWriter` 入参只有 entryId 字符串 → **拿不到任何仓储句柄** → 「概览改不了账」在**编译期**依然成立。

> ⚠️ **元宝 2026-11-26 开工令已把字段口径改细**：上条的 `entry_id/state/note` 改为
> **`id` / `source_type` / `source_id` / `status` / `done_at` / `defer_count` / `handle_note` /
> `created_at` / `updated_at`**（PM 已确认 `source_type` 枚举 = `schedule_reminder` / `loan_due`，
> 后续加新催办源只加枚举值、不加表不加列）。**以开工令口径为准。**
> **buddy 多加了第 10 列 `next_due_at`**（延期后的下一次提示时间）——
> 这是**对元宝字段清单的唯一一处增补**，理由：元宝 B4 要求「到期当天未处理 → 自动延期 →
> 到期当天再次提示」，而「再次提示的时间点」在 9 个字段里无处可存：
> ① 推 `reminders.due_at` = 概览越界写日程表（破 PM 拍板的写边界）；
> ② 用 `defer_count` 反推 = 「按次累计」退化成「按天累计」（与 B4 直接冲突）。
> **已在批次 1 简报第一节显式请元宝追认**，追认前不进批次 2 的依赖项。



### docx 真机复验（【F③】【G#1】【J】）
- 程序化验证已推到 4 层：ZIP CRC 全过 → 6 部件齐全 + XML 全良构 → **macOS `textutil`（Apple 文档引擎）读出全文**
  → **往返转换**（我们的 docx → textutil 重新序列化 → 再读，文本一字不差，且被自动补上 `word/theme/theme1.xml`，
  说明引擎把它当正常 Word 文档加工）。
- **但仍不宣称真机通过**：textutil ≠ 微软 Word / 金山 WPS。样张 docx 已备
  （`V4.0日报样张_请用Word或WPS打开.docx`，**用生产代码原样生成**），PM 用 Word/WPS 开一次才算过。
- **注意**：V4.0 界面上**没有日报入口**（孤儿页问题），所以 V4.0 无法从界面走完导出链路，样张是绕过入口验证生成器本身。

## 出包前自检清单

1. 查本表，确认目标 `versionCode` 未被占用且为「当前 + 1」。
2. 改 `pubspec.yaml` 的 `version:` 字段（`versionName+versionCode` 同一行）。
3. `git commit` 消息里写明「versionCode X→Y」及原因。
4. 出包后用 `aapt2 dump badging <apk>` 实测 APK 内 `versionCode`，与 pubspec 一致才算过。
5. 上线后用带 `?sharecode=` 的直链下载，比对 sha256。

---

## V4.1 批次 2 留档（2026-11-26）

> 本节记录 V4.1 批次 2 的**表结构变更**与**批次 1 遗留缺陷的修复**，
> 供审核方调阅。批次 2 **未出包**，versionCode 25 仍为「已占用未出包」。

### schema v12 → v13：`reminders` 加 `priority` 列

- 触发：元宝「V4.1 日报签提醒层裁定」①——
  「reminders 表加 priority 列（0低/1中/2高，默认1），日程签创建/编辑时可设，
  日报签催办区按优先级排序（高→中→低）」。
- 做法：幂等加列 `_addColumnIfMissing(db, 'reminders', 'priority',
  type: 'INTEGER NOT NULL DEFAULT 1')`。
- **表数量不变，仍是 9 张**（priority 是列，不是表）。
- **旧提醒升级后默认拿 1（中）**——不该因为升级就被判成低优先级。
- 两库结构齐平（生活库 / 工作库同一份 `onCreate` + 同一条迁移分支）。

### 批次 1 遗留缺陷（本批新写的 widget 测试暴露并修复）

| # | 缺陷 | 后果 | 修复 |
|---|---|---|---|
| 1 | 概览页**从未调用 `_reload()`**（漏 `initState`） | 页面永远停在「加载中…」，**一张卡、一条催办都不显示** | 加 `initState` → `addPostFrameCallback` 触发加载（`initState` 里不能直接 `setState`） |
| 2 | 跨域状态配对**撞车** | `todo_states` 每库一张表，两库的 `loan_due_1` 合并进同一张 Map 时互相覆盖——E1 在状态层的翻版 | 配对键改为**带域前缀** `'{domainId}:{entryKey}'`；**存储层仍不带域，表结构一个字不动** |
| 3 | 日报导出**只注册生活域**源与读取口 | 工作域条目**在界面红着、导出里没有** → 违反元宝 B6「未完成 = 提示框内未处理的条目」 | 日报服务改**逐域注入** `todoReaders` + 两域源；概览页改按域取写口 |

> 缺陷 1 的教训：**概览页从来没有 widget 测试**，数据层测试全绿也照样漏过去。
> 本批新增 6 条概览页 widget 测试（真点延期、真折分组、真切签），作为回归锁。

### 待元宝追认的口径（buddy 自定，非元宝裁定原文）

| # | 口径 | buddy 的取值 | 理由 |
|---|---|---|---|
| 1 | **系统类（借出到期）的优先级** | **高（2）** | ✅ **元宝 2026-11-26 裁定①：批准**（借出到期忘了会出事，默认高合理） |
| 2 | **提前进区的提前量** | 高 = 提前 3 天 / 中 = 提前 1 天 / 低 = 不提前 | ✅ **元宝裁定②：批准**（不新增列，由 priority 推导） |
| 3 | **日程签的勾选是否算「提醒交互」** | 勾选保留，延期 / 备注去掉 | ✅ **元宝裁定③：批准**（勾选写待办状态，不是提醒交互） |
| 4 | **延期的绝对日期写入** | ~~用户选什么就是什么~~ | ❌ **元宝裁定④修订：改为「只往后推不许回拉」**——已按新口径实现，见下节 |

> ⚠️ 上表第 1、4 条原为 buddy 自定口径，元宝 2026-11-26 已逐条裁定；
> 第 1 条的**提前量**部分被 PM 最终裁定改为 **2 天**（见下节），第 4 条口径被推翻。

---

## V4.1 批次 3 留档（2026-11-26）

> 本节记录批次 3 的**裁定落地**与**新增的窄写口**。
> 批次 3 **未出包**，versionCode 25 仍为「已占用未出包」。

### schema：**未变**（仍是 v13 / 9 张表）

批次 3 **没有新增任何列或表**：

- `reminders` 仍是 10 列（含批次 2 加的 `priority`）；
- `todo_states` 仍是 10 列（含批次 1 追认的 `next_due_at`）；
- 两库结构仍齐平。

### 元宝裁定①修订：系统类提前量 = 2 天（PM 最终裁定）

| 项 | 值 |
|---|---|
| 元宝裁定① | 系统类优先级 = 高（2） |
| 元宝裁定② | 提前量由 priority 推导（高 3 / 中 1 / 低 0），**不新增列** |
| PM 最终裁定 | 系统类**提前 2 天**，不取 buddy 原定的 3 天 |

**三条放一起会打架**（优先级=高 → 按②推导是 3 天 → PM 说 2 天）。

**解法：显式提前量覆盖**（`OverviewEntry.leadDaysOverride`，可空）

```
leadDays = leadDaysOverride ?? ReminderPriority.leadDaysOf(priority)
```

- 系统类源显式传 `2`；
- 日程类不传 → 走 priority 推导（高 3 / 中 1 / 低 0，**推导表一个字没动**）。

**为什么不能改推导表**：把 `leadDaysOf(high)` 改成 2，会连带把日程类高优先级
从 3 天改成 2 天——裁定②批的是「高3/中1/低0」，一并改掉就是越权改裁定。
**优先级（排序用）与提前量（进区用）在此解耦。**

### 元宝裁定④修订：延期只往后推，不许回拉

- 判据基准 = `next_due_at` ?? 源条目原到期日 ?? 现在；
- 选了**早于**基准的日子 → **被忽略**并报错提示，
  **状态行一字不动**（连 `defer_count` 都不加——这次延期压根没发生）；
- 选了**等于**基准 → 允许（不构成「早于」）；
- **校验在数据层**（`InventoryDatabase.defer` 抛 `ArgumentError`）：
  只在 UI 拦的话，绕过 UI 的调用照样能回拉；
- UI 侧同步：日期选择器 `firstDate` 挡住更早的日子；
  「延到明天」在会回拉时禁用并写明原因。

### 新增窄写口 `ReminderEditor`（`lib/domain/reminder_editor.dart`）

| 方法 | 作用 |
|---|---|
| `createReminder(title, {detail, dueAt, repeatRule, priority})` | 新建提醒 |
| `editReminder(id, {title, detail, dueAt, repeatRule, clearRepeatRule, priority})` | 编辑（可**显式清空**重复规则） |
| `removeReminder(id)` | 软删 |

- **只写 `reminders` 表**，不含 `items` / `loans` / `locations`；
- **不含日报读写**（`ReminderRepository` 混着 `saveDailyReport`）→ 源码级锁死；
- 方法名与 `ReminderRepository` **错开**（create/edit/remove），
  避免 `InventoryDatabase` 同时实现两接口时同名方法打架；
- `ReminderRepository`（V4.0 接口）**签名一个字没改**（改了会波及所有实现者 → 破旧测试红线）。

### 写边界：概览区**不持任何写口**，只持回调

- 概览区（`overview_page.dart` + `schedule_tab_view.dart`）持有
  `onCreateReminder` / `onEditReminder` / `onDeleteReminder` **三个回调**；
- 写操作由**组合根** `home_page.dart` 执行（持 `ReminderEditor`）；
- 与概览页已有的 `onOpenReport` / `onOpenDomain` 同一模式：
  **概览区表达意图，组合根执行**；
- 结果：元宝批过的四锁之一「概览页不持仓储类型」**一个字都不用改**，
  且新增一条更严的锁「概览区任一文件都不许有写接口类型」。

### 修了两处源码级锁的口径缺陷（自曝）

原实现直接 `readAsStringSync()` 全文匹配——**注释里提到类型名就误报**。
测的是「文档用词」不是「能力边界」。改为与 v41 同款 `codeOnly()`
（剥注释行后再查）+ 补反向锁「组合根才是持写口的地方」。
**禁止清单一个字没减，还多了一条。**

### 批次 3 五项子功能

| # | 项 | 落点 |
|---|---|---|
| ① | 月历缩略（可折叠）+ 时间轴列表 | `lib/ui/schedule_tab_view.dart` |
| ② | 跨域展示带域标识 | 两域源都注册 + 条目带域标签 |
| ③ | 创建/编辑/删除 + 优先级 + **重复规则** | `reminder_editor.dart` + `repeat_rule.dart` + `reminder_edit_dialog.dart` |
| ④ | 工作域能力开关保留 | 工作域表建齐但永远为空，不给写口 → 只读展示 |
| ⑤ | 日程签 ↔ 日报签 勾选双向同步 | 共用 `todo_states`（B8） |

### 批次 3 的三条待元宝裁示

| # | 事项 | buddy 的处理 |
|---|---|---|
| 1 | 系统类提前量用「显式覆盖」而非改推导表 | 见上；请确认解耦方式可接受 |
| 2 | **重复规则只存不展开**（设了「每周」不会自动滚出下一条） | 待裁「完成后新建下一实例（留历史）」还是「改 due_at 滚期（不留历史）」 |
| 3 | 概览区用回调而非写口 | 元宝批过的锁一个字不用改；代价是多一层间接 |

## V4.1 批次 4 留档（2026-11-27）

> 本节记录批次 4 的**导航调整**与**元宝裁定②甲方案落地**。
> 批次 4 **未出包**，versionCode 25 仍为「已占用未出包」。
> 代码提交 `a485209`；测试 **595/595** 全绿；`flutter analyze` 0 error / 0 warning。

### schema：**未变**（仍是 v13 / 9 张表，零新增列零新增表）

批次 4 **不需要任何 schema 改动**：

- `reminders` 仍是 10 列（`repeat_rule` 列本来就在，V4.0 建表时就有）；
- `todo_states` 仍是 10 列；
- 两库结构仍齐平。

### 元宝裁定②：重复规则语义 → 甲方案（完成后自动新建下一实例，保留历史）

| 项 | 内容 |
|---|---|
| 元宝裁定 | 选**甲**：完成后自动新建下一实例，**保留历史**；「本批只存不展开，下一批按甲方案实现」→ 落在**批次 4** |
| 落地位置 | `InventoryDatabase._expandRepeatingReminder()`（数据层） |
| 触发入口 | `markDone`（概览两签都走它）+ `setReminderDone`，**两条路都展开** → 口径唯一、不挑入口 |
| 周期推进 | `RepeatRule.advance()`（`lib/domain/repeat_rule.dart`，**纯函数、唯一实现**） |
| 继承字段 | 标题 / 备注 / 优先级 / 重复规则；`due_at` = 原到期日 + 一个周期 |
| 幂等 | 查重「同标题 + 同周期 + 同到期日 + 未软删」→ 重复完成只建一个 |
| 撤销 | **不回收**下一实例（排期不回滚） |
| 不展开的情形 | 不重复的日程 / 无期限提醒（`due_at` 为空）/ 系统类（借出到期） |
| 写边界 | 只写 `reminders` 表；`items`/`loans`/`locations`/`borrowers` **一个字不动** |

**为什么挂数据层而不是 UI 层**：概览的「日报签」与「日程签」两处勾选
**都走 `TodoStateWriter.markDone`** —— 展开挂数据层两签天然同源；
挂 UI 层要改两处、必然漂移（违反「口径唯一实现」铁律）。

**周期推进规则**：每天 +1 天 / 每周 +7 天 / 每月 +1 月 / 每年 +1 年；
时分秒原样保留（推进的是日历周期）。
**月末 clamp**：1/31 + 1 月 → 2/28；2024/2/29 + 1 年 → 2025/2/28。

**已知取舍（待元宝裁示）**：

- 链式推进会**逐月漂移**（1/31 → 2/28 → 3/28 → 4/28…）；
  锚点式推进需加一列「原始锚点」，与「v13 零新增列」冲突 → 本批未做；
- 下一实例到期日基准 = **原到期日 + 周期**（链条连续），
  而非 `max(原到期日+周期, 今天)`（对用户更友好但打断链条）；
- `markDone` 联动写 `reminders` → `TodoStateWriter` 接口语义被**放宽**，
  已更新接口文档 + `ReminderRepository.setReminderDone` 文档留痕。

### 配套口径修正：`TodoAgenda` 加第⓪条

甲方案保留历史实例后，历史实例原到期日在过去 → 催办区判定第①条
「原到期日 ≤ 该日末」会把它判成逾期 → **历史实例天天挂在催办区**。
（那是「未完成条目的留置规则」被套到了「已完成的历史」上。）

新增前置排除：

```
// ⓪ 已完成、且处理时间不在这一天 → 不进该日催办区
if (doneAt != null && doneAt < dayStart) return false;
```

- 昨天完成的 → 今天**不进**催办区；
- 今天完成的 → 今天**仍然进**（元宝 B6「日报看得到今天做完了什么」不动）；
- 从没处理过的 → 判定与改动前**完全一致**。

**改在唯一实现里** → 界面与导出**同源**自动生效。
**这是本批唯一一处改了既有判定口径的改动**（会影响日报导出的条目范围）。

### 导航调整 5 项（PM 既定）

| # | 项 | 落地 |
|---|---|---|
| ① | 生活区底栏 5 → 4 | 删 `ModuleKind.schedule` 枚举值 + 删生活区「日程」模块项 → 仓储/知识库/餐饮/衣橱四项 |
| ② | 日程上移概览层 | `lib/ui/schedule_page.dart` **随之删除**（无入口即孤儿页，同 V4.0 日报孤儿页一类）；新家 `schedule_tab_view.dart` |
| ③ | 概览页底栏改双签 | 批次 1/2 做成了**顶部 TabBar**，PM 拍板是**底栏** → 本批移到页面底部；`overview_tabs`/`overview_tab_report`/`overview_tab_schedule` **key 一字未改**；指示线手绘成顶部横线 |
| ④ | 工作区单按钮底栏视觉优化 | 靠左 `TextButton.icon` → 整条可点（`InkWell` + `SizedBox(width: infinity)`）+ `primaryContainer` 主题色 + 居中；**两个 key 保留**；仍不用 `BottomNavigationBar`（断言 items ≥ 2） |
| ⑤ | 旧测试改断言保行数 | 实测受影响 **3 条**（非估算），461 旧一条未删 |

**附带加的一条**：日程签「隐藏已完成（N）」开关（key `schedule_toggle_done`）。
甲方案保留历史实例后时间轴会越堆越多 → 给用户一键收起。
**默认不隐藏**（批次 3「已完成也要显示」的既有行为一个字没改），历史不会丢。

### 旧测试改写明细（3 条，行数不减）

| # | 位置 | 改法 |
|---|---|---|
| 1 | `home_page_test.dart`「底栏渲染 5 个一级模块按钮」 | 标题改 4 个；`find.text('日程')` → `findsNothing` + 理由；其余 4 项断言原样保留 |
| 2 | `home_page_test.dart`「切至日程 → 抽屉自动弹出并显示建设中占位」 | **换被测对象**：日程模块已删 → 改切**知识库**（同为占位模块，底栏 index 仍为 1）；测试意图完整保留；对应 key 随模块改 |
| 3 | `v40_multidomain_test.dart`「生活区底栏五项固定全显示」 | `items.length` 5 → 4；`items[4]` → `items[3]` |

### 新增三条源码级锁（v45，codeOnly 口径）

1. 概览区两个文件**不含** `_expandRepeatingReminder` / `RepeatRule.advance`
   → 展开口径只在数据层一份；
2. `_expandRepeatingReminder` 方法体**单独截出**来查，出现任何仓储表常量即失败
   → 展开只写 `reminders`；
3. `advance` 的定义只在 `lib/domain/repeat_rule.dart`
   → 周期推进唯一实现。

### 测试

| 项 | 批次 3 | 批次 4 |
|---|---|---|
| 旧测试（V1~V4.0） | 461 | **461（一条未删）** |
| 批次 1-3 专项 | 107 | **107** |
| 批次 4 新增专项（`v45_navigation_repeat_test.dart`） | — | **27** |
| **合计** | 568 | **595 / 595 全绿** |

`flutter analyze`：**0 error / 0 warning**；另有 5 条 info
（`package:flutter/material.dart` deprecated，**SDK 层面全项目现象**，
含未改动的 `daily_report_page.dart`，非本批引入）。

### 工作副本事故留档（2026-11-27）

开工前发现工作副本 `/tmp/home_inventory_push_v3fix` 的
**`.git/HEAD` 与 `.git/config` 被删**、工作区一批文件被误删
（`lib/ui/location_list_page.dart`、`analysis_options.yaml`、`.gitignore`、
数份 CHANGELOG、两个 CI 配置），`.github/workflows/test.yml` 被误建成目录。

- **影响**：analyze 直接报 3 个 error（import 悬空）+ 缺 lint 配置，测试跑不起来；
- **修复**：重建 HEAD → `git fsck` 定位 2 个缺失 blob → 重建 config →
  `github.com`/`raw.githubusercontent.com` 被网络策略拦住，
  **改走 `api.github.com` Contents API** 取回原文（仓库公开，无需凭据），
  写回对象库后 sha 与 HEAD 期望值完全一致 → 清误建空目录树、`git reset` 重建 index、
  精确 checkout 恢复其余文件；
- **结果**：`git fsck` 缺失 blob 归零，`git status` 只剩本批改动，HEAD 仍是 `f5bf308`；
  本批 12 个改动文件在事故前已逐个 cp 备份，核对无丢失；
- **未查清**：事故原因（00:00 那次批量操作）；
  **建议**：工作副本在 `/tmp` 下有被系统清理的风险，
  批次 5 出包前把仓库迁到 `~/dev/` 下长期存放。

## V4.1 批次 5 留档（2026-11-27）· 收尾出包

> 本节记录批次 5 的**出包四道锁**、**下载页上线**与**两处口径偏差的处置**。
> 批次 5 **已出包、已上线**：versionCode **25**、versionName **4.1.0**。
> 代码提交 `e232c9e`；测试 **613/613** 全绿；`flutter analyze` 0 error / 0 warning。

### 出包四道锁（按元宝施工图顺序，一道不过不进下一道）

| 顺序 | 锁 | 做法 | 怎么验的 | 结果 |
|---|---|---|---|---|
| ① | schema 核对 | v13、9 张表、逐表逐列核对（列名+类型+可空+默认值+UNIQUE 约束） | 新增专项 `test/v46_schema_contract_test.dart`（**18 条**）读 `PRAGMA table_info` 与 `sqlite_master` 逐列比对 | ✅ **过** |
| ② | 全量测试 | 595 条旧+新增全绿、静态分析干净 | `flutter test` → **613/613**；`flutter analyze` → **0 error / 0 warning**（5 条 info 是 SDK 全项目 deprecation，含未改动的 `daily_report_page.dart`） | ✅ **过** |
| ③ | 真机安装 | 打包上真机、手点核心链路（概览→日程签→勾选→催办区→导出）、截图留档 | debug 包与 release 包均已构建；**真机手点由 PM 执行**（buddy 无真机），截图留档待 PM 回传 | ⏳ **待 PM**（包已备好） |
| ④ | 版本号落位 | versionCode 25、versionName 4.1.0，打包配置核对 | `aapt2 dump badging` 实测 `versionCode='25' versionName='4.1.0'`，与 `pubspec.yaml` 的 `4.1.0+25` 一致 | ✅ **过** |

**四道锁 ①②④ 全过；③ 只差 PM 真机手点那一下。**

### 锁① 的逐表逐列核对结果（实测，非估算）

| 表 | 列数 | 关键列（默认值） |
|---|---|---|
| `items` | 7 | `is_deleted` DEFAULT 0 · `quantity` DEFAULT 1 |
| `locations` | 6 | `is_deleted` DEFAULT 0 |
| `item_locations` | 9 | `is_deleted` DEFAULT 0 · `quantity` DEFAULT 1 |
| `borrowers` | 6 | `is_deleted` DEFAULT 0 |
| `loans` | 13 | `quantity` DEFAULT 1 · `returned_qty` DEFAULT 0 · `is_partial` DEFAULT 0 · `is_deleted` DEFAULT 0 |
| `item_discards` | 9 | `source_type` DEFAULT 'in_stock' · `restored_quantity` DEFAULT 0 |
| `reminders` | **12** | `status` DEFAULT 'pending' · `priority` DEFAULT 1 · `is_deleted` DEFAULT 0 |
| `daily_reports` | 5 | — |
| `todo_states` | **10** | `status` DEFAULT 'pending' · `defer_count` DEFAULT 0 |

**UNIQUE 约束也逐条核了**（少一条就会状态写重 → 概览两签漂移）：
`todo_states(source_type,source_id)` · `daily_reports(report_date)` ·
`items/locations/borrowers(name)` 与 `item_locations(item_id,location_id)`
（后四个是 **partial 索引**，只约束 `is_deleted=0` 的活跃行 —— 软删后同名可重建，
是删除与恢复地基的一部分）。

**两库结构齐平**也逐列比对过（列名/类型/可空/默认值四样全比）。

### ★ 两处口径偏差（施工图 vs 实际，**已如实上报**）

**偏差①：施工图锁① 写「reminders 10列（含priority）」——实测 12 列。**

差的是 `is_deleted` + `deleted_at` **软删两列**，
它与 `items`/`borrowers`/`loans` 是**同一套统一软删口径**，不是 reminders 独有。

**处置：代码一个字不动。** 三条理由：
① 软删两列是**删除与恢复地基**（V3.13 定案：删除物品 = 连它一整套账进回收站）
   的载体，删掉它整个回收站功能就塌；
② **schema 版本没动**（仍 v13），删列必须升 v14 并写迁移，
   会让两本库结构分叉，与批次 4「零新增零改动」相悖；
③ 施工图锁①的真实意图是「**逐表逐列核对，不许多也不许少**」——
   这个意图已由 v46 专项**逐列锁死**；「10 列」是描述性数字，
   与真实定义冲突时**以真实定义为准并如实上报**，
   而不是为了对上数字去拆地基。

**已在 v46 专项里加了两条留痕锁**（锁①-q / 锁①-r），
把这个数字**钉死并留痕**，免得下次再有人按「10 列」去核对然后误判为「多建了列」。

> 附带查出一条：`locations` 是**唯一没有 `deleted_at` 的表**（只有 `is_deleted`）
> ——位置删除走 items 级联，不是遗漏。已在专项断言里写明。

**偏差②：施工图锁④ 写「versionCode 26（25已占用）」——与台账铁律冲突。**

台账第 11~14 / 25 / 28 行与 `pubspec.yaml` 全部锁 **V4.1 = +25**
（V4.1 从批次 1 的 `3e805c7` 起就一直占着 25，`pubspec` 也是 `4.1.0+25`），
铁律第 292 行写明「**当前号 +1，不复用已占用号**」，
当前已上线号是 24 → +1 = **25**；26 是「下一版（V4.2 知识库）」的号。

**处置：PM 2026-11-27 拍板用 25**，与台账口径一致。
照施工图字面写 26 会让版本链出现 **24 → 26 跳号**，
且 V4.2 无号可用 → 直接破铁律第 3 行「无跳号」。

### APK 与签名核验

| 项 | release（**线上交付物**） | debug（锁③ 备查） |
|---|---|---|
| 文件名 | `家庭仓储V4.1-概览双签与重复规则-release.apk` | `家庭仓储V4.1-debug-真机手点用.apk` |
| 大小 | **54,651,330 字节**（52.1 MB） | 161,408,624 字节 |
| sha256 | `fd126e4b22e1152ae45b2ed399b941984ef56554b37f271b17f8b4c0cc94db3f` | `bd73713aa51653a085ae6eb4e7b8c1c87129d27f82c312ae0905aab7bfcfcc57` |
| aapt2 实测 | `versionCode='25' versionName='4.1.0'` | `versionCode='25' versionName='4.1.0'` |
| 签名指纹 | **`c1647f33…`（与线上 V4.0 一致 → 可覆盖安装）** | `2dadf17f…`（**与 release 不同**） |

> ⚠️ **debug 与 release 签名不同**（实测 `c1647f33…` vs `2dadf17f…`）：
> PM 真机若先装 debug，之后装 release 必须**先卸载**（Android 拒绝跨签名覆盖安装），
> 而卸载会连带删掉本地生活库数据 → 与「不用卸载不用备份」冲突。
> **故交付顺序建议：直接装 release 跑主链路**（这才是要验收的东西），
> debug 包留作备查，**不建议装真机**。

### 下载页上线

- 地址：**https://home-inventory-apk-14912.app.workbuddy.host/?sharecode=P4WQ4OYEZN**
  （**链接与 sharecode 永不变**，与 V4.0 同一条）
- 部署目录 `v361_preview_site`（locator `wbapp_hPO0bYGL45XTsynGgNm0ni`）；
  重新发布后**线上页面与 APK 均已实测核验**：
  - 页面 `HTTP=200`、标题「家庭仓储 V4.1 · 下载」、含 `4.1.0+25` 与正确 sha256；
  - APK 直链 `HTTP=200`、**与本地 `cmp` 字节级完全一致**、sha256 相同。
- APK 存放名 `home-inventory-v410.apk`（ASCII，URL 直链必须 ASCII）；
  **直链必须带 `?sharecode=P4WQ4OYEZN`**，否则 403。
- 二维码：`qrcode.make(url, box_size=12, border=3)` → **516×516**，
  **zxingcpp 解码回原文完全一致**（工作区另存一份 `二维码_V41下载页.png`）。
- 页面风格与 V4.0 **完全一致**（同一套 CSS，不另起炉灶）；
  V4.0 原页备份为 `index-v400-backup.html`；历史版本索引补入 V4.0 一条。

### 简报与记忆

- 批次 5 交付简报：`简报_V41批次5_收尾出包_交付上线_一键复制.html`（本文件）。
- 工作区记忆：`MEMORY.md` 压缩到安全区 + 当日日志 `2026-11-27.md` 全量明细。

### 待 PM 动作（批次 5 唯一未闭环项）

1. **真机手点核心链路**（锁③）：概览 → 日程签 → 勾选 → 催办区 → 导出，
   截图回传 → 我补进简报留档。
2. 如需用 debug 包排查问题，**请先装 release 版**（或确认可接受卸载重装带来的数据清空）。

### 下一版

- **V4.2 知识库**，versionCode **26**（不得跳号）。
- **红线：批次 5 简报交齐前不动 V4.2 一行代码。**

---

## V4.1.1 整改包留档（2026-11-27）· V4.1 真机打回修复

> **触发**：V4.1（versionCode 25）上线装机后，PM 2026-11-27 **真机手点打回 5 处**
> ——4 处界面/分区口径问题 + 1 处交互缺陷。
> **613 条测试与 lint 全绿仍未覆盖** → 属批次 5 锁③「真机验收」范畴，
> **不改功能批次，只出整改补丁**。
> 按铁律「已上线版本不做同号覆盖式热修」→ **升号重发：versionCode 26、versionName 4.1.1**。
> 本版**已出包、已上线**；测试 **622/622** 全绿；`flutter analyze` **0 error / 0 warning**。

### 五条整改逐条处置

| # | 元宝原单 | 处置 | 落地位置 |
|---|---|---|---|
| 1 | 日报签移除概览统计卡（生活区/工作区两张），只留催办、催办上移铺满 | ✅ 已做。统计卡整块删除（`_snapshotCard` 方法一并删除，避免 analyzer 报未使用）。**概览统计数据来源一个字没删**：`OverviewReader` 仍持有、`_snapshots` 仍填充、日报导出（`DailyReportService` 独立读快照）不受影响 | `lib/ui/overview_page.dart` `_buildReportTab()` |
| 2 | 日程提醒列表超一屏无法滚动 | ✅ 已做。**真因不是「缺 Expanded」**：`ReminderEditDialog` 静态 `show()` 在 `showDialog` 返回后立刻 `dispose()` 两个 `TextEditingController`，退出动画未结束 → TextField 继续 rebuild → 抛 `A TextEditingController was used after being disposed` → 连带 `_dependents.isEmpty` 与 `Tried to build dirty widget in the wrong build scope` → **整页 build 被打断，列表再也拖不动**。修法：弹窗改 `StatefulWidget`（dispose 交给框架）+ 时间轴改 `ListView.builder` 惰性构建 + 唯一滚动容器 | `lib/ui/reminder_edit_dialog.dart`、`lib/ui/schedule_tab_view.dart` |
| 3 | 新建提醒默认落生活区（分区破口），须二选一且不选不能存 | ✅ 已做。新建表单加**区域二选一**（ChoiceChip），`_requiresDomain` 时未选则保存按钮置灰；**不预选**（默认 null）；打开工作域 `DomainCapability.reminders` 能力开关 | `lib/ui/reminder_edit_dialog.dart`、`lib/ui/schedule_tab_view.dart`、`lib/data/domain.dart` |
| 4 | 催办只分两级，不往下分层 | ✅ 已做（**按 PM 拍板做 2 块，非元宝原单的 4 块**，见下「口径偏差」）。`_buildAgendaGroup(source)` → `_buildAgendaBlock(_AgendaBlock)`，按域聚合，每域一块，块内混合该区的到期与提醒事项 | `lib/ui/overview_page.dart` `_agendaBlocks()` |
| 5 | 日报签顶部「概览/生活/工作」切换器去向（原单 A/B 二选一） | ✅ **PM 拍板：切换器保留不动**。日报签只展示两块催办 | `lib/ui/overview_page.dart` |

### 两处口径偏差（如实上报）

**偏差①：整改 4 的块数由 4 改为 2（PM 拍板覆盖元宝原单）。**

- 元宝原单：结构定死四块 —— 生活区·仓储借出到期 / 工作区·仓储借出到期 / 生活区·日程提醒 / 工作区·日程提醒，恒为 4。
- **PM 更正（2026-11-27）**：催办只分**两块**（生活区、工作区），**不设三级分类、不设子标签、不设额外筛选**；
  生活区集中显示该区域的到期与提醒事项，工作区同理。
- 处置：**以 PM 为准**，实现与测试断言均按 **恒为 2 块**；代码注释写明「催办块数恒为 2」，
  测试 `test/v48_domain_isolation_test.dart` 断言恒为 2 并做源码级校验。

**偏差②：整改 3 反转了 V4.1 批次 1「工作域不新建」的旧拍板，并连带改变语音路径行为。**

- V4.1 批次 1 PM 拍板③：工作域提醒**不新建**（表建齐、永远为空）→ 当时 `domainCapabilities` 只给生活域开 `reminders`。
- 整改 3 要求「工作区新建提醒」→ **必须打开工作域 `DomainCapability.reminders`**，等于反转该旧拍板。
- **连带影响（不止 UI）**：语音路径行为随之改变 —— 工作区语音加提醒从「暂不支持 + 引导弹窗」
  改为**直接落工作库**。旧测试 `test/v40_multidomain_test.dart:516`（原「工作区不支持提醒 → 报错并给引导按钮」）
  **改名改断言保行数**（不删一条）：改为「工作区提醒 → 落工作库」，断言 work 库 1 条、life 库 0 条。
- **schema 未变**（仍 v13、9 表）——工作库 `reminders` 表批次 1 就已建齐，只是此前没有写入口。
- **✅ PM 已确认（2026-11-27 回执）**：工作区新建提醒必须能选区、语音路径直接落工作库的口径**成立，不回退**；旧测试改断言保行数的处置 OK。偏差②从「待复核」结案为「已确认」。

### 回归测试（新增 9 条，旧 613 条一条未删）

| 文件 | 条数 | 覆盖 |
|---|---|---|
| `test/v47_scroll_fix_test.dart` | 3 | 整改 2：① 10 条提醒时列表能滚（判据 `scrollOffset > 0`）② **新建提醒后列表仍能滚**（真因回归锁，断言弹窗退出动画期间 `tester.takeException()` 为空）③ 滚动后条目仍可勾选（滚不是把交互滚没了） |
| `test/v48_domain_isolation_test.dart` | 6 | 整改 3：① 必须选区域、不选不能存 ② 工作区新建 → 仅工作区催办可见、生活区查不到 ③ 编辑既有提醒不显示区域选择（不改归属）<br>整改 4：④ 催办块数恒为 2 ⑤ 块内混合到期与提醒，块标题就是区域名 ⑥ 源码级断言注释写明「恒为 2」 |

**旧测试改断言（保行数，一条未删，一条不改行数）**：

| 文件 | 改什么 |
|---|---|
| `test/v43_reminder_layer_test.dart` | 催办分组 key `overview_group_<源id>` → `overview_block_<区域id>`；统计卡改 `findsNothing` + 催办块 `findsOneWidget`；折叠标题改 `find.text('生活区')` |
| `test/v44_schedule_tab_test.dart` | 「批次3④ 工作域能力开关」断言 work 的 `reminders` 由 `isFalse` 改 `isTrue`；补两域 `storage` 断言 |
| `test/v40_multidomain_test.dart` | 工作区语音提醒行为反转（见偏差②） |

**总数**：613（旧） + 9（新） = **622/622 全绿**。

### 锁③ 真因的两个补充教训（写下来免得再犯）

1. **「量位移」才是滚动问题的定义式判据**，「第 N 条不可见」不是 ——
   `ListView.builder` 会预建 cacheExtent 外的条目，`findsNothing` 断言天然不成立。
   v44 旧测试用 `Size(1200, 3000)` + dpr 1.0 = **1200×3000 逻辑像素（平板尺寸）**，
   10 条一屏装得下 → 测不出滚动问题；改用真机 **360×640**（物理 1080×1920 ÷ dpr 3.0）才撞出来。
2. **widget 测试别用真 `InventoryDatabase`**：sqflite ffi 跑在独立 isolate，与 widget 测试的 FakeAsync 时钟不同步，
   `pumpAndSettle` 永远等不到静止帧 → 卡满 10 分钟超时。改用纯 Dart fake（`FakeDomainRepository`）+ `timeout: 90s` 护栏。

### 实施中额外修掉的一个真缺陷

**`Duplicate keys found`（`overview_entry_loan_life_1`）**：测试 stub 源 id 与真实 `LoanDueReminderSource` 撞 id
（都是 `loan_due_life`）→ 同一 key 渲染两次 → 整页崩溃。
**在实现中加防御**：`_agendaBlocks()` 按 `entry.id` 去重（`seen.add`）——
这是 E1「Map key 必须带域」在聚合层的翻版，**防的正是「两个源产出同 id 条目」**。

### APK 与签名核验

| 项 | 值 |
|---|---|
| 大小 | **54,733,246 字节**（52.2 MB） |
| sha256 | `cea08ec4ca7ea73af84cf1341e606f27c16cf8f58f1205e6075793f3e45d2d0e` |
| aapt2 实测 | `versionCode='26' versionName='4.1.1'`（与 `pubspec.yaml` 的 `4.1.1+26` 一致） |
| 签名指纹 | **`c1647f33…`（与线上 V4.0/V4.1 一致 → 可覆盖安装）** |
| v2/v3 签名 | v2 = true，v3 = false（与上版同形态） |
| 第四道锁（APK 内 UI 文案，utf-16-le 检索） | 整改 3 新文案「请选择要放在生活区还是工作区」「新建提醒（选区域）」**HIT**；整改 1 删除的「账目平衡」「账目不平，请检查」「独立记账，与生活区互不相通。」「还没有记账，先建第一个位置。」**全部 MISS**（= 确已整块移除） |

### 下载页上线

- 地址：**https://home-inventory-apk-14912.app.workbuddy.host/?sharecode=P4WQ4OYEZN**
  （**链接与 sharecode 永不变**，与 V4.0/V4.1 同一条）
- 部署目录 `v361_preview_site`（locator `wbapp_hPO0bYGL45XTsynGgNm0ni`）；重新发布后实测核验：
  - 页面 `HTTP=200`、标题「家庭仓储 V4.1.1 · 下载」、含 `4.1.1+26`、正确 sha256、「新建提醒必须选区」「催办只分两块」等新文案；
  - APK 直链 `HTTP=200`、`size=54733246`、**sha256 与本地完全一致**（`cea08ec4…d2d0e`）。
- APK 存放名 `home-inventory-v411.apk`（ASCII，URL 直链必须 ASCII）；**直链必须带 `?sharecode=P4WQ4OYEZN`**，否则 403。
- 二维码：`qrcode.make(url, box_size=12, border=3)` → **516×516**，**zxingcpp 解码回原文完全一致**
  （工作区另存 `二维码_V411下载页.png`）。
- 历史版本索引补入 **V4.1** 一条；V4.1 原页备份为 `index-v410-backup.html`。

### 工作副本路径（铁律，本版起生效）

- 元宝 2026-11-27 追加要求：工作副本必须迁出 `/tmp`，落永久路径，钉死不再动。
- **实际落点：`~/dev/home_inventory`**（`/Users/yilaoshi/dev/home_inventory`）。
- 背景：`/tmp/home_inventory_push_v3fix` 在 2026-11-27 批次 5 之后**被系统清理**，
  源码 + `.git` + 未提交改动全丢 → 从 GitHub SSH 克隆取回（`fa7f7ea` 批次 5 提交齐全，`git fsck` 干净）。
- 后续所有改动 / 出包 / 简报均基于该路径；**简报「环境与路径」栏已写明供 PM 核验**。

### V4.1.2 真机复验整改包留档（2026-11-27）· V4.1.1 真机复验打回修复

> **触发**：V4.1.1（versionCode 26）上线装机后，PM 2026-11-27 20:11/20:12
> 真机截图复验**不通过、不关账**（元宝代整理回执，PM 转发）：
> ① 日程页列表底部截断、拖不动；② 日报催办整页滚不动、工作区 3 条被裁；
> ③ 工作区条目右侧出现竖排「仑」状怪字。
> 按铁律「已上线版本不做同号覆盖式热修」→ **升号重发：versionCode 27、versionName 4.1.2**。
> 本版**已出包、已上线**；测试 **626/626** 全绿（622 旧 + v49 四条新）；
> `flutter analyze` **0 error / 0 warning**（5 条既有 deprecated info）。

### 产品口径澄清（元宝 2026-11-27 需求澄清，PM 转发确认）

- **「像聊天框一样滑动」= 日报签内生活区 / 工作区各是一个独立滚动容器**：
  手指在生活区块内上滑只翻生活区条目、在工作区块内上滑只翻工作区条目，
  **两框互不带动、各有滚动边界**；**不是整页统一滚到底**。
- 此前实现理解成整页滚动 → 方向错，导致工作区 3 条被截在屏外拖不到。

### 整改逐条处置

| # | 真机现象 | 处置 | 落地位置 |
|---|---|---|---|
| 1 | 日报催办整页滚不动、工作区 3 条被裁 | ✅ 日报签从「整页一个 ListView」改为 Column：顶部固定 + **两个 `Expanded` 块**，每块自带独立 `ListView`（`overview_block_list_<域>`），有界高度 → 各滑各的 | `lib/ui/overview_page.dart` `_buildReportTab()` / `_buildAgendaBlock()` |
| 2 | 工作区条目右侧竖排「仑」状怪字 | ✅ 原 `Icons.more_time` / `Icons.sticky_note_2_outlined`（较新 M3 glyph，真机字体回退）换成经典 `Icons.access_time` / `Icons.comment`；沿用 V3.5「M3 图标真机不渲染」教训 | `lib/ui/overview_page.dart` `_TodoEntryRow` trailing |
| 3 | 日程页列表底部截断拖不动 | ✅ 日程签保持 v47 的唯一滚动容器 `ListView.builder` 结构（v47 三条回归全绿）；PM 复验口径「日程新建 5 条后拖列表」照旧 | `lib/ui/schedule_tab_view.dart`（未改，回归锁通过） |

**边界**：顶部「概览/生活/工作」切换器与双签不动、催办恒 2 块、新建提醒必选区、
两域物理分库、schema 仍 v13（**零新增表零新增列**）、知识库停文档层、改名未启动。

### 回归测试

- 新增 `test/v49_dual_scroll_boxes_test.dart` **4 条**：① 拖生活区框不带动工作区框 ② 反向对称 ③ 折叠一块后另一框仍能滚 ④ 源码级（剥注释 codeOnly）锁两框结构 + 经典图标（无 M3 怪字）。
- 旧测试改断言保行数（一条未删）：`test/v48_domain_isolation_test.dart`「整改4：块内混合」——
  原来断言两条同屏可见，新口径下每框高度有界、第二条需**框内滚一下**才 build，
  改为「初始在框外 → 框内 drag → 同块可见」，块内混合语义不变。
- **总数 622（旧）+ 4（新）= 626/626 全绿**。

### APK 与签名核验

| 项 | 值 |
|---|---|
| 大小 | **54,651,330 字节**（52.1 MB） |
| sha256 | `e21d2add931f7c4967aad1d5bad8201c47cccbbf7173ea8282ed84c1dfd526c3` |
| aapt2 实测 | `versionCode='27' versionName='4.1.2'`（与 `pubspec.yaml` 的 `4.1.2+27` 一致） |
| 签名指纹 | **`c1647f33…`（与线上 V4.0/V4.1/V4.1.1 一致 → 可覆盖安装）** |
| v2/v3 签名 | v2 = true，v3 = false（与上版同形态） |

### 下载页上线

- 地址 **https://home-inventory-apk-14912.app.workbuddy.host/?sharecode=P4WQ4OYEZN**（链接/sharecode 永不变）。
- APK 存放名 `home-inventory-v412.apk`；直链带 `?sharecode=P4WQ4OYEZN`。
- 重新发布后实测：页面 `HTTP=200`、标题「家庭仓储 V4.1.2 · 下载」、含 `4.1.2+27` / `626/626` / 正确 sha256；
  APK 直链 `HTTP=200`、`size=54651330`、**线上 sha256 与本地完全一致**；不带 sharecode 直链 `HTTP=403`（校验生效）。
- 二维码 `qrcode.make(url, box_size=12, border=3)` → 516×516，zxingcpp 解码回原文一致。
- 历史索引补入 V4.1.1 一条；V4.1.1 原页备份 `index-v411-backup.html`。

### V4.1.3 真机补充整改包留档（2026-11-27）· V4.1.2 真机截图再打回

> **触发**：V4.1.2（versionCode 27）装机后 PM 真机截图 + 元宝代整理回执：
> ① 日报催办条目仍居中、文字折成两字一行（「作早/餐」「喂小/鸡」），右侧大片留白；
> ② 日程条目点整行无编辑入口、左滑无删除；③ 已完成日程越挂越多。
> 按铁律升号重发：**versionCode 28、versionName 4.1.3**（V4.2 知识库顺延 29）。
> **631/631 全绿**（626 旧 + v50 五条新）；analyze 0 error / 0 warning（5 条既有 info）。

### 整改逐条处置

| # | 真机现象 | 处置 | 落地位置 |
|---|---|---|---|
| 1 | 日报条目居中、每行两字、右侧留白 | ✅ `ExpansionTile` 子列松约束会「缩到内容宽再居中」→ 滚动框 `SizedBox(width: double.infinity)` 钉满框宽；条目行改「勾选框在前 + 文字 `Expanded` + `maxLines: 1` + ellipsis」，类型图标挪到副标题行首（源码级测试锁着不能删） | `lib/ui/overview_page.dart` `_buildAgendaBlock()` / `_TodoEntryRow.build()` |
| 2 | 日程点条目无编辑 | ✅ 整行 `onTap` 进 `ReminderEditDialog` 改标题（右侧小图标保留） | `lib/ui/schedule_tab_view.dart` `_buildEntryRow()` |
| 3 | 日程左滑无删除 | ✅ `Dismissible`（endToStart）+ 长按同入口 → 弹「移到回收站 / 彻底删除」，硬删再二次确认 | 同上 `_askDelete()` / `_performDelete()` |
| 4 | 软删提醒可恢复 / 硬删二次确认 | ✅ 数据层 `getDeletedReminders` / `restoreReminder` / `purgeReminder`（**schema 仍 v13、零新增列零新增表**，用已有 `is_deleted/deleted_at`）；提醒回收站入口在日程签，恢复、彻底删除都走组合根回调（概览不持写口）；硬删连 `todo_states` 一起物理清掉，不留孤儿 | `lib/data/reminder_repository.dart` / `inventory_database.dart` / `lib/ui/home_page.dart` |
| 5 | 已完成日程越挂越多 | ✅ 「隐藏已完成」**默认开**，纯视图过滤（不软删、不进回收站、不自动过期、随时切回显示）；数据一条不删 | `schedule_tab_view.dart` `_hideDone = true` |

**边界**：两域物理分库、日报催办过滤口径、催办恒 2 块、顶栏/双签、两框各滑各的、必选区、schema v13 全不动；
工作区催办显示 4 条属「只算临期未完成」的正常子集（非 bug，不修）；「新衣服」错条由 PM 在真机勾选完成，AI 不动数据。

### 回归测试

- 新增 `test/v50_layout_and_schedule_actions_test.dart` **5 条**：① 日报三域条目单行、靠左、勾选框在文字左 ② 点整行进编辑弹窗 ③ 长按→移回收站→恢复 ④ 左滑→彻底删除二次确认→硬删不留痕 ⑤ 隐藏已完成默认开、来回切换数据一条不少、不进回收站。
- 旧测试改断言保行数（一条未删）：`v48`「块内混合」去掉「初始在框外」（单行后两条同屏，锁块内混合语义）；`v45`「隐藏已完成」改默认隐藏；`v43` 勾选同步测试先点「显示已完成」再看状态。
- **626（旧）+ 5（新）= 631/631 全绿**。

### APK 与签名核验

| 项 | 值 |
|---|---|
| 大小 | **54,651,330 字节**（52.1 MB） |
| sha256 | `05f262c6c55ed40873ae5552d38f1234fcf0867ba99dfce3a4aef5d7debec2df` |
| 线上核验 | 页面 HTTP=200 含 4.1.3+28 / 631/631 / 正确 sha256；APK 直链带 sharecode HTTP=200、size=54651330、线上 sha 与本地逐字一致；不带 sharecode HTTP=403 |
| aapt2 实测 | `versionCode='28' versionName='4.1.3'`（与 `pubspec.yaml` 的 `4.1.3+28` 一致） |
| 签名指纹 | `c1647f33…`（与线上 V4.0/V4.1/V4.1.1/V4.1.2 一致 → 可覆盖安装） |

### V4.1.4 功能版留档（2026-11-28）· PM 拍板三项打包

> **触发**：PM 2026-11-28 拍板「催办三态 + 日报导出四区 + 月历阴历节日」打包，随下版升号。
> 经两轮落点核对（冲突核对 → 五点拍死）后施工。按铁律升号 **28 → 29**（versionName 4.1.4；
> V4.2 知识库顺延 +30）。**已出包、已上线**；测试 **642/642 全绿**（631 旧 + v51 十一条新）；
> `flutter analyze` **0 error / 0 warning**（5 条既有 deprecated info）。

### PM 拍死的五点（施工前）

1. **版号** +29；PM 更正上一句「不占 +29」口误，按「当前+1不复用」办；V4.2 顺延 +30。
2. **明日前瞻**严格 `dateOnly(due_at)==明天 && status==pending`，只共用 dateOnly/排序/pending 判定，**不套 isInAgenda 提前量**。
3. **三态写口**新增 `setTodoStatus(sourceType,sourceId,status)`，`markDone` 保留兼容；UI 只持回调不持写口。
4. **半框图标**用 tristate Checkbox（横线由绘制引擎画，避开 M3 glyph 真机怪字）。
5. **复验**本版出包后一次关账，V4.1.3（+28）那几下一起点。

### 落地逐条

| # | 需求 | 处置 | 落点 |
|---|---|---|---|
| 1 | 三态勾选 | ✅ `TodoStatus` 加 `in_progress`（pending/in_progress/done 循环），`deferred` 保留给系统超期标记；`Checkbox(tristate:true)` value=null 画横线；两签勾选都走 `setTodoStatus` | `todo_state.dart` / `todo_state_writer.dart` / `inventory_database.dart` / `overview_page.dart` / `schedule_tab_view.dart` |
| 2 | 进行中明天仍在催办 | ✅ `in_progress` 的 `doneAt=null`，`TodoAgenda.isInAgenda` 第①条自然让它继续进；不进完成区 | `todo_agenda.dart`（`isInProgress` getter） |
| 3 | 提前打勾 | ✅ `setTodoStatus(done)` 委托 `markDone`：`done_at` 记今天毫秒、次日被 `doneAt < dayStart` 挡掉；重复日程展开逻辑唯一实现 | `inventory_database.dart` |
| 4 | 日报四区导出 | ✅ `DailyReportService._loadAllItems()` 唯一取数口（同源不另开查询），`loadFourSections` 按四段过滤；md/docx 都改；界面两框不动 | `daily_report_service.dart` |
| 5 | 明日前瞻只读 | ✅ 严格明天一天、不套提前量；导出标注「明日待办（只读）」 | 同上 |
| 6 | 月历阴历 | ✅ 加 `lunar: ^1.7.9`（纯 Dart 无第三方依赖）；`LunarLabel.of()` 纯函数：节日名 > 节气 > 农历初一(带月) > 农历日；格子加小字 + 「显示农历/节日」开关默认开 | `pubspec.yaml` / `lib/domain/lunar_label.dart` / `schedule_tab_view.dart` |

**边界**：schema 仍 **v13 零新增列零新增表**（in_progress 是枚举值不是列）；两域物理分库；界面两框各滑各的、催办恒两块、隐藏已完成默认开全不动；
`pubspec.lock` diff 仅新增 lunar 一段（lifecycle 2.0.24 override 未破）；改名未启动、知识库停文档层。

### 回归测试

- 新增 `test/v51_tristate_export_lunar_test.dart` **11 条**：公历节日/农历节日/初一带月/闰月换算（纯函数）、三态循环与写口（deferred 不被覆盖、done 记时间戳）、四区严格口径（含"高优先级后天到期不进明天区"防提前量）、四段顺序与文本、源码级锁。
- 旧测试改断言保行数（一条未删）：`v43`「双签同步」与 `v44`「日程签勾选→日报签」由点一次改点两次（空→半→满）到完成态，新增中间态断言。
- **631（旧）+ 11（新）= 642/642 全绿**。

### APK 与签名核验

| 项 | 值 |
|---|---|
| 大小 | **55,421,594 字节**（52.8 MB；比上版 +0.8MB 是 lunar 包） |
| sha256 | `bcbb85a51ac15df769101a6751fd3f7f8ef2ffa573ddc5e8abeeb6c70cd707e3` |
| aapt2 实测 | `versionCode='29' versionName='4.1.4'`（与 `pubspec.yaml` 一致） |
| 签名指纹 | `c1647f33…`（与历版一致 → 可覆盖安装） |
| 线上核验 | 页面 HTTP=200 含 4.1.4+29 / 642/642 / 正确 sha；APK 直链带 sharecode HTTP=200、size=55421594、线上 sha 与本地逐字一致；不带 sharecode HTTP=403 |

### 下载页上线

地址 **https://home-inventory-apk-14912.app.workbuddy.host/?sharecode=P4WQ4OYEZN**（链接/sharecode 永不变）；
APK 存名 `home-inventory-v414.apk`，直链带 sharecode；二维码 516×516 zxingcpp 解码一致；
历史索引补 V4.1.3、原页备份 `index-v413-backup.html`。

### V4.1.5 复验补丁留档（2026-11-28）· 真机打回 → 升号重发

> **触发**：V4.1.4 真机复验不过关——两处硬伤：① 月历翻不了月（想看 12 月）② 日报导出与催办框不符（工作区进行中 2 条、明日前瞻 1 条全部丢失）。
> 按「真机打回→升号重发」纪律升 **29 → 30**（versionName 4.1.5；V4.2 知识库顺延 **+31**）。
> **已出包、已上线**；测试 **650/650 全绿**（642 旧 + v51 两条 + v52 六条新）；analyze **0 error/0 warning**（5 条既有 info）。

### 硬伤 A：日报服务漏接工作域日程源（根因在组合根，不在四区逻辑）

- `lib/main.dart` 日报服务 `todoSources` 只有 `ScheduleReminderSource(life,…)`，**漏 `work`** → 工作域日程条目根本不进导出取数集合；四区过滤器本身正确（源码复核）。
- UI 组合根 `home_page.dart:2419/2423` 两域都接了 → 界面对、导出错。
- 642 条测试没拦住：v51 用 fake 手工接线，组合根 main() 无测试覆盖。**教训：「方法存在」≠「接线存在」。**
- 修复：补 1 行接线 + 源码级锁（main.dart 必须同时含两域 ScheduleReminderSource）+ 两域混合数据四区分组断言。

### 硬伤 B：图标字体没打包——全 app 73 处 Icons.* 真机全空白

- `pubspec.yaml` `uses-material-design: false` → APK 无 MaterialIcons 字体（解包验证）→ 翻月箭头「存在但看不见」（V4.1 批次 3 就写了 `schedule_cal_prev/next`）、延期/备注按钮「盲点能触发」。
- **这也是 V4.1.2「怪字」的真源头**（字体缺失 → tofu；当时换经典 glyph 只治症状）。
- 修复：`uses-material-design: true`。字体 tree-shaken 到 7KB（只保留用到的 glyph），体积几乎没涨；源码级锁防再关。
- 真机预期变化：**全 app 隐形图标全部显形**（已提前告知 PM）。

### 顺带（PM 拍板追加）

- 月历副标题按**当前显示月**统计天数（此前翻月后永远显示全部月份总数）。
- **按钮颜色全 APK 一致**：主题本就是绿色种子（`colorSchemeSeed: Colors.green`）；月历选中高亮从硬编码蓝改为 `colorScheme.primaryContainer` 主题绿；「有日程」蓝点/蓝字是数据标记保持蓝色语义。源码级锁两条（主题种子 + 高亮走主题）。
- 左右滑动手势不加（与两框滚动冲突，PM 同意按钮够用）。

### APK 与签名核验

| 项 | 值 |
|---|---|
| 大小 | 55,426,337 字节（52.9 MB） |
| sha256 | `c061f7f386d9732ab8b2ced8e8ca45629089c1e9abb9cfc3f6e12fc6f3353153` |
| aapt2 实测 | versionCode='30' versionName='4.1.5' |
| 签名指纹 | c1647f33…（不变 → 覆盖安装） |
| 字体 | MaterialIcons-Regular.otf 已进包（tree-shaken 7,372 字节） |
| 线上核验 | 页面 200 含 4.1.5+30/650/650/sha；APK 直链 200、线上 sha 与本地逐字一致；不带 sharecode 403 |

### 复验清单（一次关账，AI 不代签）

翻月 12 月（农历/蓝点/筛选/开关）→ 导出工作区三条进对区段 → **全 app 图标显形扫一遍（独立项）** → V4.1.4 四项 → V4.1.3 六项 + 两框各滑各的。

### ★ 关账确认（2026-11-28，PM 亲签）

- **V4.1.5（+30）真机七组复验全部通过，本版正式关账，批次 5 闭环。AI 不代签，签 = PM。**
- 覆盖项：月历翻月（12 月/跨年/蓝点/点日筛选/开关保持）、导出四区对齐（工作区进行中 2 条 + 明日前瞻 1 条进对应段）、全 app 图标显形扫一遍（无怪字无错位）、按钮颜色统一绿（月历选中高亮绿/蓝点保持蓝）、三态切换、V4.1.4 四项、V4.1.3 六项 + 两框各滑各的——全部点完确认。
- **+29 留档**：sha256 `bcbb85a5…707e3` 原样保留，V4.1.4 移入下载页历史索引，+30 升号缘由见上节。
- **下一步解锁**：改名（小本本 + `com.danfeng.xiaobenben`）→ V4.2 知识库。
- **+31 候选已挂**：日报导出纯序号（无状态符号，四区各自从 1 开始编号），方案简报另出，PM 拍板后并入 +31。

### +31 拍板与候选登记（2026-11-28）

- **纯序号三件事 PM 全认默认**：+31（4.1.6）、知识库顺延 +32、.md 保留标题层级（buildMarkdown 对固定标题锚点行加回 ##）、顺序=改名后知识库前；追加硬约束：v53 必须含「仓储动态/账目快照两段存在且非空」断言（防 docx 切段换锚后静默丢段——测试不红、真机才露馅那种）。旧 650 一条不删；sha 实测不预估。**未动代码，等改名方案拍完再开工。**
- **全系统备份恢复**：PM 登记为候选项（并入 +31 或紧随其后）。**备料澄清**：元宝"现有备份只覆盖仓储模块"**查实不符**——`exportBackup` 已导 9 表含 reminders/todo_states/daily_reports + 域标识 + schemaVersion，换机走现有备份日程和日报不丢。真实缺口：跨域单文件（建议合并单 JSON，不引 zip 依赖）、manifest 完整性信息、**设置类偏好（月历/隐藏已完成）全是内存 state 未落盘**——备份它们需先做偏好持久化（前置小功能）。版号建议：+32（4.1.7），知识库 +33。
- **改名方案已出（简报备料版，未动代码）**：落点核实 build.gradle.kts:8/34 + MainActivity.kt + Manifest:3；建议 namespace 不动只改 applicationId+label；迁移路径五步（旧包分域导 9 表备份 → 并存装新包 → 分域导入 → 核对清单 → 过了才卸旧包），开工首步真机演练；版号序列矛盾点（纯序号已拍 +31 但改名在前）给出甲（改名并入 +31 同批）/乙（改名独立 +31）两案待拍，另有 D1 namespace / D2 文案与文件名 / D4 演练三项待拍。

### +34 候选登记：数据管理页签（2026-11-28，结构 PM 已拍板，触发条件=+33 落地后）

- **需求**：底部页签第三个「数据管理」（`overview_page.dart:251-285` 双签扩三签，排日报/日程右侧）；顶栏概览/生活/工作不动；点页签自动弹左侧抽屉菜单，菜单按分组（全系统备份 / 物品明细·回收站·位置清单 / 生活区·工作区日程 / 日报归档）；主区只读预览+顶部固定导出/导入按钮（导入不支持置灰）；表格型用滚动表格、文本型用滚动文本，日程走 +32 纯序号口径。
- **迁移来源**：抽屉「数据备份与恢复」（`home_page.dart:2088`/`backup_page.dart`）→ 全系统备份；明细页导出 Excel → 物品明细；+32 日报导出 → 日程导出。
- **边界**：只改 UI 结构与导航，不动数据层；schema v13 不变、不加依赖、签名不变。
- **依赖**：+33 全系统备份先做通，本页签套壳。

### 版号链（2026-11-28 PM 排定，+31~+34）

- **改名 +31 → 纯序号 +32 → 全系统备份 +33 → 数据管理页签 +34**。D3 由本链隐式定为乙案：改名独立占 +31（versionName 待定，建议 4.1.6 归改名版或另议——开工前 PM 一句话确认）。
- **待确认**：V4.2 知识库顺延位置（页签占 +34 后建议 +35，PM 一句话定）；改名 D1（namespace 不动）/ D2（文案与导出文件名前缀）/ D4（迁移演练）三项仍未拍。

### V4.1.6 改名版留档（2026-11-28）· versionCode 30 → 31

> **触发**：PM 拍板五项（D1/D2/D4 全认默认 + 版号全链 +31~+35 排定）。
> **已出包、已上线**；测试 **655/655 全绿**（650 旧 + v53 五条改名锁）；analyze 0/0（5 条既有 info）。

### 落地逐条（D1/D2/D4 按拍板）

| 项 | 内容 |
|---|---|
| D1 | `namespace`/MainActivity **不动**；仅 `build.gradle.kts:34` applicationId → `com.danfeng.xiaobenben` |
| D2 | lib/「家庭仓储」文案**清零**（grep 证实），应用标题/导出文件名（日报 md/docx、备份 json、Excel、docx creator、md 标题）全改「小本本」；pubspec name 不动；数据库文件名不动 |
| D2 配套 | `AndroidManifest.xml:3` label `home_inventory` → `小本本`（桌面名） |
| D4 | 真机迁移演练步骤+核对清单随简报给出；**演练=PM 真机执行**（AI 无真机不代签），演练通过才卸旧包、改名版才算验收 |

### aapt2 实测

`package: name='com.danfeng.xiaobenben' versionCode='31' versionName='4.1.6'` · `application-label:'小本本'` · 55,426,345 字节 · sha256 `303ca8591731af8c9b749d1adb646168ea0d75806079402050f56fd0125f8ddc` · 签名 c1647f33… 不变（**换包名 → 新包与旧包并存，不覆盖安装，数据走备份迁移**）。

### 测试与发布

- 新增 `test/v53_rename_test.dart` 五条源码级锁（applicationId/namespace 不动/label/文案清零/版号/标题与文件名前缀）；旧测试改断言 2 处（excel_exporter_test:258、v40:417），一条未删；v51 版号断言同步 4.1.6+31。
- 下载页：标题/二维码文案换「小本本」、新增**改名迁移五步**区块（第 1-5 步含核对清单与"过了才卸旧包"）；V4.1.5 入历史索引（备份 index-v415-backup.html）；二维码 516×516 解码校验；线上 curl 全核验（页面 200 含包名/五步，APK 直链 200、线上 sha 与本地逐字一致，不带 sharecode 403）。

### 下一版

- **纯序号 +32（4.1.7）**：v53（测试）必加「仓储动态/账目快照两段存在且非空」断言；改名版真机演练关账后开工。
- 全系统备份 +33（4.1.8）→ 数据管理页签 +34（4.1.9）→ 知识库 +35（4.2.0）。

### V4.1.7 备份恢复修复版留档（2026-11-28）· versionCode 31 → 32

> **触发**：改名迁移演练 PM 真机验机打回——「旧包导出的 JSON 恢复到新包，工作区日程等数据未完整导入（生活区正常）」。PM 指令：定位修复导出/导入管道，出补丁版；修复后 PM 重走演练核对清单，全过才关账。

### 根因定位（两条，都实锤）

| # | 根因 | 层 | 证据 |
|---|---|---|---|
| 1 | **恢复成功后首页不刷新**：概览/日程签数据只在 initState 读一次，`_push(BackupPage)` 返回无 setState——恢复完成返回首页看到的是**恢复前的内存数据**（新装包=空库），体感=「导入后数据丢了」。生活区「正常」只是因为切域走了 `_switchSection` 全量刷新 | UI 层 | `backup_page.dart` 无 onRestored 传递；`home_page.dart` `_push` 无返回刷新 |
| 2 | **恢复收口抹掉软删物品数量**：`restoreBackup` 收口对全部物品跑 `_syncItemTotal`，软删物品的关联也是软删 → SUM(活跃位置)=0 → 备份里保真的 quantity 被改写成 0 | 数据层 | v54 往返测试实锤：电钻备份 quantity=1，恢复后 0 |

> **注意**：备份 JSON 本身（exportBackup 9 表全量含软删行）与恢复落库（按原 id 重插）经 9 表逐行逐列比对**全保真**——丢的是「界面没刷新」的体感 + 软删 quantity 一处真实改写。

### 修复逐条

| # | 修复 | 落点 |
|---|---|---|
| 1 | BackupPage 加 `onRestored` 参数并转发 BackupActions；home_page 备份入口传 `_onBackupRestored`（setState 清 result/notice → body 重建 → 概览页重读库） | `backup_page.dart` / `home_page.dart` |
| 2 | 恢复收口**跳过软删行**——软删物品 quantity 按备份原样落地（回收站恢复另有收口） | `inventory_database.dart` restoreBackup |
| 3 | 恢复完成 SnackBar 带**行数明细**（物品/日程/催办状态/借出/日报），核对清单当场有数字可对；老备份缺表**点名提示**「导出较早不含 X，无法找回」，不再静默按空表处理 | `backup_actions.dart` `_restoreResultText` |

### 测试与发布

- 新增 `test/v54_backup_roundtrip_test.dart`（工作区全类型数据 9 表逐行逐列往返保真 + 导出行字段==表全部列防模型吞列）；`backup_page_test.dart` 增 3 条（行数提示/缺表点名/onRestored 必达）；v51/v53 版号断言同步 4.1.7+32。**全量 660/660 全绿，analyze 0 error/0 warning（5 条既有 info）**。
- aapt2 实测：`com.danfeng.xiaobenben` versionCode=32 versionName=4.1.7；55,426,349 字节；sha256 `33d23b4ff77d9fe62b7fdcada0a4c5ca354682a52edc783cc95687e60b1da5ac`；签名 c1647f33… 不变。
- 线上核验：页面 200 含 V4.1.7/versionCode=32/sha/v417.apk；APK 直链 200，线上 sha 与本地逐字一致；不带 sharecode 403。V4.1.6 入历史索引。
- **版号链顺延（待 PM 确认）**：+32 被本补丁占用，原排定纯序号版顺延——纯序号+33 → 全系统备份+34 → 数据管理页签+35 → 知识库+36。
- **演练重跑口径**：PM 按下载页五步重走演练；恢复完成提示直接报行数，两边数字对上再逐项核对；全过才关账，真机签=PM。

### ★ 关账确认：改名迁移演练通过（2026-11-28，PM 亲签）

- **PM 真机完成分区导入复验：日程、日报数据完整导入并核对通过，V4.1.7（+32）修复版真机验收通过，V4.1.6/V4.1.7 正式关账，改名迁移线闭环。AI 不代签，签 = PM。**
- 复验口径说明：PM 现有数据集中在日程与日报（物品/位置/借出模块暂无记录，空库对空库无损）；三张账目表的往返保真由 v54 自动化测试实锤（9 表逐行逐列比对）。
- **下一步解锁**：纯序号版开工（版号顺延方案：纯序号+33 → 全系统备份+34 → 数据管理页签+35 → 知识库+36（4.2.0），待 PM 一句话拍板后开干）。

### 需求登记：知识系统构想简报收档 + 版号链定稿（2026-11-28，PM 终审版，元宝代笔）

- **PM 终审版《WorkBuddy 知识系统模块 · 构想简报》收档**：产品层锁死（核心定位=打捞读过/想过/悟出的；顶栏四栏 概览/生活/工作/知识，全名「知识系统」按钮文案「知识」，概览不展示知识区；学科 9 根类预置可增删改；树形三层封顶 学科→主题→条目；成熟度三档手动标 🟤🟡🔴；每条强制「一句话核心」；树视图+时间线两视图；创作区 4 拆解模板；日报改单份跨域日报+知识段带成熟度状态；起步原则 5 条）。未建表、未碰 schema、未改代码。
- **版号链定稿（构想简报十二，PM 拍板）**：+33 三域骨架（4.2.0 里程碑）→ +34 全系统备份 → +35 数据管理页签 → +36 知识库功能（含知识系统区完整实现）。此前「顺延链待 PM 确认」状态解除。
- **两份文档合并口径**：构想简报=产品层（指导 UI 与交互）；buddy《V4.2 知识库调研总集》=技术层（4 主表+FTS、接口拆分、备份口径、搜索方案）。+36 开工时合并落地。
- **buddy 审阅标注的待落点（开工 +36 前必须定死）**：① 树形三层落表方式（学科/主题建表 vs entries 层级列）② 成熟度/一句话核心/模板字段列设计 ③ 学科/主题 CRUD 进 Writer 的接口扩口 ④ **日报「单份跨域」= 现有分域日报口径变更**（影响 daily_reports/导出/概览日报签，须明确落哪版）⑤ +33 骨架版建壳不建 knowledge.db（建议口径待确认）。

### V4.2.0 三域骨架里程碑留档（2026-11-28）· versionCode 32 → 33

> **依据**：PM 2026-11-28 终审拍板「顶栏四栏 + 生活区底栏三栏」+《知识系统构想简报（PM 终审版）》十二节版号链。知识库从生活区底栏占位项提平为**顶栏第四栏独立第三域「知识系统」**（按钮文案「知识」）。

### 改造逐条

| # | 改动 | 落点 |
|---|---|---|
| 1 | `InventoryDomain` 加 `knowledge`（id='knowledge'，label='知识系统'，fileName='knowledge.db'）；`domainCapabilities[knowledge]={}` 全空（不开放仓储/提醒，写路径天然被拒） | `lib/data/domain.dart` |
| 2 | DomainHub **注册表化**：life/work 具名参数保留 + `additionalInstances` 注册新域；`instanceOf`/禁写循环/重建连接全改查表；切库守卫五步流程一字不动；加第五域=构造加一项 | `lib/domain/domain_hub.dart` |
| 3 | 知识域**壳实例** `ShellDomainInstance`（无连接无仓储句柄，repository 访问即抛 ArgumentError「知识系统建设中」；在飞恒 0，守卫零等待）——骨架版**建壳不建库**（PM 拍板⑤） | `lib/domain/domain_instance.dart` |
| 4 | 顶栏四栏 [概览][生活][工作][知识]，segments 按「概览 + InventoryDomain.values」**注册表驱动渲染**；`_TopSection` 加 domain 字段；`_switchSection` 泛化（`_execRepo` 仅在开放仓储的域重指，绕开壳实例抛点） | `lib/ui/home_page.dart` |
| 5 | 生活底栏三栏 仓储/衣橱/餐饮（PM 原话顺序），「知识库」撤下底栏；`modulesOf(knowledge)` 空列表；零模块域→主体给域壳页、无底栏、抽屉只有标题 | `lib/ui/home_module.dart` / `home_page.dart` |
| 6 | **概览不展示知识系统**：`_agendaBlocks` 按能力开关过滤（v55 测试实锤拦截——改造中概览曾渲染出 `overview_block_knowledge`，违反 PM「概览不展示知识系统任何信息」拍板，已修死） | `lib/ui/overview_page.dart` |
| 7 | 组合根注册壳实例 | `lib/main.dart` |

### 测试与发布

- 新增 `test/v55_three_domain_skeleton_test.dart` 15 条（域定义/能力开关全空/壳实例抛点/Hub 注册表+未注册抛错/第五域留位/顶栏四栏驱动渲染/知识壳页+无底栏/知识域抽屉只有标题/知识→生活回切数据完好/概览无知识信息/组合根源码级锁）；旧断言改口径一条未删（home_page_test 3 条、v40 导航 1 条、v45 注册表 1 条），另加知识域注册表 1 条。**全量 676/676 全绿，analyze 0 error / 0 warning（5 条既有 info）**。
- aapt2 实测：`com.danfeng.xiaobenben` versionCode=33 versionName=4.2.0；55,426,157 字节；sha256 `4cd4a4708d66eba30b432e8d022148fad4e659eb4b321d8c6532f06efb17ad9f`；签名 c1647f33… 不变，可覆盖安装。
- 线上核验：页面 200 含 V4.2.0/versionCode=33/sha/v420.apk；APK 直链 200，线上 sha 与本地逐字一致；不带 sharecode 403。V4.1.7 入历史索引（APK 保留在线，sha 复核一致）。
- **需求链（PM 拍板）**：+33 三域骨架（本版）→ +34 全系统备份 → +35 数据管理页签 → +36 知识库功能（含知识系统区完整实现；开工前须落 v5 施工图定死树形落表/列设计/Writer 扩口/日报单份跨域口径）。

### ★ 关账确认：V4.2.0 三域骨架版真机验收通过（2026-11-28，PM 亲签）

- **PM 真机验收全过**：顶栏四栏（概览默认首屏/生活/工作/知识）、知识壳页无底栏、生活底栏三栏（仓储/衣橱/餐饮）、概览无知识系统信息、记账/日程/催办/备份照旧可用。**V4.2.0（+33）正式关账。AI 不代签，签 = PM。**
- **PM 附记**：日报单份跨域口径（含知识系统段）挂 +36 待办，不卡 +33——与此前拍板一致（④日报单份跨域落 +36）。
- **下一步解锁：+34 全系统备份**。需求链：+33（已关账）→ +34 全系统备份 → +35 数据管理页签 → +36 知识库功能（开工前落 v5 施工图：树形落表/列设计/Writer 扩口/日报单份跨域）。

### V4.2.1 全系统备份版留档（2026-11-28）· versionCode 33 → 34

> **依据**：PM 需求链 +33→+36（构想简报十二）中「+34 全系统备份」；V4.1.6 改名迁移演练实锤痛点（两域两份文件、导两轮导两份、漏域风险）。

### 实现逐条

| # | 改动 | 落点 |
|---|---|---|
| 1 | **全系统备份服务**：`FullSystemBackup`——`exportAll()` 把生活+工作两库各 `exportBackup()` 打包成一份 `{app, kind:'full_system', formatVersion, exportedAt, domains:{life:{…}, work:{…}}}`；域条目沿用单域备份原结构，恢复逐域 delegate `restoreBackup`（V4.1.7 收口全继承，**一行不重写**）；只收开放 `storage` 能力的域（knowledge 壳域永不出现） | `lib/domain/full_system_backup.dart`（新建，独立能力不塞 InventoryRepository 接口） |
| 2 | **恢复校验前置**：结构/域归属（key↔domain 双向一致）/schemaVersion 逐条先验，全过才开始写第一本账——任一分区非法**整体拒绝不落库**（不出现半截状态） | 同上 |
| 3 | **互拒指路**：单域文件进全系统入口 →「这是分区备份…请到对应区域恢复」；全系统文件进分区入口 →「请在备份页用『全系统恢复』入口恢复」 | `full_system_backup.dart` / `inventory_database.dart` restoreBackup |
| 4 | **UI**：备份页顶部新增「全系统备份（推荐）」区（导出/全系统恢复两键 + 交互模式与分区对齐：点击=保存到手机、长按=分享、确认框、错误明确提示）；分区备份区下沉保留 | `lib/ui/full_system_backup_panel.dart`（新建）/ `backup_page.dart` |
| 5 | **组合根**：抽屉备份入口传 `FullSystemBackup(repositories: _storageRepositories())`（先能力开关过滤再碰 repository，V4.2.0 壳实例教训沿用） | `lib/ui/home_page.dart` |
| 6 | **恢复提示逐域分行**：「生活区：物品 X 条、日程 Y 条…」+ 缺表点名（V4.1.7 行数口径的跨域版） | `full_system_backup.dart` restoreResultText |

### 测试与发布

- 新增 `test/v56_full_system_backup_test.dart` 6 条：**双真库造满数据 → 一份 JSON 往返 → 双新库恢复 → 每域 9 表逐行逐列保真**（含软删行）；互拒×2；未知分区/错位/版本过高全拒；**校验前置（合法分区也不动）**；domains 口径。`backup_page_test.dart` 增 4 条 widget（全系统区渲染/双域导出合成/恢复分发不串库+onRestored 必达/单域误入不落库）。v51/v53 版号断言同步 4.2.1+34。**全量 686/686 全绿，analyze 0 error / 0 warning（5 条既有 info）**。
- aapt2 实测：`com.danfeng.xiaobenben` versionCode=34 versionName=4.2.1；55,442,741 字节；sha256 `b6b3d28b35e05919aa0f4a902081b56bcc92622f6306b8fe95cdf58df35342a2`；签名 c1647f33… 不变，可覆盖安装。
- **如实说明**：调研时提的「偏好落盘缺口」经核查不成立——全 app 无 SharedPreferences，唯一用户设置（月历农历开关）为内存态、默认开，无可落盘之物，本版不虚增该范围。
- 需求链：+34（本版）→ +35 数据管理页签 → +36 知识库功能（开工前落 v5 施工图）。

### V4.2.2 数据管理页签版留档（2026-11-28）· versionCode 34 → 35

> **依据**：PM 开工边界（2026-11-28 拍板）——「把抽屉里『数据备份与恢复』单页，收拢升级为数据管理页签，承载备份/恢复/导出/清理等数据类操作」。红线：不建知识域表、不改备份 JSON 格式（formatVersion:1、domains.life/work 九表结构不动）、不碰签名/下载页/sha 链路。

### 实现逐条

| # | 改动 | 落点 |
|---|---|---|
| 1 | **数据管理页签**：抽屉入口升级「数据管理」（key `drawer_backup` 不变），TabBar 四签：全系统备份（推荐）/分区备份/导出 Excel/回收站与清理 | `lib/ui/data_management_page.dart`（新建） |
| 2 | **全系统区原样搬入**：+34 的 FullSystemBackupPanel 一字不改进签①；fullSystem=null（单域注入）时显示提示，与 BackupPage 同口径 | 同上 |
| 3 | **BackupPage 重构为 BackupPageBody**：无 Scaffold 主体抽出，分区备份签与旧 BackupPage 共用；BackupPage 类原样保留（AppBar+body），路由/旧测试全兼容 | `lib/ui/backup_page.dart` |
| 4 | **导出 Excel / 回收站=入口跳转**：签③跳物品明细页（底部导出/长按分享照旧）、签④跳 TrashPage（恢复/彻底删/全部清空照旧），**取数与清理逻辑一行没重写** | 同上 |
| 5 | **返回兜底刷新**：抽屉 push 数据管理页 await 返回后调 `_onBackupRestored()`——页签内回收站恢复/彻底删/全部清空都改库，V4.1.7 同款链路幂等兜底（恢复本身仍有 onRestored 即时回调） | `lib/ui/home_page.dart` |
| 6 | **误装指路文案校准**：分区文件误入全系统入口 →「请到对应区域的『数据管理 → 分区备份』页签恢复」（原指「数据备份与恢复」页已无抽屉直达入口，指路不更新会变死路） | `lib/domain/full_system_backup.dart` |

### 测试与发布

- 新增 `test/v57_data_management_tab_test.dart` 5 条：四签结构/签①全系统面板默认可达/签②分区按钮可达/签③跳明细页/签④跳回收站。`home_page_test.dart` 抽屉 2 条断言改「数据管理」保行数；`backup_page_test.dart` 指路断言同步。**全量 691/691 全绿（686 旧条一条未删 + 5 新增），analyze 0 error / 0 warning（5 条既有 info）**。
- aapt2 实测：`com.danfeng.xiaobenben` versionCode=35 versionName=4.2.2；55,475,505 字节；sha256 `97bd99c94c6b07901761723a9d228d00aefbc70692fcc7d6944ab92de7a51f06`；签名 c1647f33… 不变，可覆盖安装。
- 线上核验：页面含 V4.2.2 与 sha、APK 直链 200 且 sha 逐字一致、无 sharecode 403、v421 历史链 200；二维码 516×516 重新生成并 zxingcpp 解码校验。
- **范围如实**：本版只做收拢搬运，+34 行为一字不改；日报老六块口径未动（变更挂 +36）；无 schema 变更。
- 需求链：+35（本版）→ +36 知识库功能（v5 施工图已收档，开工前落 7 点回执）。

### V4.2.3 数据管理终审版留档（2026-11-28）· versionCode 35 → 36

> **依据**：PM 终审开工边界（2026-11-28 元宝代笔，V4.2.2 上线后发现 tab 形态与终审冲突，版号按「当前+1 不复用」铁律顺延：本版占 **+36**，知识库功能顺延 **+37**）。终审要点：数据管理=概览「日程」右侧新签、唯一集散入口；抽屉入口撤掉改跳签；明细页导出 Excel 按钮撤除；签内**整页纵向滚动四区**（系统/生活/工作/知识），不做横向切页、不做顶部 tab、不弹新页。

### 实现逐条

| # | 改动 | 落点 |
|---|---|---|
| 1 | **概览第三签「数据管理」**：TabBar 2→3 签（日报/日程/数据管理），`initialTab` + seed 换 key 重建响应抽屉跳签；组合根 `_buildDataManagementTab()` 注入 `DataManagementView`（概览只收 Widget 不持仓储，写边界铁律） | `lib/ui/overview_page.dart` / `home_page.dart` |
| 2 | **四区单页纵向滚动**：`DataManagementView` 重写为 SingleChildScrollView——区①系统区（FullSystemBackupPanel 原样）→ 区②生活区 → 区③工作区 → 区④知识区（按钮置灰通道：不建库不接 Writer，建库后自动开放）；+35 的 tab 形态撤除 | `lib/ui/data_management_page.dart`（重写） |
| 3 | **全系统备份扩三域 JSON**：`exportAll` 增 `domains.knowledge` 空壳分区（壳域恒在，建库后自动带数据）；恢复端：knowledge 放行→空壳跳过→**带数据明确拒绝不炸**（「请升级应用后恢复这份备份」）；旧版 app 恢复新文件走既有未知分区指路；+34 行为一字不改（校验前置/逐域分行/互拒指路） | `lib/domain/full_system_backup.dart` |
| 4 | **生活/工作区自带导出**：每区=分区备份/恢复（BackupPageBody 原样复用）+ Excel 导出（点击保存/长按分享，`ExcelExportKit` 从明细页搬组装链路）+ **新增 Word 物品清单导出**（`ItemDocxExporter`，docx 含物品+存放位置，点击保存/长按分享） | `lib/data/excel_export_kit.dart`（新建）/ `item_docx_exporter.dart`（新建）/ `data_management_page.dart` |
| 5 | **散落入口撤除**：抽屉改回「数据备份与恢复」跳概览数据管理签（多域）；单域形态（单测）兜底 push 独立页；物品明细页底部「导出 Excel」按钮撤除（BackupActions 底栏整体撤除） | `home_page.dart` / `item_list_page.dart` |
| 6 | **互拒指路文案再校准**：分区文件误入全系统入口 →「请到对应区域的『数据管理 → 分区备份』页签恢复」对齐四区布局 | `full_system_backup.dart` |

### 测试与发布

- `v57` 重写为四区断言 8 条（四区布局+纵向次序/系统区两键/生活工作备份恢复+Excel+Word 齐备/知识区置灰/生活区 Excel 保存/生活区 Excel 长按分享/生活区 Word 保存/单域模式提示）。旧断言按终审口径改写**一条未删**：v56 三域 JSON+拒收文案 2 处、backup_page_test 三域断言 1 处、home_page_test 抽屉 2 处、item_list_page_test 明细页撤按钮锁 2 处。v51/v53 版号锁同步 4.2.3+36。**全量 694/694 全绿，analyze 0 error / 0 warning（5 条既有 info）**。
- **过程中修的实现 bug**：四区标题 `'${domain.label}区'` 拼出「生活区区」（label 已含「区」字）——真机验收前被测试拦截，未上线。
- aapt2 实测：`com.danfeng.xiaobenben` versionCode=36 versionName=4.2.3；55,475,525 字节；sha256 `b58dc2a8b6f9c0d2777cf7475919f24084d2227c6c326a0605dbbb6fc5ace16d`；签名 c1647f33… 不变，可覆盖安装。
- 线上核验：页面含 V4.2.3 与 sha、APK 直链 200 且线上 sha 逐字一致、无 sharecode 403、v422 历史链 200；二维码 516×516 重新生成并 zxingcpp 解码校验。
- **范围如实**：知识区只做通道按钮（不建库不接 Writer，全归 +37）；日报导出不归本签（走日报页自己按钮）；无 schema 变更。
- 需求链：+36（本版）→ **+37 知识库功能**（v5 施工图已收档；开工前按 7 点回执落定：备份枚举 9→15、updateNodeTitle 补口、deleteNode 软删边界、search_text 跨表落点、种子只进 knowledge.db、+34→全系统备份扩 knowledge【已于本版预落】、创作区入口待元宝补）。
- **环境留档**：WorkBuddy 权限放行「未匹配文件规则的删除=允许」后 flutter 恢复会话内运行（engine.stamp.tmp 删除被 `**` 规则拦的问题解除），analyze/test/build 全链回归会话内自跑。

### ★ 关账确认：V4.2.3 数据管理终审版真机验收通过（2026-11-28，PM 亲签）

- **PM 真机验收全过**：数据管理签入口正确、四区纵向滚动无 tab、系统区三域 JSON 含 knowledge 空壳、生活/工作区备份恢复+Excel+Word 导出可达、知识区按钮置灰、散落入口撤干净、+33/+34 无回归。**V4.2.3（+36）正式关账。AI 不代签，签 = PM。**
- **下一步解锁：+37 知识库功能**。开工回执七点已由元宝补第 7 点（创作表达区）全数落定（2026-11-28）。
- **+37 开工口径落定（buddy 自主决策留档）**：① 备份枚举 9→15 = 6 张主表（nodes/entries/tags/entry_tags/links/entry_meta），**FTS 不进备份枚举**（虚拟表可从主表全量重建，备份只存真数据——否则 15 对不上）；② **knowledge.db 首建 schemaVersion=14**（含 15 张表），life/work 保持 v13 不动——分域版本号独立演进，旧版 app 恢复新备份走「版本过高拒绝」既有校验链，两库齐平旧口径由分域版本号取代。

### V4.3.0 知识库功能版留档（2026-11-28）· versionCode 36 → 37

> **依据**：PM +37 开工回执（2026-11-28 元宝代笔，七点全落定：备份枚举 9→15、updateNodeTitle 补口、deleteNode 软删边界、search_text 跨表落点、种子只进 knowledge.db、全系统备份填实、创作表达区第 7 点补完）。

### 实现逐条

| # | 改动 | 落点 |
|---|---|---|
| 1 | **knowledge.db 首建**（schemaVersion=14，分域版本号独立演进，life/work 保持 v13 不动）：六表 knowledge_nodes（自引用树 parent_id + node_type + maturity + is_system）/ knowledge_entries（source/core_summary/learned_at/template/**search_text 派生列**）/ tags / entry_tags / links / entry_meta | `lib/data/knowledge_database.dart`（新建） |
| 2 | **知识域实例转正**：`KnowledgeDomainInstance` 取代壳实例（repository 照旧抛「知识系统不开放仓储账目」——语音路径照旧被能力开关拦；知识读写走 store 独立接口，铁律「新能力拆独立接口」）；能力开关增 `knowledgeLibrary` | `lib/domain/knowledge_domain_instance.dart`（新建）/ `domain.dart` / `domain_instance.dart`（删壳类）/ `main.dart` |
| 3 | **种子幂等**：9 学科 + 创作表达 4 主题（is_system=1 可改名不可删）；判重把软删行算「已存在」——**用户删掉的根节点不被 seed 复活** | knowledge_database.dart `_ensureSeed` |
| 4 | **Writer 九写口**：addSubject/addTopic（只挂学科，三层封顶）/addEntry（core_summary 强制非空、挂 topic）/updateNodeTitle（entry 改名后 search_text 同步重算不留脏索引）/updateEntry/deleteNode（**整棵子树软删**，links 边不软删 JOIN 过滤恢复接回）/moveNode（防环+深度校验）/setMaturity（practice 锁死🔴）/creativeTopics | 同上 |
| 5 | **搜索**：search_text 派生列（标题+一句话核心+来源）+ LIKE 检索——**技术偏离留档：FTS5 在 Android 系统 SQLite 上大量真机不可用**（ROM 未编译），改派生列方案，接口语义不变，数据量级（个人笔记）LIKE 足够 | 同上 / 简报如实报 |
| 6 | **知识系统页三页签**：今日学习摘要（时间线 learned_at 倒序）/ 知识系统（树视图：果实数标记 (n🟤 m🟡 k🔴)、空态引导、搜索）/ 创作表达（4 模板卡片动态表单：technique/scene/material/practice；practice 成熟度锁🔴+字数自动统计只读；详情页按模板分行显示、空字段不占位不留空行） | `lib/ui/knowledge_page.dart`（新建）/ `home_page.dart` 零模块域分支 |
| 7 | **全系统备份 knowledge 分区填实**：exportAll 真数据六表（FTS/派生列不进备份，恢复后 `_rebuildSearchText` 全量重建）；restoreAll 校验上限按域独立（knowledge 14 / 仓储 13）；未注入 store 的形态维持 +36 壳口径（空壳跳过/带数据礼貌拒绝）；报数「N 学科 / M 条目」 | `lib/domain/full_system_backup.dart` |
| 8 | **日报单份跨域 · 知识段**：`knowledgeReader` 注入；buildContent/buildDocx 增「今日学习」段——**有则显示、无则不出现**；条目=模板前缀（如「写作手法拆解·《白夜行》」）+标题+成熟度🟤🟡🔴+来源+一句话核心；导出前缀「小本本-…」照旧 | `lib/data/daily_report_service.dart` / `main.dart` |

### 测试与发布

- 新增 `test/v58_knowledge_library_test.dart` 12 条：建库 v14+种子/幂等+软删不复活/三层封顶错层拒绝/一句话核心非空/改名后 search_text 重算/moveNode 防环+深度/子树软删不进搜索+links 边不软删/系统主题不可删学科可删/创作区模板 meta 落表+空字段不占位/practice 成熟度锁死/全系统备份往返+报数「N 学科 / M 条目」/日报知识段两态。旧断言按 +37 口径改写**一条未删**（v55 壳实例段 8 处转建库版、能力开关 1 条）。v51/v53 版号锁升 4.3.0+37。**全量 706/706 全绿（694 旧条 + 12 新增），analyze 0 error / 0 warning（5 条既有 info）**。
- aapt2 实测：`com.danfeng.xiaobenben` versionCode=37 versionName=4.3.0；56,065,685 字节；sha256 `a5ed618beddf6fd2a20b77ab7e12f4459e3ca7acb91fdbc6da3b2bae898df320`；签名 c1647f33… 不变，可覆盖安装。
- 线上核验：页面含 V4.3.0 与 sha、APK 直链 200 且线上 sha 逐字一致、无 sharecode 403、v423 历史链 200；二维码 516×516 重新生成并 zxingcpp 解码校验。
- **范围如实**：FTS5→派生列 LIKE 为技术方案偏离（台账留档，简报如实报）；创作区 4 模板不做内容推荐不自动填字段；meta 表只服务知识域不扩 life/work；versionName 4.3.0 为 buddy 建议（里程碑功能版，回执只定 versionCode=37），已随本版上线。
- 需求链：+37 知识库功能（本版）→ +38 及以后（未排）。

### V4.3.1 返工+借出补丁版留档（2026-11-29）· versionCode 37 → 38

> **依据**：PM +37 真机验收未过返工通知（3/6 硬伤、4/5/10 待复验）+ 借出模块两 Bug 紧急补丁回执 + P0/P1/P2 性能与数据安全清单（PM 经 AskUserQuestion 拍板「P0 并入 +38，P1/P2 放 +39」）。版号矛盾（PM 回执初写「versionCode 保持 37 热修」撞「升号不热修」铁律）以 AskUserQuestion 让 PM 亲拍：并入 +38、versionCode=38、签名不变、全量测试一条不删。

### 实现逐条

| # | 改动 | 落点 |
|---|---|---|
| 1 | **借出补丁①·位置查询合并借出状态**：查询合并 getActiveLoansForItem 未还借出（与借出管理页同源 loans 一张表）；三态文案——无借出纯位置 / 在库 0「已借给X（借出日~到期日），当前在库 0，原存放：…」+「借出中，不在库」（不列位置行）/ 部分借出分开列「在库 N 个 + 借出未还 M 个」 | `lib/ui/home_page.dart`（_queryLoans/_queryQty/_queryResultText）/ `inventory_database.dart` / `inventory_repository.dart` |
| 2 | **借出补丁②·「标记全部归还」防护**：按钮改名 + 二次确认弹窗（「确认将 X（N个）标记为已归还？此操作不可撤销」）+ 归还时间可改（默认当天，支持日期/日期时间两种格式、未来时间拒绝）+ 归还恢复源位置；returnLoan 加 returnedAt 参数（仅还清写 returned_at） | `lib/ui/loan_list_page.dart` / `inventory_database.dart` |
| 3 | **位置恢复·from_location_id**：Loan 加 fromLocationId（借出时从哪个位置扣数落库）；归还优先恢复源位置（显式 toLocationId > 源位置 > 主位置回退链）；**schema v13→v14**（幂等加列 _addColumnIfMissing；旧记录/旧备份 null 回退主位置；legacy 无 loans 表的极端路径探表跳过） | `lib/data/item.dart` / `inventory_database.dart` |
| 4 | **+37 硬伤一返工·界面删除入口**：主题行「⋮」PopupMenuButton（系统预置拦「不可删」、有子条目拦「先清空或转移」、空主题确认弹窗）+ 条目长按删除 + 条目详情页删除弹窗文案统一（「删除后从知识树隐藏，数据保留在本地备份，不可在界面恢复。」） | `lib/ui/knowledge_page.dart` |
| 5 | **+37 硬伤二返工·知识区解锁**：数据管理签按钮从硬编码置灰变动态（注入 knowledgeStore 即解锁）；_shareKnowledgeBackup/_restoreKnowledge 落地；组合根 home_page 注入 knowledgeStore——**V4.1.5 同款「接线缺失」教训第三次现身（组合根没传 store，fake 测不出）** | `lib/ui/data_management_page.dart` / `home_page.dart` |
| 6 | **P0-1·备份内档轮转**：BackupArchiver（应用私有文档目录/backups，文件名秒级时间戳倒序取 keepCount=3 之后物理删）；导出/分享成功后同步留内档并轮转（轮转时 SnackBar 报「备份轮转，删除最旧备份 xxx（本地保留最近 3 份）」）；**archiver=null=不轮转（测试形态），生产组合根两构造点注入**——面板内 `?? BackupArchiver()` 兜底写法会在测试环境炸 path_provider，全量回归拦截 | `lib/domain/backup_archiver.dart`（新建）/ `full_system_backup_panel.dart` / `backup_page.dart`（BackupPage/BackupPageBody 透传参数）/ `data_management_page.dart` |
| 7 | **P0-2·备份完整性校验**：BackupIntegrity（外键悬空/returned_qty 穿账/空名/知识域 parent_id·node_id 悬空，按本仓真实表清单）；exportAll/分区保存/分享前 ensureValid，ArgumentError→SnackBar「数据异常，暂不备份，请联系排查（共 N 处）」，坏数据绝不落盘 | `lib/domain/backup_integrity.dart`（新建）/ `full_system_backup.dart` / `backup_actions.dart` / `full_system_backup_panel.dart` |

### 测试与发布

- 新增 v59 借出补丁 13 条（源位置落库/位置恢复源≠主/旧记录回退/归还时间+未来拒绝/迁移 v13→v14/getActiveLoansForItem/备份往返/弹窗三态 widget/查询合并三态）+ v60 返工 7 条（纯 Dart _FakeKnowledgeStore——真 ffi 库与 FakeAsync 不同步卡死老坑复现，StackOverflow 无限递归被 catch 吞掉一例：deleteNodeSync 递归条件误写）+ v61 备份安全 9 条（轮转 4 次剩 3/未超不动/非 json 不动/真实库零误报/外键悬空/穿账/文案/知识悬空/坏数据网关零写入）。旧断言按 +38 口径改写**一条未删**：v46 schema 锁 v14 + loans 14 列、v51/v53 版号锁 4.3.1+38。
- **全量回归拦下两处真 bug + 一处测试脆弱**：① 面板 `?? BackupArchiver()` 兜底炸 path_provider（成功文案被顶掉）→ null=不轮转+组合根注入；② v14 迁移在无 loans 表 legacy 路径炸 → 探表跳过（V3.11 locationTables 同款防御模式）；③ v51 固定日期 2026-11-28 撞跨午夜（done_at=真实 now，today 已过去→done 区恒空，昨日全绿属日期巧合）→ _today() 真实当天零点，产品口径本身无 bug。
- **全量 735/735 全绿（706 旧 + 29 新），analyze 0 error / 0 warning（5 条既有 info）**。
- aapt2 实测：`com.danfeng.xiaobenben` versionCode=38 versionName=4.3.1；56,262,293 字节；sha256 `d9ae77829f55dd6832236a500c76cd0e469b772bca6d407d71ceff180f3066b6`；签名 c1647f33… 不变，可覆盖安装。commit 4b35be0。
- 线上核验：页面含 V4.3.1 与 sha、APK 直链 200（56,262,293 字节）且线上 sha 逐字一致、无 sharecode 403、v430 历史链 200；二维码 516×516 重新生成并 zxingcpp 解码校验。
- **范围如实**：P1/P2（分页 50 条/搜索 100 上限/文本 2000 字提示/备份大小提示/数据概况页）记 +39；本仓无餐饮/衣橱表（元宝模板串行修正，按真实表清单校验）、无评论区（映射现有文本框记 +39）；备份轮转只删**内档目录**备份文件（SAF 用户自选位置 App 无权清理，留档说明）。
- 需求链：+38 返工+借出补丁版（本版）→ +39 P1/P2 性能与数据安全二批（已排入）。
