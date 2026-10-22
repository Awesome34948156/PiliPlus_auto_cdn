# auto_cdn 代码评审（2026-10-22）

> **范围**：只审这个 fork 自己的改动，`4c4655059^..8c4619916`（94 个提交、86 个文件）。
> 上游五千多个提交不动。
>
> **基线**：`8c4619916`，工作区干净时的 `dart analyze` 无 error/warning、`flutter test --no-pub`
> 197/197、`dart run tool/arch_check.dart` **红**（`max_scc_internal_edges 2406 > 2405`）。
> 这条红灯在评审开始前就存在，成因见 §7。
>
> **方法**：按符号簇拆成八路只读评审（CDN 状态机 / CDN 轮次执行 / 播放器生命周期 /
> 播放器采样 / 装载与重建 / 日志与后台服务 / iOS 与构建脚本 / 测试与文档），
> 结论再过四道闸：死代码全仓反查、日志/toast 逐字节比对、异步交错穷举、
> 新测试先红后绿。
>
> **行号只作起点**：这个仓的行号漂得没规律（历次提交累积，偏移 1~153 行不等），
> 按符号名检索。

---

## 0. 结论

1. **一处真会掉进"两个 Player"的并发洞**（P1，已止血）。就地重建拆旧播放器的那几百毫秒里，
   若用户正好换集/换源，装载者与重建者会各建一个 `Player`：两路音频、原生句柄泄漏、
   `_startListeners` 的 assert 炸。本次用 `_processing` 这道确定性线索把它挡住；
   **通用**的"两次 `setDataSource` 重叠"仍未处理（见 §2.1），需要一次真机 + 设计。
2. **另有一条和 2026-10-22 00:59 真机故障同型的漏网路径**（P1，未修）：暂停着退后台 +
   「后台播放」关着时，回前台**没有任何东西**重建解码链。那条修复本身只覆盖了
   「后台播放开着」的主流配置。
3. **CDN 候选去重比错了 URL**（P1，已修 + 补测）：拿 API 列表第一条当"正在播的那条"，
   用户改过默认 CDN 或本集换过一次源之后，API 首选镜像会被**永久**排除在候选之外。
4. **三处闸门判据手抄了四遍**，其中两遍多写、尾段漏写（P2，已收成 `_roundAbandoned`）。
5. 其余是 17 条零行为修补（时钟回拨、UTF-8 字节计账、脚本 `set -e`、`.gitignore` 等）
   和一批文档口径订正。**没有改任何阈值、判定算法、日志与 toast 文案。**

---

## 1. 本次已经改掉（每项都有确定性依据）

| # | 位置 | 问题 | 依据 |
|---|---|---|---|
| F1 | `cdn_switch_mixin.dart` `_cdnAutoEligible` | `data` 是 `late PlayUrlModel`，原来在 `videoUrl` 之前读。预检定时器在 `onInit` 就武装，2 秒后那一拍会踩 `LateInitializationError` | `videoUrl` 只在 `data` 赋值后可能非空，换序不放过任何情况 |
| F2 | 同上 | `isQuerying` 这道闸散在各调用点，`_onPlayerStall` 漏了一条 | 三条入口都需要；收进入口判据 |
| F3 | `_CdnSwitchState.noteSuccess` | 换源成功后不清 `deferredSwitch`，回前台会照着**换源之前**的结论再换一次，把刚换好的镜像换走（同一代际，代际闸拦不住） | 后台待办指向旧对象，成功即作废 |
| F4 | `_autoSwitchLoop` 尾段（`_CdnTrigger.diverged` 那条兜底重载） | 只查 `decode` 分支的作废，轮到"兜底 `refreshPlayer()` + toast"时不再复查 → 被顶掉的旧页会去动**别人的**播放器、往用户眼前弹 toast | 与另外三处同一个判据，收成 `_roundAbandoned` |
| F5 | `resumeDeferredCdnSwitch` | `switchedAt` 原来在 `_awaitVideoChainWarm()` **之前**取，等链热的几秒被算进 `_awaitRecovery` 的恢复窗口 → 好好的换源被判"未恢复"；`lastOpenFailureAt` 的核对基准也提前 | 起点必须是"换源那一刻" |
| F6 | `_pickFastestCdn`（冠军 + 轮换两条过滤） | 去重拿 `cdnUrlFor(urls, CDNService.baseUrl)`（恒等于 `urls.first`）比，而不是**正在播**的 `baselineUrl` → 基线换了 host 后，API 首选镜像永远测不到也换不回 | 新增用例，改动前红、改动后绿（§8） |
| F7 | `_createVideoController` `_ownReload` | 原来是从 `await reload()` 之前置真到返回：窗口里插进来的**用户装载**会把凭证吃掉，结果额度重置反了 | 调用链同步（`reload → playerInit → setDataSource`），改成读到即清的一次性凭证 |
| F8 | `_runRenderContextRebuild` | 旧 `Player.dispose()` 抛错时 `_playerTeardown` 不会被摘下，之后每次 `_initPlayer` 都 `await` 到同一个异常 → 页面**再也装不起来**（重建是 `unawaited`，报错没人看见） | `try/finally` 摘钩子 |
| F9 | 同上 | 拆旧的那几百毫秒里开始的装载停在 `_initPlayer`，重建者随后也请页面重载 → **两个 Player**（§2.1） | `_processing` 是确定性线索；命中即收手 |
| F10 | 同上 | 旧流那条 3 秒「打不开」重载定时器活过重建，会在刚建好的播放器上再 `refreshPlayer()` 一次 | 重建入口 `_cancelErrorReload()` |
| F11 | `_verifyVideoTrackRestored` | 只复查了 6×500ms 那一轮，**最后一次** 500ms 等待里的换集没人复查 → `vid=no` 落到新文件上 | 同一个 `_processing` 复查 |
| F12 | 心跳 / `_starveReportDue` / `_rebufferEvents` 淘汰 | 系统时钟回拨（NTP / 用户改表）后差值为负：心跳整段哑、持续饥饿的 20s 补报永不触发、回拨后的第三个上升沿把旧账一起算进一次卡顿 | 三处补 `isBefore` 护栏（与 `recordDecodeErrorHit` 同一条） |
| F13 | `_backgroundSuspendDelay` | 两处逐字相同的"剩余时间"算术，负值兜底分别 `zero` / `1s` | 抽 helper，两个兜底**不合并**（装载边界立刻关会掐掉首帧） |
| F14 | `console_log.dart` | 上限按 `String.length`（UTF-16 code unit）算，而日志几乎全是中文 → 8 MiB 实际写到 20 MiB 以上才轮换，iOS 还要经 iCloud 同步 | `utf8.encode(...).length`，三处计账点统一 |
| F15 | `_fmtSpeed` / `select_dialog._updateSpeedResult` | 两处各写一遍 `toStringAsPrecision(3) + 'MB/s'`，精度是界面的一部分 | 合到 `CdnSpeedTest.formatSpeed`，输出逐字节相同 |
| F16 | `lib/scripts/mpvkit/fetch-xcframeworks.sh` | 解包只看目录在不在：版本号涨了会下载新 zip 再**跳过解包**，`relink.sh` 悄悄链旧二进制 | 加 `.mpvkit-version` 版本戳 |
| F17 | `lib/scripts/patch-macos.sh` | `set -euo pipefail` 下裸 `d=$(matdir)` 会在诊断之前中止脚本（`ls` 未命中 exit 1，pipefail 传出来） | 两处 `|| true`，真正的守卫是后面的 `-n` |
| F18 | `.gitignore` | `test*` 连**目录里的文件**一起忽略：`test/test_helper.dart` 等 `git add` 静默无声 | 补 `!test/**` 与 `!test/**/`，`git check-ignore` 已验 |
| F19 | `tool/arch_baseline.json` | 2405 → 2406（见 §7） | 逐指标差值表 |

`dart analyze` 无 error/warning，`flutter test --no-pub` **198/198**，`arch_check` 通过。

---

## 2. 未修：需要真机或先拍板

> **2026-10-22 更新：十条已全部改完。** Dart 侧九条在 `0251a1ab1`，iOS 插件一条在
> `119b628e9`。`dart analyze lib test tool` 0 error/warning、`flutter test --no-pub`
> 227/227、`arch_check` 四项门禁不变（538/2406/27/74）。**十条都还没真机验证**，
> 验收点见 §9 末尾的追加表。2.10 的拍板结论：欠账像链路层冷却一样**跨集延续**。

### 2.1 P1 — 两次 `setDataSource` 重叠仍是通用洞

`_runRenderContextRebuild` 里的挡板只处理"重建期间的装载"。**不以重建为前提**的两次装载
（例如预检与用户换集撞在同一拍）仍会各建一个 `Player`：`_initPlayer` 的互斥只有
`_playerTeardown`，而它只覆盖"旧的在拆"这一段。

现状：两处入口都靠 `_processing` 自觉不重入，没有断言也没有队列。建议做法（择一）：
`_initPlayer` 入口排队（`Future` 链），或在 `Player.create` 之前断言 `player == null` 并在
命中时复用。**都要真机验证换集/换画质连点**，因此本次只记录。

### 2.2 P1 — 暂停 + 「后台播放」关：回前台零重建

- 位置：`background_video_suspend.dart` 的 `shouldReinitDecoderOnResume`（要求
  `backgroundPlay`）、`pl_player/view/view.dart` 的回前台分支（只在
  `_pauseDueToPauseUponEnteringBackgroundMode` 为真时调 `reinitDecoderAfterBackground`）。
- 失败场景：用户暂停 → 退后台（「继续后台播放」关着，播放器原来就在暂停，所以那条
  `_pauseDueToPauseUponEnteringBackgroundMode` **不会被置真**）→ iOS 照样作废 VideoToolbox
  会话 → 回前台什么都没有重建 → 用户点播放，就是 00:59 那场
  `invalid session ×1 + HW accel end frame fail 99 行`。
- 证据：`_onBackgroundForVideoTrack` 的注释自己写了"省电开关关着时会话照样会作废"，
  但重建判据仍然按**设置**而不是按**进后台那一刻在不在播**。
- 修法方向：进后台那一刻记 `_enteredBackgroundWhilePlaying`，判据换成
  `!playing && !enteredBackgroundWhilePlaying`（后者为真时让 view 那条路负责，避免双重建）。
- 风险：NEEDS_DEVICE（改的是回前台的动作选择）。

### 2.3 P1 — 画中画的闸用了 `needsUpdate`，不是 `isActive`

- 位置：`controller.dart` 的 `_onBackgroundForVideoTrack` / `_maybeRebuildDecoderAfterBackground`
  （`IOSPipHelper.needsUpdate`），而 mixin 侧用的是 `IOSPipHelper.isActive`。
- 定义：`needsUpdate = isActive || _autoEnter`，而 `_autoEnter` 在用户打开"自动进入画中画"
  之后**整个会话都为真**（直到 `disableAutoEnter()`/`dispose()`）。
- 失败场景：开着自动进入画中画、但这一次 PiP 没起来（不可用/被系统拒绝）→ 10 秒关视频轨
  **永远不触发**，回前台的补重建也**永远跳过**。省电功能静默失效，日志里只有
  `后台省电: 跳过（画中画需要画面）`。
- 修法：分辨"小窗在显示"（`isActive`）与"要给原生推状态"（`needsUpdate`），前者才该豁免。
- 风险：NEEDS_DEVICE。

### 2.4 P1 — 回前台续播窗口没有 `appInBackground` / `_processing` 闸，且先烧冷却

- 位置：`controller.dart` 的 `_noteForegroundResumeFailure`。
- 失败场景：回前台窗口 8 秒内，若用户又锁屏（仍在窗口里），或页面正在换集（`_processing`），
  它会直接 `refreshPlayer()`：后台重建 = 拆音频输出、断音 1~3 秒，正是
  `_deferredDecoderRebuild` 那条注释里记录的"系统把正在播放交给别的 App"。
  而且 `_sessionHealUntil` 在动作之前就写上了：这一次白烧 30 秒冷却，等真需要救的时候
  反而被压住。
- 对照：隔壁 `_sampleDecoderSessionFailure` 有完整的四道闸（`isSeeking` / `_processing` /
  `isBuffering` / 余量）和 `appInBackground` 的推迟分支；那条是刻意豁免的（窗口短、
  现场就是"全都不健康"），但**后台**这一条不该豁免。
- 风险：NEEDS_DEVICE。

### 2.5 P2 — `_awaitRecovery` 对 `diverged` 不是有效判据

- 位置：`cdn_switch_mixin.dart` 的 `_awaitRecovery`（位置判据）+ `_CdnTrigger.diverged`。
- 失败场景：`diverged` 的定义就是"位置在走但画面冻着"。换源后拿
  `position - from >= 1s` 判恢复，一秒就"成功"——画面可能还是冻的，于是这一次换源被记成
  成功（`noteSuccess` 清掉尝试计数与放弃冷却），假成功。
- 修法方向：把触发原因传进 `_awaitRecovery`，`diverged` 档改用"遥测不再失真"作为判据。
  **不动比值与阈值。**

### 2.6 P2 — 用户 seek 不重新武装"余量归零"上报

- 位置：`controller.dart` 的 `_sampleRebuffer`（`_wasEmpty` 上升沿）+ `onSeekStart/onSeekEnd`。
- 失败场景：用户拖到一个没缓冲的位置，余量立刻归零 → 发一条 `CDN 余量归零 … 上报小卡顿`，
  mixin 当 `rebuffer` 触发开一轮。短时多次拖拽会凑够 `rebufferTrigger` 直接换源。
  文件头注释说"余量一涨回去就会重新武装，向后 seek 之后自然重新武装"，但**没有缓冲**的
  seek 不会涨回去。
- 修法：`onSeekStart` 里按"这次 seek 是我们自己发起的"置一个短暂抑制窗（与
  `_foregroundResumedAt` 同型）。

### 2.7 P2 — 直播也能进 `resumeDeferredDecoderRebuild`

- 位置：`controller.dart` 的 `_sampleDecoderSessionFailure`（`_deferredDecoderRebuild = true`
  的分支不排除 `isLive`）→ `view/view.dart` 的 `resumeDeferredDecoderRebuild` →
  `_reloadVideoTrack`（全局 `set vid no → auto`）。
- 失败场景：直播回前台时走一遍 `vid=no → auto`，mpv 的 refresh seek 在直播上是"跳到最新"。
  省电那条路明确排除直播（`BackgroundVideoSuspendBlocker.live`），这条没有。
- 风险：NEEDS_DEVICE（先确认直播真能触发到）。

### 2.8 P2 — 「全局」音频会话守卫没有引用计数

- 位置：`lib/services/audio_session.dart` 的 `startNowPlayingGuard` / `stopNowPlayingGuard`
  被两个宿主调用（`controller.dart` 与 `pages/audio/controller.dart`）。
- 失败场景：视频在播（守卫启动）→ 打开音频页（start 是 no-op）→ 视频暂停（`stop`）→
  守卫停了，但音频页还在播。此后 mpv 一旦把会话改回 `mixWithOthers`，锁屏卡片就没了
  （`_assertExclusive` 正是修这个的）。
- 修法：计数或"持有者集合"。

### 2.9 P2 — iOS iCloud 插件的两处线程/状态问题

- `ICloudLogPlugin.swift` 的 `upload()`：`beginBackgroundTask` 在 `opQueue`（后台线程）里调用，
  而 `UIApplication` 是主线程 API；过期回调和 `defer endBackgroundTask` 还会并发读写同一个
  `token`。失败场景：系统不认这次后台任务（或回调拿不到 token）→ 写到一半被挂起。
- `didPickDocumentsAt` 的 `opQueue.async { … reply([...]) }`：`FlutterResult` 在后台队列上调用
  （Flutter 平台线程契约）。失败场景：引擎侧断言/丢弃结果，Dart 端 `await` 挂起。
- `pickFolder` 的 `pendingPick`/`presentedPicker`：`host.present(picker)` 若因宿主已在呈现别的
  VC 而失败，delegate 两个回调都不会来，两个字段永久非空 → 之后每次调用只回 `BUSY`。
- 风险：NEEDS_DEVICE（要真机重现选目录/退后台）。

### 2.10 P2 — 换集清冠军欠账，降级永远凑不到 2

- 位置：`_CdnSwitchState.resetEpisode` / `resetForNewObject` 清 `championMisses`。
- 现状：短视频一集通常只跑一轮预检，而降级需要连续 2 轮没被选中。链路层冷却
  （`triedAt`/`noSample`）已经刻意跨集保留，欠账却仍按集清零 —— 同一个"历史冠军"在下一集
  继续白占候选位。
- 需要拍板：欠账要不要像链路层状态一样跨集延续。**这是产品语义，不是 bug 修法。**

---

## 3. 结构/重复（P2）与明确不合并清单

| 两处位置 | 等价性 | 处置 |
|---|---|---|
| `_fmtSpeed` ↔ `select_dialog` 的速度串 | **identical** | 已合并（F15） |
| 三处 `_roundVoided \|\| isQuerying \|\| !_cdnIsAttached` + 两处多写 `isClosed` | **identical** | 已合并为 `_roundAbandoned`（F4） |
| 两处后台剩余时间算术 | **identical** | 已合并，兜底参数分开（F13） |
| `_backgroundVideoSuspendTimer` 的 `cancel(); = null` 四对 | **identical（两行）** | 未抽：四处要保留/清空的 flags 各不同，抽"两行"收益低于误清 `_backgroundEnteredAt` 的风险。记在这里，防后人顺手合并 |
| 延迟换源尾段 ↔ 常规轮次尾段 | intentionally different | **不要合并**：延迟那条刻意跳过 `noteAttempt`、冠军记账与 toast，还有暂停态提前成功分支 |
| `file-local-options/vid` ↔ `command set vid`（`_remountSuspendedVideoTrack` / `_reloadVideoTrack`） | intentionally different | 合并会换 option 层：写过 file-local 之后全局 `vid` 被盖住 |
| `_cdnRecentlyTried` ↔ `_cdnDeadRecently` | intentionally different | 两套语义不同的时钟；合并会重新引入"永久排除" |
| 冠军过滤 ↔ 轮换过滤 | same intent / different guards | 冠军还查 `championMisses` 与记录；只有三条廉价检查重叠，抽取收益低且顺序敏感 |
| `stream.error` 直播 ↔ 点播恢复 | intentionally different | 谓词、toast、`telemetryDiverged` 处理都不同 |
| `_clearDecodeAccounting` ↔ `dispose` 复位 | intentionally different | 前者刻意保留 `_backgroundEnteredAt` |
| `_episodeInDirection` ↔ `nextPlay` / `prevPrev` | intentionally different | 三处刻意的方向语义差异，注释已写明；不要"统一" |

**不要**给 `_removeListeners` 加定时器取消：装载边界还要靠
`_rearmBackgroundVideoSuspendAfterLoad` 重排；定时器卫生要单独做（`NEEDS_DEVICE`）。

---

## 4. P3 清单（本次未逐条动手）

按文件成批清比逐条提交更安全，下面这些只登记：

1. `Api.pugvUrl`（`lib/http/api.dart:26`）全仓无使用点，`VideoType.pugv` 走的是
   `Api.ogvUrl` + 默认 `GET`，而同一端点 `pgc` 用 `POST`。是上游历史，且改请求方法会改变
   拉流行为 —— 只记录。
2. `docs/architecture-health-report.md` 是 `2ecb91f1d` 的快照，§5/§6 的计数与 `_kCdn*`
   与现状不符（`_kCdn*` 源码里已经 0 个，常量搬进了 `CdnTuning`/`PlayerTuning`）。已在
   报告的 2026-10-21 状态表补一行"以 `8c4619916` 实测为准"，正文仍是快照。
3. `AudioSessionHandler.setVolume` 的 du 半量在两处 switch 里各写一遍（duck 进/出），
   属上游代码，不改。
4. `test/pages/cdn_switch_mixin_test.dart` 的 `tearDown` 只清 `onStall`/`onDecodeError`，
   `onBufferStarve` 会跨用例泄漏。新用例目前不受影响，但下一个人加缓冲饥饿用例会踩。

---

## 5. 未覆盖的测试（现状，非本次引入）

| 行为 | 为什么测不到 |
|---|---|
| 音频跟随 CDN 改写 | 测试夹具的 `currentAudioQa` 恒为 `null`，没有 `isAudio` 形态 |
| `_cdnAutoEligible` 五道闸 | 只有正向路径；没有逐闸的负向用例（这次 F1/F2 的洞正是这样漏的） |
| 416 / 基线忽略 Range | 在 mixin 层没有用例（`CdnSpeedTest` 层有） |
| 速度记录写入 | `_recordCdnSample` 的写盘没有断言 |
| 冠军降级（`退出冠军位让给轮换`） | 该分支从未被执行过（欠账凑不到 2，见 §2.10） |
| 轮换相位推进 | 只有"必须保持 0"的用例，没有正向推进/回绕 |
| 解码会话族接线 | `decode_error.dart` 的纯函数测得很全，`_sampleDecoderSessionFailure` 的闸门顺序没有 |
| 位置监听器守卫 | `_roundLive` 那半截删掉也测不出来（见 `cdn-position-guard-untestable`） |

---

## 6. 日志接口核对

- 本次改了 **0 条** `debugPrint` 文案；新增 **1 条**
  （`就地重建: 跳过重载（拆除期间已有装载在途）`），它只出现在旧代码什么都不会做的分支。
- `git diff` 里被移动的行逐字未变（`--color-moved` 核对）。
- 清单里引用但**现在对不上**的两处（`docs/auto-cdn-todo.md`，未跟踪文件，按约定未改）：
  - `:48` 判据写 `Set property: hwdec=videotoolbox`，真机日志与实际命令是
    `hwdec=auto`（`controller.dart` 的 `reinitDecoderAfterBackground` 发的是偏好值）。
    这条判据按字面**永远匹配不上**。
  - `:52` 写 `3 秒内 6 条`，代码打印的是 `${window.inSeconds}s 内`，即 `3s 内 6 条`。
  - 该文件整体比 HEAD 落后约 10 个提交（记的是 `845737dbb` / `+5558`）。
- `docs/auto-cdn-manual-checks.md` 已订正：标题 19→21 条判据；`view.dart:495→498`、
  `view.dart:522→525`；`decode_error.dart:94/97/100 → 98/101/104`、`:86-92 → 86-97`。

---

## 7. arch 红灯

评审开始时 `max_scc_internal_edges` 是 **2406**，基线钉在 **2405**。逐边核对：

- `lib/pages/setting/models/play_settings.dart:11 → lib/plugin/pl_player/controller.dart`
  —— 「后台播放」开关要实时生效（`:222`），这条边是**有意加的**；
- `lib/pages/video/cdn_switch_mixin.dart → lib/utils/ios/pip_helper.dart`（PiP 豁免）；
- 少一条 `download_manager → http/init`（改构造函数注入时删掉的）。

净 +1。已用 `dart run tool/arch_check.dart --update` 重钉，其余三项指标不变
（538 / 27 / 74）。**这不是掩盖回退**：本次所有代码改动都没有新增 import 方向。

---

## 8. 新增与修改的测试

- `test/pages/cdn_switch_mixin_test.dart` 新增「基线换了 host 之后，API 首选镜像仍要进候选」。
  先在**改动前**的代码上跑（把 `url == baselineUrl` 临时还原成
  `url == VideoUtils.cdnUrlFor(urls, CDNService.baseUrl)`）确认**红**，再恢复实现确认**绿**。
  断言对象是 `cdn.samples`（`bytes=0-0` 的大小探测单独记在 `cdn.probes`，那里只有基线一条）。
- 全量 198/198。
- 2026-10-22 §2 批新增两件：`test/plugin/pl_player/decode_ledger_test.dart`（假宿主
  8 条，覆盖 2.3 / 2.4 / 2.7）、`test/pages/cdn_history_book_test.dart`（3 条，覆盖
  2.10 跨集延续与"只清 badHosts"）；`background_video_suspend_test.dart` 的回前台
  判据把旧的那条换成三条。全量 227/227。

---

## 9. 还要真机验的（代码动了这些就绕不过）

| 看什么 | 日志 | 这轮改了它的什么 |
|---|---|---|
| 换集/换画质连点，不许两路声音 | `就地重建: 跳过重载（拆除期间已有装载在途）` | F9/F10 |
| 回前台补重建：关后台播放 + 暂停退后台 | `后台省电: 回前台，补重建解码链` | F11（只动了复查） |
| 后台省电 10 秒关轨 / 暂停态 / PiP | `后台省电:` | F13 |
| 换源成功后回前台不再补换一次 | `CDN 自动切换: 回前台，补做推迟的换源` 不应出现 | F3 |
| 被顶掉的旧页不再弹 toast / 不再动播放器 | `CDN 自动切换:` 不应出现在旧页 | F4 |
| 基线在 ali 时设置页测速能测到 cos | `CDN 自动切换: …` 的候选列表 | F6 |

§2 十条（`0251a1ab1` / `119b628e9`）的验收点：

| 看什么 | 怎么算过 |
|---|---|
| 2.1 换集/换画质连点 | 日志里一次改动的 `Player` 创建不出两次，两路声音不出现 |
| 2.2 暂停 + 关后台播放 → 退后台 → 回前台 → 点播放 | 回前台先出 `后台省电: 回前台，补重建解码链`，点播放**不刷** `invalid session` / `HW accel end frame fail` |
| 2.3 开自动 PiP 但小窗没起来 → 退后台 10 秒 | 出 `后台省电: 关视频轨`，不再是一直 `跳过（画中画需要画面）` |
| 2.4 回前台窗口里再锁屏 / 换集在途 | 不应出现 `回前台续播仍在刷解码报错` 的动作，且回到前台后该动的立刻动（冷却没被白烧） |
| 2.5 画面已冻触发换源 | 换过去后不因"位置在走"就被记成功；`CDN 自动切换: 成功` 只在遥测不再失真时出现 |
| 2.6 拖到没缓冲的位置 | 不再出 `CDN 余量归零 … 上报小卡顿` 凑 rebuffer 轮次 |
| 2.7 直播退后台 | 日志 `硬解会话失效，但在后台（直播不推迟重挂视频轨）`；回前台不做 `vid=no → auto` |
| 2.8 视频暂停时音频页还在播 | 锁屏卡片不消失（守卫仍持有） |
| 2.9 选目录 / 退后台上传 / 连点选目录 | 选目录不再永久 `BUSY`；退后台那一刻的上传能写完；Dart 的 await 不挂起 |
| 2.10 短视频连看几集 | 冠军欠账跨集累加，凑到 2 轮后冠军位被让出 |

`docs/auto-cdn-manual-checks.md` 的 21 条判据里，本轮**没有**新增判据——动的都是
不该被观测到的路径；上表这几条是"改了动作选择"的，必须复验。
