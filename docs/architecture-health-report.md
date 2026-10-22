# auto_cdn 结构体检报告

> **基线**：分支 `fix/no-video-fast-probe` @ `2ecb91f1d`（2026-10-15）。
> 本报告是**只读勘察**产物，没有改动任何代码。文中所有行号以该提交为准；
> 代码继续前进后会漂移，复查时优先按**符号名**检索，行号只作起点。

> **状态更新（2026-10-21）**：下面是 `2ecb91f1d` 的快照。之后 Tier A/C 已经落地
> 一批，以下条目**已经改掉**，照报告动手前先按符号名核对现状：
>
> | 报告条目 | 现状 |
> |---|---|
> | §2.1 两处匿名 `Timer(3s)` | 已收进 `_errorReloadTimer` 字段，赋值前与 `dispose()` 里都 `cancel()`（`f11e18d6a`） |
> | §2.2 `volumeTimer` 未随 `dispose()` 取消 | 已补 `volumeTimer?.cancel()`（`f11e18d6a`） |
> | §3.2 「必须同时改两个字段」的点 | 17 个状态字段已收进 `_CdnSwitchState`，成组写入收成 `beginRound` / `noteSuccess` 等语义方法（`5f03d6519`） |
> | §3.2 疑似问题 1：`_cdnIsAttached` 只比 `onStall` | 改为 owner token：`cdnSwitchCallbacksOwnedBy(_cdnClaimToken)`，5 个回调原子挂载/撤下（`5f03d6519`） |
> | §9 附录「两处重复的账本清零」 | 已合为 `_clearDecodeAccounting()`（`8fcaa00f5`） |
> | §4 分层无护栏 | 已加 `tool/arch_check.dart` ratchet（SCC 内部边数 + 底层→pages 条数，`2f8eba268`） |
> | §4「DI 应发生在单例内部」的实践缺口 | `DownloadManager` 的 `Dio` 已改构造函数注入（`6594e9c0e`） |
> | §5、§6 的全部计数 | 已漂移，以 **`8c4619916` 实测**为准：测试 **12 个文件 / 198 个 `test(` / 25 个 group**、`@visibleForTesting` **37 个**；`_kCdn*` 常量已搬进 `CdnTuning`（`lib/pages/video/cdn_tuning.dart`，25 个），播放器侧在 `PlayerTuning`（29 个），源码里 **0 个 `_kCdn*`** |
>
> **仍然成立**：两个 god object 都**没拆**（Tier B 推迟），§3.2 的
> `_pickFastestCdn` 470 行、`_cdnAttachedOnce` 不重置、`_cdnAutoAttempts` 双计数
> 都维持原判；§1 的体量数字只会更大。全文行号仍按 `2ecb91f1d`。

---

## 0. 一句话结论

结构上最贵的是**两个 god object**：

- `lib/plugin/pl_player/controller.dart` —— 3,170 行，一个类扛 11~12 个可独立职责；
- `lib/pages/video/cdn_switch_mixin.dart` —— 1,881 行，31 个方法、17 个状态字段，
  其中 `_pickFastestCdn` 单方法 470 行。

**分层问题（巨型循环依赖）看着吓人，但对这个项目的实际伤害被高估了。**
它不阻塞测试，也不阻塞改动；而上面两个 god object 两者都阻塞 ——
136 个用例里大半是为了绕开它们才存在的。

所以如果要排期，顺序应该是「先拆 god object，再谈分层」，不是反过来。

---

## 1. 体量与口径

| 项 | 数量 |
|---|---|
| `lib/` 下 `.dart` 文件 | 1,335 |
| `lib/` 总行数 | 449,821 |
| `lib/grpc/` 生成代码 | 248,648 行（**55.3%**） |
| `lib/common/widgets/flutter/` Flutter 框架副本 | 29,629 行 / 20 文件（另有 39 个 patch） |
| **手工代码（扣除以上两项）** | **约 171,500 行** |
| 测试 | 8 个文件、136 个 `test(`、18 个 `group(` |

后面所有结论都以**手工代码**为对象。生成代码与框架副本不参与评价 ——
它们是资产而不是负债，除了升级成本不透明这一点（见 §8）。

---

## 2. P0 — 正确性风险

### 2.1 两处匿名 `Timer(3s)`：创建 2 次，取消 0 次

`lib/plugin/pl_player/controller.dart`

- `:1588` 直播分支：`stream.error` 命中 `tcp: ffurl_read returned …` /
  `Failed to open https://` 时起一个 `Timer(Duration(milliseconds: 3000), …)`；
- `:1622` 点播分支：`EasyThrottle` 节流后再起一个同款 `Timer(3s)`。

两处都**没有把 Timer 存进任何字段**，因此 `dispose()`（`:2942` 起）和
`_removeListeners()`（`:2422`）都碰不到它们。回调闭包持有 `this`，3 秒后调
`refreshPlayer()`。

`dispose()` 里实际取消的定时器只有：`cancelLongPressTimer()`、`_cancelSubForSeek()`、
`_timer`、`_removeListeners()`、`_stopWakeLockTimer()` —— 不含这两处匿名 Timer。

**后果**：页面销毁/播放器卸载后的 3 秒窗口内，计时器仍会醒来并调用
`refreshPlayer()`。`_playerCount == 0` 的守卫能挡住大部分伤害，但这属于
「靠下游兜底」而不是「源头收口」。

**修法**：两个分支共用一个 `Timer? _errorReloadTimer` 字段，赋值前先 `cancel()`，
`dispose()` 里再 `cancel()` 一次。直播与点播的 `isLive` 在同一媒体内不变，共用安全。

### 2.2 `volumeTimer` 没有随 `dispose()` 取消

- 声明与赋值：`controller.dart:2554`、`:2576-2577`（`setVolume()` 里，200ms 后写 setting）；
- 另一个赋值点：`lib/plugin/pl_player/view/view.dart:183-184`（widget 侧 cascade 赋值）；
- `dispose()` 里**没有** `volumeTimer?.cancel()`。

对比同类字段：`longPressTimer` 有 `cancelLongPressTimer()` 并在 `dispose()` 里调用，
`_wakeLockTimer` 有 `_stopWakeLockTimer()` 并在 `dispose()` 里调用。`volumeTimer` 是
唯一漏网的 —— 属于遗漏，不是设计。

### 2.3 三条「死代码」结论是假的 —— 请勿照着删

勘察过程中出现过三个看起来很像死代码、实际不是的结论。它们流传性很强，
这里明确否掉，避免将来有人「顺手清理」：

| 被误判的项 | 实际状态 | 证据 |
|---|---|---|
| `BlockConfigMixin` 的 8 个字段「在控制器内部零引用」 | **不是死代码**。控制器通过 getter 转发给页面，页面和 SponsorBlock 逻辑都在用 | `lib/pages/video/controller.dart:556` `BlockConfigMixin get blockConfig => plPlayerController;`；使用点 `:1338`、`lib/pages/sponsor_block/block_mixin.dart:60/131/138/189` |
| `longPressTimer`「从未被赋值」 | **不是死字段**。由 widget 侧赋值 | `lib/pages/video/widgets/player_focus.dart:78`（`Timer.periodic`）、`:127`（一次性 `Timer`） |
| `_cdnAutoAttempts`「只用于日志，可删」 | **不可删**。它正是被手测文档逐字引用的日志值 | `lib/pages/video/cdn_switch_mixin.dart:1125-1127` → `CDN 自动切换: 第N次 -> …` |

这三条之所以会误判，是因为控制器内部确实不引用它们 —— **引用方都在外部**。
这也是 god object 的典型副作用：读单个文件读不出真实使用面。

---

## 3. P1 — 结构热点

### 3.1 `PlPlayerController`：3,170 行，11~12 个职责

`lib/plugin/pl_player/controller.dart`，类声明在 `:76`。

| # | 职责 | 大致行号 | 约行数 |
|---|---|---|---|
| 1 | 播放控制（seek/play/pause/倍速/音量/画面适配/全屏/锁屏/手势） | 137-140、2436-2804、2907-2939 | ~400 |
| 2 | 数据源装载 / Player 构造 / 重开会话 / 解码器重建 | 1031-1401 | ~350 |
| 3 | 渲染上下文与会话生命周期（8 条流订阅、认领名册、dispose） | 1403-1428、1461-1711、2942-3013 | ~460 |
| 4 | 无视频轨判据（时间窗 + 强/弱指纹） | 1662-1919、2176-2178 | ~300 |
| 5 | 解码错误采样（坏字节族 + 会话失效族） | 299-395、489-532、2012-2138 | ~300 |
| 6 | 缓冲与卡顿看门狗（冻结/饥饿/遥测失真） | 224-297、397-487、2140-2418 | ~420 |
| 7 | 诊断心跳日志 | 422-424、487、2156-2175 | ~25 |
| 8 | 历史记录心跳上报 | 183、1500-1531、2853-2905 | ~60 |
| 9 | Pref 配置镜像（61 个 `late final`） | 543-870、927-1008 | ~500 |
| 10 | 桌面/移动画中画 | 548-741、2965-2969 | ~190 |
| 11 | 截图与进度预览 | 3025-3136 | ~110 |
| 12 | 单例与引用计数 | 80、872-925、1017-1022、2942-3013 | ~100 |

**状态面**：85 个可重新赋值的实例字段（其中 38 个私有）+ 41 个可变 Rx/集合
（其中 10 个私有）⇒ 私有可变状态载体 48 个，全部可变状态载体 126 个。

最典型的字段簇（这些簇内部高度内聚，是拆分的天然切口）：

- **簇 A 无视频轨 + 重建额度**（7 个）：`_noVideoWindowStart`、`_noVideoLastPosition`、
  `_noVideoRebuilds`、`_rebuildingRenderContext`、`_ownReload`、`_playerTeardown`、`renderContextGen`；
- **簇 B 看门狗**（9 个，`472-487`）：`_stallTicker`、`_stallLastSecond`、`_stallFrozen`、
  `_rebufferEvents`、`_rebufferSuppressUntil`、`_wasStalled`、`_wasEmpty`、`_starveSeconds`、
  `_starveLastReportAt`；
- **簇 C 解码账本**（6 个，`489-532`）；
- **簇 D 页面认领/引用计数**（6 个）；
- **簇 E 媒体身份**（9 个，`176-185`）。

**可拆出的最大一块**：职责 4+5+6+7（无视频轨判据 + 解码两族 + 缓冲看门狗 + 心跳）
合计约 **1,100~1,200 行**，共享的只有 `position/buffered/isBuffering/playerStatus`
四个只读输入，彼此通过回调和「动作出口」交互 —— 内聚度高、边界清楚。

### 3.2 `CdnSwitchMixin`：1,881 行，状态机只存在于调用顺序里

`lib/pages/video/cdn_switch_mixin.dart`

- 24 个 `static const`（`204-324`）、17 个 `_cdn*` 状态字段、31 个具体方法；
- `_pickFastestCdn`（`1220-1685`）**单方法 470 行**，内含 5 个局部闭包
  （`sample`/`guarded`/`describe`/`unmeasurable`/`usable`）；
- `_autoSwitchLoop`（`1056-1208`）153 行。

**核心问题：没有状态模型。** 没有 enum、没有状态对象、没有集中 invariant，
合法性完全靠**调用顺序**维持。典型证据是下面这些「必须同时改两个字段」的点：

| 位置 | 同时改的东西 |
|---|---|
| `:589-590` | `_cdnGeneration++` 与 `_cdnAutoBusy = false` |
| `:628-638` | `_cdnGeneration++`，再条件性清 busy/attempts（其余字段保留） |
| `:757-759` | `_cdnAutoBusy = true` 与 `_cdnAutoServiceSnapshot` 必须同拍，再捕获 generation |
| `:863-864` | `attachCdnSwitch` 里同样成对改 generation + busy |
| `:996`、`:1016-1023` | `_cdnPreflightPending`、`_cdnPreflightSince`、定时器三件事 |
| `:1125-1126` | `_cdnAutoAttempts` 与 `_cdnLastAttemptPos` |
| `:1144-1147` | 成功时同时清 attempts / lastAttemptPos / triedAt / giveUpUntil |
| `:1314-1333` | `_cdnObjectSize` 只在 `_roundVoided` 复查后写 |
| `:1437-1439`、`:1473-1479` | `_cdnTriedAt` 与 `_cdnNoSample` 的配对写入 |

另外三处疑似 bug/隐患（本次未验证为线上问题，仅记录）：

1. `_cdnIsAttached`（`:826`）判断「我是不是现役页」时**只比较 `onStall` 一个回调**，
   而挂载时实际设了 5 个（`:871-877`）。另外 4 个被别的页面覆盖时它仍会认为是自己。
2. `_cdnAttachedOnce`（`:417`）置真后**从不重置**。看起来是有意的（避免每次回页
   重新武装预检、白花测速流量），但没有注释说明，容易被误当缺陷「修掉」。
3. `_cdnAutoAttempts` 不参与任何闸门，真正的尝试次数是 `_autoSwitchLoop` 里的局部变量
   `attempt`。两套计数并存，但前者是日志接口，不能删（见 §2.3）。

---

## 4. P2 — 分层与耦合

### 4.1 循环依赖：不是 404 个小环，是**一个巨型环**

按 import/export 边对 `lib/` 建图（排除 `grpc/`、`common/widgets/flutter/`、
`*.g.dart`、`*.freezed.dart`），用 Tarjan 求强连通分量：

| 指标 | 数值 |
|---|---|
| 节点 / 边 | 1,202 / 6,039 |
| 强连通分量（size > 1） | **5** |
| **最大分量规模** | **538 个文件（占 44.8%）** |
| 分量内部边 | 2,413 |

结论：近一半的代码文件处在**同一个强连通分量**里。这意味着「改底层会不会牵动页面层」
这个问题没有意义 —— 它们本来就在一个环里。真正该记的指标是**分量内部边数**（2,413），
它是唯一能单调下降的度量。

### 4.2 底层反向依赖页面层

`utils/`、`models/`、`models_new/`、`common/`、`services/`、`http/` 中，
有 **27 个文件、74 条 import** 指向 `lib/pages/`。典型：

- `lib/utils/accounts.dart:3` → `pages/mine/controller.dart`
- `lib/models/common/nav_bar_config.dart:4` → `pages/home/view.dart`
- `lib/utils/storage_pref.dart:29` → `pages/setting/...`
- `lib/http/init.dart:10` ↔ `lib/utils/accounts.dart:1`（互相依赖）

### 4.3 全局可变入口

| 入口 | 引用面 |
|---|---|
| `PlPlayerController` 静态单例 | 29 个文件 |
| `Request` 全局 Dio 单例 | 302 处调用（29 个 http 文件） |
| `Accounts` / `GStorage` | 259 处 |
| `GlobalData` | 34 处 |
| GetX `Get.put/find` | 266 处，与上面的静态单例**并存** |

最后一条值得单独注意：项目里同时存在两套依赖获取方式，没有统一约定。

---

## 5. P3 — 测试

### 5.1 分布极度集中

- 8 个测试文件、136 个用例、18 个 group；
- `test/pages/cdn_switch_mixin_test.dart` 一个文件 **1,932 行、45 个用例**；
- 而这 45 个里，有 **16 个实际测的是 `PlPlayerController` 的无视频轨逻辑**，
  不是 CDN 切换 —— 文件名叫 mixin，装的是播放器。

**完全没有测试的核心模块**：`lib/http/`（29 文件 / 302 处请求）、
`pl_player/controller.dart`（3,170 行）、下载、直播、模型、`storage_pref.dart`、路由。

### 5.2 为可测性付出的生产代码代价

- 20 个 `@visibleForTesting`（控制器 13、CDN mixin 2、console_log 5）；
- 生产 mixin 里直接留了注入字段 `Dio? cdnAutoDioForTest`（`cdn_switch_mixin.dart:393-394`）；
- 测试**无法构造播放器**（私有构造函数），只能靠摆布公开可变字段
  （`playerStatus`/`position`/`buffered`/…）和**匹配 `debugPrint` 文本**做断言
  （`test/pages/cdn_switch_mixin_test.dart:1929` 的 `contains`）。

最后一条是最贵的：**测试断言绑在日志文案上**，这直接导致 §6.3 的日志约束。

---

## 6. P4 — 常量、日志、依赖

### 6.1 调参常量分四层

| 层 | 数量 | 位置 |
|---|---|---|
| CDN 决策 | 25 个 `CdnTuning.*`（原 `_kCdn*`，已搬家） | `lib/pages/video/cdn_tuning.dart` |
| 播放器看门狗 | 29 个 `PlayerTuning.*`（原 `_k*`，已搬家） | `lib/plugin/pl_player/player_tuning.dart` |
| 测速 | 18 个 | `cdn_speed_test.dart:16-58` |
| Pref 默认值 | 若干 | `storage_pref.dart`（1,123 行 / 249 个 getter） |

三类之间靠注释互相引用，没有一个地方能看到全部。另有 265 处 `Duration` 字面量
散在 115 个文件里 —— 但**其中大部分是 UI 动效/提示时长，不该集中**（见 §8）。

### 6.2 依赖

- `pubspec.lock` 里 `source: git` 共 **28 条**；
- `pubspec.yaml` 里 **25 处 `ref:` 是可移动分支名**（`dev`/`main`/`master`/`native`/…），
  不是提交号。只有 `media_kit_video` 固定在有意义的提交上。

这是**唯一一条「便宜、无争议、确定该做」的清理项**：分支名随时可被 force-push
或前进，`pub get` 的结果不可复现。钉成 `pubspec.lock` 里已经解析出的 `resolved-ref`
即可，行为零变化。

### 6.3 日志是事实上的接口 —— 建议**一字不动**

日志被三处消费者**按子串匹配**：

1. `docs/logs/verify-rebuild.sh`（shell grep）；
2. `docs/auto-cdn-manual-checks.md`（逐字抄写日志串作为判据）；
3. 测试断言（`contains`，见 §5.2）。

而且日志是这个项目**唯一的真机取证通道**：`docs/logs/README.md` 表里 16 局归档、判据订正、
因果链全靠它。改文案会让历史日志和新代码不可比，`docs/logs/README.md` 里的对照表会失效。

**建议**：不改。若将来确实要动，只走一条路 ——
**抽成具名常量、值逐字符不变**（连全角标点、空格都不动），这样 grep 仍然命中。

顺带记录：文档里已有**失效**的日志串（`无视频轨自愈 1/2`、`[本次媒体已自愈过]` 等），
它们对应代码已删除 —— 这类「文档落后于代码」是另一类问题，和日志文案本身无关。

---

## 7. 建议路线（仅供参考，本次不执行）

三档可独立取舍，建议按 A → B → C 推进。

### Tier A — 零行为清理（低成本，可一次做完）

| 项 | 内容 |
|---|---|
| A1 | 修 §2.1 的两处匿名 Timer（**唯一带轻微行为收紧**的项，单独提交） |
| A2 | 补 `dispose()` 里 `volumeTimer?.cancel()` |
| A3 | 两处重复的账本清零（`resetDecodeErrorAccounting():525-532` 与 `_startListeners():1466-1471` 是两份完全相同的 6 行）抽成私有方法 |
| A4 | 把 24+24 个调参常量抽成常量类，**值一字不改、注释随值走** |
| A5 | 失效的 `file.dart:行号` 引用改为符号引用（`verify-rebuild.sh:50` 已漂移） |
| A6 | 25 处可移动 `ref:` 钉成提交号 |

### Tier B — 拆看门狗子系统（单点最大收益）

从 `pl_player/controller.dart` 抽出约 1,100~1,200 行（无视频轨判据 + 解码两族 +
缓冲看门狗 + 心跳）。

**用「宿主接口 + 独立类 + controller 薄委托」，不要用 mixin。** 理由：
mixin 看不到私有字段，仍要声明一整套 abstract 成员，等于付了接口成本却拿不到封装；
而独立类可以用假宿主直接实例化 —— 这才是治「测试必须靠日志断言」的根本办法。

**硬要求**：136 个用例的调用入口（`debugCheckNoVideoTrack(now)` 等）签名不变，
controller 留一行委托。`@visibleForTesting` 缝不合并、不删除，只做逻辑搬家。

### Tier C — 结构治理

- **C1**：CDN mixin 状态对象化 —— 只把 §3.2 那 10+ 处「同时改两个字段」收进
  `_CdnSwitchState` 的语义方法，**不重排 `_pickFastestCdn` 的算法**
  （那 470 行里的比值/冷却/Range/冠军位规则来自真机日志，重写风险远大于收益）。
  顺带把 5 个回调改成 `owner token` 原子挂载，修 §3.2 第 1 条。
- **C2**：分层 ratchet 脚本 —— 基线化「最大 SCC 内部边数」和「底层→pages 条数」，
  只允许下降。**不是一次性消灭循环依赖。**
- **C3**：叶子级依赖注入。**不要**动全局单例（见 §8）。

---

## 8. 明确不建议做的项

| 不做 | 理由 |
|---|---|
| 删 `BlockConfigMixin` / `longPressTimer` / `_cdnAutoAttempts` | 见 §2.3，都不是死代码 |
| 把 300 处 `res.data['code'] == 0` 抽 helper | 跨 100+ 文件的机械替换，收益只是少打字；不同接口的 `code` 语义并不一致 |
| 替换 532 处 `Success/Error` | 现有 `sealed class` 模式匹配已是正确抽象，替换只会加一层间接 |
| 集中 265 处 `Duration` 字面量 | 多数是 UI 动效/提示时长，集中后反而丢失局部语境 |
| 重写 `_pickFastestCdn`（470 行） | 规则来自真机日志，状态机化只应包住「轮次状态」 |
| 一次性消灭循环依赖 | 538 个文件的巨型分量，重写成本远超收益；只做 ratchet |
| 替换 GetX / `Request` / `Accounts` / `GlobalData` | 合计上千处调用点，对单人项目 ROI 为负 |
| 引入 custom_lint 做分层检查 | 单人项目维护 analyzer 插件不划算；一个 `tool/arch_check.dart` 够用 |
| 把 `PlPlayerController` 单例拿掉 | 29 个文件依赖它，且它承载「跨页共享 + 页面顶替」语义；DI 应发生在单例**内部** |

---

## 9. 附录 — 证据表

| 结论 | 文件:行 |
|---|---|
| 匿名 Timer（直播） | `lib/plugin/pl_player/controller.dart:1588` |
| 匿名 Timer（点播） | `lib/plugin/pl_player/controller.dart:1622` |
| dispose 实际取消项 | `lib/plugin/pl_player/controller.dart:2945/2946/2970/2988/2995` |
| `volumeTimer` 声明/赋值 | `lib/plugin/pl_player/controller.dart:2554`、`:2576-2577`；`lib/plugin/pl_player/view/view.dart:183-184` |
| `blockConfig` 转发 | `lib/pages/video/controller.dart:556`、`:1338`；`lib/pages/sponsor_block/block_mixin.dart:60/131/138/189` |
| `longPressTimer` 赋值 | `lib/pages/video/widgets/player_focus.dart:78`、`:127` |
| `_cdnAutoAttempts` 喂日志 | `lib/pages/video/cdn_switch_mixin.dart:1125-1127` |
| `_cdnIsAttached` 只比 1 个回调 | `lib/pages/video/cdn_switch_mixin.dart:826`，对照 `:871-877` |
| 两处重复的账本清零 | `lib/plugin/pl_player/controller.dart:525-532`、`:1466-1471` |
| 测试断言绑日志 | `test/pages/cdn_switch_mixin_test.dart:1929` |
| 日志判据文档 | `docs/auto-cdn-manual-checks.md:8-9`、`:111-139`；`docs/logs/verify-rebuild.sh` |
