# 自动换源：真机手测清单

这份清单对应 17 条判据修复。其中大部分**单测验不了** —— 要真机、真网络才看得出
来：回拖重开闸、换画质的 416 循环、解码风暴的干净窗口、旧页面探测定时器、
暂停下换源。每条都写成「前置 → 手机上怎么做 → 哪行日志算通过 → 哪种现象是没修好」。

日志字符串逐字抄自源码（`lib/pages/video/cdn_switch_mixin.dart` 的
`debugPrint('CDN 自动切换: ...')` 和 `lib/plugin/pl_player/controller.dart` 的
`debugPrint('CDN 看门狗: ...')`）。

> 状态：**尚未执行**。写下来是为了让验证可复现，不代表已验证。

## 0. 先把日志打开（所有检查都依赖它）

设置 → 视频设置页（入口副标题「画质、音质、解码、缓冲、音频输出等」，
`lib/pages/setting/models/video_settings.dart`）。打开：

- **「卡顿自动切换 CDN」** → `SettingBoxKey.autoSwitchCdnOnStall`（默认开）。
  **必须开**：关掉时 `_cdnAutoEligible` 为假，每条检查都会卡在资格门上。
- **「详细播放日志」** → `SettingBoxKey.mpvVerboseLog` → `Pref.mpvVerboseLog`
  （`lib/utils/storage_pref.dart:517`）。它把 mpv 的 `logLevel` 抬到 `.v`，但
  **只在控制台出口开着时生效**：`lib/plugin/pl_player/controller.dart:1041`
  `logLevel: consoleLogActive && Pref.mpvVerboseLog ? .v : (kDebugMode ? .warn : .error)`。
- **「CDN 切换提示」** → `SettingBoxKey.showCdnSwitchToast`（默认开）。可选，
  给同一批事件做旁证。

**控制台日志开关不是一个用户设置**，别去找：捕获钩子在启动时无条件装上
（`installConsoleLogCapture()`，`lib/main.dart:99`），开关是 getter
`consoleLogActive`（`lib/services/console_log.dart:84`，`=> _sink != null`）——
正常手机包上文件能开就是 true，所以只开「详细播放日志」就够了。

日志文件：应用文档目录下的 **`pili-console.log`**（`_kConsoleLogName`，
`lib/services/console_log.dart:28`）。用 adb / 文件 App / iOS 文件共享取回，或直接
看控制台。iOS 上 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` 都开着，
所以「文件」App → 我的 iPhone → PiliPlus 里直接就有这个文件。

**每条物理行都以 `HH:mm:ss.SSS ` 开头**（`_stamp`，2026-10-11 加）。下面表格里那些
"逐字发出的行"指的是戳**之后**的那一段 —— grep 子串照样命中。加戳的理由：换源的一半
判据是时间窗判据（6s 内 12 条 / 5ms 内算同一包 / 换源后 ≥8s 干净），而 mpv 的原文
一个时刻都不带，没有戳的话日志只答得了"发生过没有"，答不了"够不够密"。

⚠️ **每次启动都会把这个文件截断重写**（`writeAsString('')`）。测完**别杀进程、别重启
app**，直接去文件 App 取，或者当场用共享菜单发出来。

注意：CDN 与看门狗那几行**刻意不套 `kDebugMode`**（`cdn_switch_mixin.dart` 注释：
「下面这些诊断刻意不套 kDebugMode：release 包只走手机测试，套了就看不到」），
所以 release 手机包上照样有。

构建注意：本仓库用 `lib/scripts/patch.ps1` 打完补丁后用 `--no-pub` 构建，
**不要**跑 `flutter pub get`。

### 日志字符串速查

| 事件 | 逐字发出的行 |
|---|---|
| 触发 | `CDN 自动切换: ` + `_describeTrigger`（见下） |
| 闸门：没推进 | `CDN 自动切换: 距上次尝试只推进了 Ns，忽略`（**N 只可能 ≥0**，见条目 1） |
| 闸门：忙/关/没资格 | `CDN 自动切换: 忽略<what> @Ns (busy=… closed=… eligible=…)` |
| 闸门：放弃冷却 | `CDN 自动切换: 冷却中，忽略<what> @Ns` |
| 小卡顿节流 | `CDN 自动切换: 小卡顿冷却中（距上次 Ns），只记不测 @Ns` |
| 目标偏移 | `CDN 自动切换: 目标偏移 <off>/<size> 字节 (位置 <ms>ms/<dur>ms)`（`size` 未探到时是字面量 `未知`） |
| 探大小失败 | `CDN 自动切换: 探测对象大小失败: <e>` |
| 本轮样本 | `CDN 自动切换: [基线 <host>] <r>MB/s (<kB>kB/<s>s ranged=<b>) \| [<svc>] 无样本` |
| 416 | `CDN 自动切换: 目标偏移 <off> 越界(416)，放弃本轮` |
| 基线非 206 | `CDN 自动切换: 基线未遵守 Range(200)，样本作废，放弃本轮` |
| 单 URL 失败 | `CDN 测速失败 <label>: <e>` |
| 没候选 | `CDN 自动切换: 没有可测的候选镜像` |
| 第 N 次 | `CDN 自动切换: 第N次 -> <svc> (<r>)` |
| 禁基线 host | `CDN 自动切换: <host> 给的字节解不出画面，本集不再作为候选` |
| 禁换入 host | `CDN 自动切换: <host> 换过去仍解不出画面，本集不再作为候选` |
| 切换成功 | `CDN 自动切换: 成功，已切到 <svc>` |
| 未恢复 | `CDN 自动切换: <svc> 未恢复，换下一个候选` |
| 冻结重载 | `CDN 自动切换: 画面已冻（余量失真），重载当前源` |
| 放弃 | `CDN 自动切换: 放弃，Ns 内不再尝试（<reason>）` |
| 解码档恢复 | `CDN 自动切换: 解码错误档换源后 Ns 无新报错，判定已恢复` |
| 余量恢复 | `CDN 自动切换: 前向余量回到 Ns（回填水位 N…s），判定已恢复` |
| 解码风暴 | `CDN 看门狗: 解码错误风暴（6s 内 12 条），当前镜像给的字节解不出画面 —— 上报换源` |
| 码率不够 | `CDN 自动切换: 解码错误，但没有候选能满足 <r>MB/s 的码率，放弃本轮` |
| 会话失效 | `CDN 看门狗: 硬解会话失效（3s 内 6 条），本机解码器被系统作废 —— 重建解码器` |

触发正文（`_describeTrigger`，逐字）：

- 预检：`预检 @Ns（新视频，在 size×15% 处测一轮，不看缓冲）`
- 定期：`定期测速 @Ns，前方余量 Ns 低于 mpv 回填水位，开始找可用镜像`
- 小卡顿：`小卡顿 @Ns，余量刚归零，后台快速测一轮（快速档 NNNkB × 3，不看缓冲水位）`
- 饥饿：`缓冲饥饿 @Ns，开始找可用镜像 (bufferSec=<Pref.bufferSec>)`
- 卡顿：`卡顿 @Ns，开始找可用镜像`
- 解码：`解码错误 @Ns，当前镜像给的是坏字节（画面已解不出来），直接换源、不看速度`

通用前置：真机 + 一个 ≥10 分钟的长视频 +「详细播放日志」开 + 日志出口接上。
要造故障就用代理限速 / 飞行模式闪断 / 一个喂坏字节的镜像。

---

### 1 — 回拖会永久关掉闸门（HIGH）

前置：必须有一轮**"切了但没成功"**的账。`_cdnLastAttemptPos` 只在**切换那一刻**
置非零（`cdn_switch_mixin.dart` 的 `_cdnLastAttemptPos = stalledAt`），而一轮
**成功**会把它归零（同文件的 `成功，已切到` 那一行）—— 所以光看到 `第1次 ->`
**不算数**，必须看到那一轮最终是 `… 未恢复，换下一个候选` → … → `放弃`。

> 实测（2026-10-11）：那一轮是 `第1次 -> tf_hw` → `未恢复` → `第2次 -> hw` →
> `成功，已切到 hw`，闸门**当场归零**。此后回拖无论怎么拖都不会有任何一行 ——
> 不是漏了，是闸门根本没关上过。

步骤：等上面那种"切了又放弃"的一轮结束，**过掉那 60s 放弃冷却**（否则只会看到
`冷却中，忽略…`），然后往回拖 ≥3s，再立刻制造一次卡顿/饥饿。

通过：出现**新的**触发行（如 `CDN 自动切换: 卡顿 @Ns，开始找可用镜像`），且里面的
位置是**变小后**的新位置 —— 它同时证明了回拖那一支确实把非零值清掉了。

失败：**拖完之后再等多久都没有新的触发行**（不是"出现 `Δ 为负` 的行"，见下）。

⚠️ `CDN 自动切换: 距上次尝试只推进了 -Ns，忽略` 里 **Δ 为负是打不出来的**：
代码先做 `if (position < _cdnLastAttemptPos) _cdnLastAttemptPos = Duration.zero`，
紧接着的闸门又要求它非零 —— 两条合起来 Δ 只可能 ≥0，那行只在"位置只推进了 0~2 秒"
时出现。拿它当本条的失败证据是清单早期版本的笔误（2026-10-11 修正）。

`playRepeat` 循环播放也会这样复现。

### 2 — 换画质 = 新的对象：重新探大小、不出现 416 循环、不毒化死镜像冷却（MEDIUM）

前置：1080P 在播，`_cdnObjectSize` 是大对象长度。记住 `目标偏移 …/<大size> 字节`。
步骤：切画质 1080P→360P（`updatePlayer` → `resetCdnForNewObject`），然后制造卡顿。
通过：下一轮打印的 `目标偏移 <off>/<新size> 字节` 用的是**新**size；候选行照常出现
（`… | [<svc>] <r>MB/s …` 或 `无样本`），**不出现**
`CDN 自动切换: 目标偏移 <off> 越界(416)，放弃本轮`；候选池也不空
（不出现 `没有可测的候选镜像`）。416 那条 return 在 `_cdnNoSample` 记账**之前**，
所以没有镜像被锁 30 分钟。
失败：整集每轮都以 `越界(416)，放弃本轮` 收尾，随后 `没有可测的候选镜像`
（死镜像冷却 `_kCdnDeadRetryAfter` = 30 分钟被毒化了）。

### 3 — 作废的那一轮不许清忙闸（MEDIUM）

前置：制造一个能拖住的换源（限速下的慢卡顿），使 `_cdnAutoBusy == true` 并已出现 `第1次 ->`。
步骤：那一轮还在跑时换画质（`resetCdnForNewObject` → `_cdnGeneration++`），再触发一次卡顿。
通过：后一次触发被**认了** —— 打印触发行 + `第N次 ->`，且永远不出现
`(busy=true …)` 的 `忽略…` 行。代际不匹配让旧轮的 `whenComplete` 跳过清忙，闸门归新一代。
失败（少了条目 3）：两轮并发，出现两组交错的 `第N次 ->`。
失败（少了条目 2）：此后每次触发都 `忽略<what> @Ns (busy=true …)`，永久卡死。

### 4 + 10 — 取样点落在**缓存末端之后**；时长未知时退回内部下界（MEDIUM/LOW）

前置：任意一集在播，盯着 `目标偏移 <off>/<size> 字节 (位置 <posMs>ms/<durMs>ms)`。
步骤：正常播（缓冲健康、bufferedAhead > 0），再让它饿到 0。
通过：`<off>` 对应 `(max(cacheEnd, playhead) + 5000ms) / durMs × size` —— 落在播放头
字节**之后**、也落在缓存末端之后，且 ≥ `size × 0.15`（15% 下界）、≤ `size − 4MiB`。
当 `<durMs>` 是 `0`（刚装载、时长还没到）时，偏移是**内部下界** `size × 0.15`，
不是 `0`（不是头部）。只有听视频（`onlyPlayAudio`）或 size 未知/为 0 才给 `0`。
失败：`目标偏移` 等于头部（`0`，或冷启动时的播放头字节）—— 头部每个镜像都快，
样本打平、比值 ≈ 1，即使尾段真的坏也报 `没有找到更快的镜像` / 永不切换。

### 5 — 关掉控制台日志时采样仍要活着（MEDIUM）

前置：release 或 debug 包都行；把日志关掉（「详细播放日志」OFF），能造出
`consoleLogActive == false` 更好。喂坏字节（坏镜像/代理吐垃圾，或实测那个 AV1 1080P 场景）。
步骤：让坏源播上几秒，攒够一轮报错。
通过：`CDN 看门狗: 解码错误风暴（6s 内 12 条），当前镜像给的字节解不出画面 —— 上报换源`
照样出现，后面跟一个 `解码错误 @Ns…` 触发。`stream.log` 订阅现在是无条件的，
`_sampleDecodeError(log.text)` 对每条消息都跑，跟 `kDebugMode`/`consoleLogActive` 无关。
失败：报错在刷（mpv 那边照写），但看门狗那行永不出现 —— 判据静默失明，正是修复前的行为。

### 6 — 账在换集/换画质时归零，但**换源时不归零**（MEDIUM）

前置：坏源，默认档位（logLevel `.error`）。
步骤 (a)：风暴中途换集（或换画质），新一集得从头攒。
步骤 (b)：同一集里，让一场风暴横跨一次自动换源（重载会排空旧流的报错）。
通过 (a)：换集后**不立刻**出现看门狗行 —— 必须重新攒满 12 条/6s；旧流的账不带过去
（页面在 `controller.dart:1309` `onReset` 调 `resetDecodeErrorAccounting()`，
换画质走 `resetCdnForNewObject()`）。
通过 (b)：换源期间旧流的报错**继续计数** —— 换源前会触发的那场风暴，换源后照样触发
（`_decodeErrors` 刻意不在 `player.open`/`setDataSource` 里清）。
失败 (a)：新一集的 host 被上一集残留的风暴瞬间禁掉。
失败 (b)：每次重载都把计数清零，风暴永远攒不满 12，换源永不发生。

### 7 — 解码档按干净窗口判恢复；换入的 host 会被禁；最终干净地放弃（HIGH）

前置：源级坏字节（所有镜像的字节一样坏 —— 比如坏上传，或代理对每个 host 都吐垃圾）。
默认档位即可。
步骤：播到解码风暴触发，让循环跑到头。
通过：每次尝试都由干净窗口裁定，只有在画面真的干净时才打印
`CDN 自动切换: 解码错误档换源后 Ns 无新报错，判定已恢复`（≥4s 宽限之后再有 ≥4s 安静，
**合计 ≥8s**；日志里那个 Ns 是"观察到的安静时长"，所以它在成功时应 ≥4）。
仍然坏的镜像被禁：`CDN 自动切换: <host> 换过去仍解不出画面，本集不再作为候选`；
换到好源以 `CDN 自动切换: 成功，已切到 <svc>` 结束。对全坏的源，收敛到
`第N次 -> …` 最多 `_kCdnMaxAttempts`（3）次，然后放弃：
`CDN 自动切换: 放弃，Ns 内不再尝试（换了几处镜像，画面仍然解不出来，已暂停尝试）`。
失败：快但坏的镜像在 ~0.5s 内被判"已恢复"（走的是余量/位置那条），画面还冻着；
循环在同样几个 host 之间来回弹，而不是逐个禁掉再放弃。
注意强制档的总上限是 `_kCdnDecodeRecoverWindow`（18s），不是 12s 的 `_kCdnRecoverWindow`。

### 8 — 跳相关视频后，旧页面的探测定时器要静音（MEDIUM）

前置：播一个视频，看着探测节奏（起播后每 2s 一次预检，之后 `定期测速` 每 2 分钟）。
步骤：从播放页点一个**相关视频**（会 push 第二个 `/videoV`，不关第一个）。
让新视频起播；等过至少一个旧节奏窗口（≥2 分钟，且越过旧页面的下一次预检轮询）。
通过：旧页面的定时器在下一拍自我取消 —— `_cdnIsAttached`（`onStall == _onPlayerStall`）
为假，`_onCdnProbeTick` 取消 `_cdnProbeTimer` 后静默返回。此后**不再**出现
属于前一个视频的 `CDN 自动切换: 预检 @Ns…` / `定期测速 @Ns…`；只剩新页面的节奏。
失败：新视频在播之后，仍然冒出 `预检`/`定期测速`（或 `第N次 ->`）且播放器用**旧视频的 URL**
重载 —— 表现为新视频莫名回跳/重载。

### 9 — 某个候选的 416 不该作废整轮（LOW）

前置：一轮里 1 个基线 + ≥2 个候选，其中一个候选的对象更短/不接受该 range（在该偏移回 416）。
步骤：制造卡顿，看这一轮。
通过：该候选在本轮汇总里就是 `无样本`，并产生 `CDN 测速失败 <label>: <DioException 416>`；
**其他**候选的样本保留、本轮继续。`offsetRejected` 只在 `isBaseline` 为真时置位。
若**基线**回 416，整轮正确作废：`目标偏移 <off> 越界(416)，放弃本轮`。
失败：单个候选的 416 就产生 `越界(416)，放弃本轮`，把好候选的样本一起丢掉，
还白搭 20s 的 `_kCdnUnmeasuredCooldown`。

### 11 — 零字节镜像不该被重新排进候选（LOW）

前置：让一个镜像进入 `_cdnNoSample`（某轮它一个字节没到 → `[<svc>] 无样本`）。
步骤：同一集里立刻再来一轮（再制造一次卡顿）。
通过：零字节镜像在放宽的第二遍里被跳过 —— 不出现在下一轮的样本行里；
只在第 1、2 遍都填不满窗口时才走第 3 遍「全都不管」。有可用候选时不该出现
`CDN 自动切换: 没有可测的候选镜像`。
失败：零字节镜像每轮都被重新排进去，每次白搭两个 3s 超时
（`_kCdnDeadRetryAfter` = 30 分钟就是为了防这个）。

### 12 — 换集时 `_cdnQuickProbeAt` 要归零（LOW）

前置：触发一次小卡顿探测，让 `_cdnQuickProbeAt` 打上时间戳（出现 `小卡顿 @Ns…`）。
步骤：30s 内（`_kCdnRebufferCooldown`）换到下一集，再制造一次余量归零。
通过：新一集的小卡顿打印
`CDN 自动切换: 小卡顿 @Ns，余量刚归零，后台快速测一轮（快速档 NNNkB × 3，不看缓冲水位）`
—— 节流被 `resetCdnAutoSwitch` 清了（`_cdnQuickProbeAt = null`）。
失败：打印的是 `CDN 自动切换: 小卡顿冷却中（距上次 Ns），只记不测 @Ns`，N < 30 且指的是
**上一集** —— 新一集开头 30s 的小卡顿全被压住。

### 13 — 暂停后强制换源：播放必须保持暂停（LOW）

前置：坏源；暂停播放（缓冲里残留的坏字节仍可能凑够一场风暴）。
步骤：暂停，等解码风暴触发（`CDN 看门狗: 解码错误风暴…` → `解码错误 @Ns…`）。
通过：换源照跑，但播放**保持暂停** —— `_switchTo` 现在读
`final wasPlaying = plPlayerController.playerStatus.isPlaying;` 再
`playerInit(autoplay: wasPlaying)`，位置不前进、暂停态保留；用户的
`Pref.autoPlayEnable` 偏好也不被改写。
失败：重载后自己播起来了（旧代码写死 `autoPlay = true`）。

### 14 — 强制档也不许落到喂不动的镜像上（LOW）

前置：坏源，且 `needBps` 已知（size 与 duration 都探到）；唯一候选很慢（~43 KB/s）。
步骤：让解码触发出手，候选被测完。
通过：`CDN 自动切换: 解码错误，但没有候选能满足 <needBps>MB/s 的码率，放弃本轮`
—— 因为 `needBps > 0 && bestBps < needBps`，宁可拒绝也不落到不可播的镜像上。
size/duration 未知（`needBps == 0`）时跳过这道守卫，行为与原来一致
（强制档绕过 `_kCdnStarveRatio` 仍然成立）。
失败：循环换到那个 ~43 KB/s 的镜像上（`第N次 ->` 之后接着饿），而不是拒绝。

### 15 — 大小写不同的解码报错仍要认得（LOW）

前置：主要是**单测**（`test/utils/decode_error_test.dart` 覆盖
`av1: OBU_Forbidden_Bit Out Of Range`、`INVALID NAL UNIT SIZE`）。真机上只是抽查。
步骤：坏源下把 `pili-console.log` 里的原始 mpv 行捞出来，确认即使 ffmpeg 用混合/大写
发签名，仍然能产生看门狗行。
通过：`isDecoderCorruptionLog` 两边都转小写（`_kDecoderCorruptionSignaturesLower`），
比如 `metadata obu type` 任意大小写都能匹配、都能触发 `CDN 看门狗: 解码错误风暴…`。
失败：某个大小写变体（如 `Error Parsing OBU Data`）流过去了却没有看门狗行 —— 判据静默失效。

### 16 — 时钟回拨会让记录过期（LOW）—— **只能单测**

没有控制手机系统时钟就测不了。由 `test/utils/cdn_speed_test_test.dart` 对着桩时钟覆盖：
`CdnSpeedTest.recordTooOld(now, recorded, window)` 在 delta 为负（NTP 回拨/用户改时钟）
以及 `delta >= window` 时都返回真，所以一条峰值记录活不过 6 小时的作废线，
「重新开窗」那道守卫也照样触发。真机上唯一的症状是"一条陈旧峰值记录永不过期"，
手动触发不到。

### 17 — 风暴门槛数的是**包**不是日志行（LOW）

前置：坏源；一个坏包会被 ffmpeg 的各层（`av1:` / `libdav1d:` / `NULL:`）发 2~3 行。
步骤：真机上看 `CDN 看门狗: 解码错误风暴…` 是相对多少个**坏包**触发的；
去重窗是 `_kDecodeLineDedupe = 5ms`（距上一条 5ms 内的算同一个包，不计入）。
通过：需要约 12 个**不同**的坏包（每个包 5ms 内的多层重复只算一条），而不是约 4 个。
要精确确认看纯函数单测 `recordDecodeErrorHit`（`test/utils/decode_error_test.dart`）。
失败：只攒到约 4 个坏包就触发（修复前的有效门槛），即三层的重复被各记了一条。

---

### 18 — 回前台后硬解会话作废：画面必须自己回来（HIGH，2026-10-11 新增）

前置：任意一集在播（**AV1 硬解**那一档，`hwdec videotoolbox`）。
病根不是源、不是字节：iOS 在 app 被挂起时会作废本机的 `VTDecompressionSession`。

步骤：`1` 记下当前画面正常；`2` 退到后台 **≥5 分钟**（锁屏或切走都行）；`3` 回到 app。

通过：**≤2 秒**内出现
`CDN 看门狗: 硬解会话失效（3s 内 6 条），本机解码器被系统作废 —— 重建解码器`，
随后画面自己回来（日志里能看到新的 `VO: [libmpv]` / `vo/libmpv: reconfig`），
位置不倒退（`refreshPlayer` 用 `start: state.position`）。

失败（修复前的实测样子）：回前台瞬间刷 78 行
`av1: Failed to decode frame (invalid session, -12903)` /
`av1: vt decoder cb: output image buffer is null: -12909, reconfig 1` /
`vd: Error while decoding frame (hardware decoding)!` /
`av1: HW accel end frame fail.`（0.881 秒内），然后**画面再也没回来** ——
位置照走（19s→28s）、余量健康（28s）、音频正常，只有画面是黑的，直到手动切走。

要一起确认的三件（这一档的副作用 / 误伤面）：

1. 重建后**不该**跟着冒出一轮换源（`预检` / `缓冲饥饿` / `测速` 都算误伤）——
   重建会把缓冲清零，若 CDN 那边的饥饿判据被它带起来，说明需要一个抑制窗。
2. 不该**反复**重建：冷却 30s，正常一轮就恢复；若日志里每 30s 一条，说明新会话
   在回前台后又被作废，得走第二级（软解回落，尚未实现）。
3. 坏源那一路（条目 7/17）**不许**被这条路抢走动作：真坏字节时应当看到
   `CDN 看门狗: 解码错误风暴` 而不是这条。判据上两族由
   `lastDecoderCorruptionAt` 的 2 秒让位窗隔开（见 `_sampleDecoderSessionFailure`）。

纯函数那半边由单测覆盖：`isDecoderSessionFailureLog` /
`test/utils/decode_error_test.dart`。

---

## 需要真机确认的调参

这几个都是拍的，真机限速下盯着看。

1. **`CdnSpeedTest.sampleLeadMs` = 5000ms**（计划里叫 `_kCdnSampleLead`，已搬到
   `lib/utils/cdn_speed_test.dart` 的 `sampleLeadMs`，由 `_starveOffset` 传入）——
   取样点越过缓存末端的量。
   - 太小：样本落回热的缓冲区间（实测同一偏移热 19.2MB/s、冷 0.683MB/s）→ 基线虚高、
     除掉它之后比值塌下去、永不切换（`目标偏移` 又贴回缓存末端/播放头字节）。饥饿时最致命，
     因为那时 `cacheEnd == playhead`，这个 lead 是唯一的余量。
   - 太大：取的字节超出播放头接下来要用的范围，量到的速度不代表即将播放的那段；
     对短对象还会被 `size − readWindowBytes` 夹到同一个偏移，所有镜像打平。

2. **`_kCdnDecodeCleanWindow` = 4s**（`cdn_switch_mixin.dart`）—— 判定解码档恢复所需的安静时长。
   - 太小：慢一点才坏的镜像在下一场风暴来临前就被判
     `解码错误档换源后 Ns 无新报错，判定已恢复`，几秒后画面又冻（来回弹）。
   - 太大：真的好镜像被判未恢复 → 多余的重载/位置抖动；而每次失败都禁一个 host，
     候选被耗光，正常的网络最后落到放弃。

3. **`_kCdnDecodeRecoverGrace` = 4s**（`cdn_switch_mixin.dart`）—— 旧流的报错不算新镜像账的宽限期。
   - 太小：重载（实测 5~10s）期间旧流还在排空，那些报错刷新 `lastDecoderCorruptionAt`，
     干净窗口永远满足不了，连好候选也判未恢复 → 干净地放弃。
   - 太大：新镜像真实的坏字节被忽略那么久 → 坏镜像看着"干净"，在画面还冻着时被判已恢复
     （正是条目 7 修掉的那个 bug）。
   - **注意它必须按时刻滤**（`lastDecoderCorruptionAt` 早于 `start + grace` 的整段忽略），
     不能只用来重置一个 `since`：grace 和 `_kCdnDecodeCleanWindow` 等长时，后者会把
     宽限期想区分的那件事原样抹平（判据退化成"离最近一次报错满 4 秒"，而那次报错可能
     来自旧流）。这两条谁改都必须一起改。

4. **`_kCdnDecodeRecoverWindow` = 18s**（`cdn_switch_mixin.dart`）—— 解码档等待恢复的总上限。
   - 太小：重载（5~10s）+ 宽限（4s）+ 干净窗口（4s）≈ 13~18s 塞不下，正好在镜像快要自证干净时
     判失败 → 提前禁 host、来回弹。
   - 太大：一心想换掉一条真坏的镜像时，每次尝试都要烧这么久；配上 `_kCdnMaxAttempts = 3`，
     一轮可以在冻着画面上耗掉约 54s 才放弃。

5. **`PlPlayerController._kDecodeErrorBurst` = 12 / `_kDecodeErrorWindow` = 6s**
   （`lib/plugin/pl_player/controller.dart`）—— **这一条有个前提尚未验证：门槛可能根本够不到。**
   算一下：实测那次风暴是「400+ 行」，而行→包的去重比约 3:1（一个坏包在 `av1:` /
   `libdav1d:` / `NULL:` 各记一行），于是约 133 个包。如果这 133 个包摊在整个播放时长
   （而不是全部挤在冻住的那一段），包速率就是 ~1.3/s，而门槛要求 12 个包挤进 6s = **2/s**。
   真这样的话，`decode` 这一档在它自己为之而生的场景里**永远不会触发** —— 修复等于没生效，
   而日志里只有沉默，没有任何一行提示。
   - **怎么量**（要有**带时间戳**的那版日志，即 2026-10-11 之后的构建；更早那份没有戳，
     量不了）：
     `grep -E "obu_forbidden_bit|Error parsing OBU|Unknown OBU type|Invalid NAL unit size|missing picture in access unit" pili-console.log | cut -c1-8 | uniq -c`
     `cut -c1-8` 取的是 `HH:mm:ss`，所以输出就是"每秒多少行"。除以约 3（去重比）就是
     包速率。**≥ 2/s** → 12/6s 成立，不用动；**≈1/s** → 门槛够不到，把窗口放宽到 12s
     （而不是把门槛降到 6：放宽窗口只是等价于 1/s，而降门槛会把"换集边界上一两条"的
     零星报错也算成风暴）。
     注意这条要的是**风暴那几秒**的行密度，不是全程平均：把 `uniq -c` 的输出按峰值看，
     平滑平均会把一段 400 行的爆发摊成"全程很稀"。
   - 另外两处注释（`decode_error.dart` 顶部的「400+ 条」和 `controller.dart` 里
     `_kDecodeErrorBurst` 的那段"卡在两者之间"）互相不自洽：前者是行数、后者是包数，
     中间隔着一个约 3 倍的去重比和一段没说清的时长。量完顺手把这两个数写实。

## 复查追加的四处（2026-10-11，对抗性复查 diff 之后修的）

这四处都不是新功能，是上面条目的补洞 —— 前一轮的修复各自留了一条"作废的轮次仍会提交状态"
的缝。查的时候跟对应条目一起看：

- **条目 2 的补洞（HIGH）**：一轮测速中间有两次数秒级的 await（探大小、并发测速），期间
  换画质/换集会把这轮作废，但作废的那一轮**仍在往下写** —— 最毒的是把**旧对象**的字节总长
  写回 `_cdnObjectSize`。它是一次性的（只有 `size == null` 才探），被填回去就整集不再探第二次，
  此后每轮都拿旧长度算偏移，落到短一截的新对象上必得 416 → `unmeasurable` → 自动换源整集失效。
  查法：换画质那一下之后，`目标偏移 …/<size>` 里的 `size` 必须是**新画质**的长度；若一直沿用
  旧值（或此后每轮都 `越界(416)，放弃本轮`），就是这个洞。现在两处 await 之后都有
  `_roundVoided(generation)` 复查，作废即 `return null`，一个格子都不落。
- **条目 8 的补洞（MEDIUM）**：`_cdnIsAttached` 原先只挡了探测定时器，挡不住**在途的那一轮**：
  旧页的 `_autoSwitchLoop` 已经在跑，回调被新页覆盖也拦不住它，它会拿**旧视频**的 URL 去
  reload 新视频的播放器。查法：跳相关视频后看有没有"第N次 -> …"来自旧视频；现在整个循环里
  三处闸门都带 `!_cdnIsAttached`。
- **条目 7 的补洞（MEDIUM）**：`_awaitRecovery(decode:true)` 返回 false 有两种含义 ——
  "新镜像还在吐坏字节"和"这一轮作废了/页面关了"，而原来的禁 host 把两种都当成前者，
  凭空封掉一条从没被播出过的镜像 30 分钟。现在禁 host 前要求这一轮仍然有效。
- **条目 6 的补洞（MEDIUM）**：挂载新页（相关视频跳转，旧页不 `onClose`）从来不重置共享
  播放器的解码账，于是旧视频的残余计数让新视频几条零星报错就凑满风暴门槛，没过期的静默期
  又把新视频真正的风暴按下去。现在 `attachCdnSwitch()` 里调 `resetDecodeErrorAccounting()`。

## 复查追加的第二批（/code-review，2026-10-11）

这六个是自动代码复查抓出来的，其中两个就在第一批的修复里（第一批修的是"作废的轮次
仍会提交状态"，这批修的是"作废的轮次在别处留下的另一边"和"恢复判定自己的时间轴"）：

- **恢复判定提前到 4s（HIGH，在第一批的修复里）**：滤掉旧流报错之后，安静时长是从
  `start` 算的（不是从宽限期结束算），于是 `elapsed >= 4 && since >= 4` 在 elapsed 刚
  够 4 那一刻同时成立 —— **一秒安静都没观察到**就宣布恢复，宽限期又从另一头变成空转，
  跟 `_kCdnDecodeRecoverWindow` 注释里的"宽限 + 干净窗口（≈8s）"自相矛盾。现在从宽限期
  结束算，合计 ≈8s。查法：看 `解码错误档换源后 Ns 无新报错` 里的 Ns，成功时它必须 ≥4。
- **跳相关视频回来之后永久静默（MEDIUM）**：旧页被顶掉时停掉自己的探测定时器，而返回时
  没有任何东西重挂 —— 连换集都不恢复（`restartCdnProbe` 只重启定时器，不重挂回调）。
  修法：`attachCdnSwitch()` 改成幂等的，并在 view 的 `didPopNext`（返回本页）里调它。
  查法：A → 相关视频 B → 返回 A → 制造一次卡顿，`CDN 自动切换:` 必须照常出现。
- **旧页退出清掉现役页的解码账（MEDIUM）**：`detachCdnSwitch → resetCdnAutoSwitch` 会动
  共享播放器的账，而被顶掉的旧页退出时那份账是现役页的。修法：只有"退出时仍是现役页"
  才清，判断在回调置空前取（置空之后 `_cdnIsAttached` 自己就成假了）。
- **时钟回拨会让解码判据整个 session 失效（LOW）**：`recordDecodeErrorHit` 的去重比较
  在回拨后成负数 → 此后每条报错都被当成同一包的副本吞掉，而淘汰条件对未来时刻也不成立
  → 记录清不掉。和条目 16（`recordTooOld`）是同一件事，按同样口径修：负差值算新的，
  落在未来的旧记录清掉。单测 `test/utils/decode_error_test.dart` 里钉住了。
- **`_cdnTriedAt` 记在作废判断之前（LOW）**：候选冷却在测速**之前**写入，于是作废的那一
  轮仍会给新对象留下 3 分钟冷却（`_cdnTriedAt` 是刻意为换画质保留的）。已挪到两道作废
  判断之后。影响本来被三遍候选循环的第三遍（忽略冷却）挡掉大半，所以只是让注释里那句
  "一个字节都不许提交"变成真话。
- **`disableAudioCDN` 在换源时被忽略（MEDIUM，**既有**，不是这次改出来的）**：音频那条
  重写没把 `isAudio: true` 传进 `getCdnUrl`，于是"音频不跟随 CDN"这个设置只在起播时
  生效、一换源就失效 —— 正是这个开关要避免的"部分视频无声"。`cdnUrlFor` 现在带
  `isAudio`。**这条在 HEAD 里就是这样**（`CdnSpeedTest.urlFor` 也没传），顺手修了。
  查法：打开该设置，换源后看音频 URL 的 host 有没有跟着变。

## 备注

- 条目 15、16 本质上是单测项；17 用纯函数单测确认最好，真机只做抽查。
- 5、6、7、17 都需要一个**真的坏源**（喂坏字节的镜像/代理）。源码注释里的真实复现是：
  一条 1080P AV1 流，余量 ≈27s、位置一路推进、`hwdec videotoolbox` 正常，同时 mpv 在刷
  解码报错 —— 吞吐、缓冲、位置全是健康的，只有解码器日志看得见这件事。
- 条目 8 的 `_cdnIsAttached` 靠回调同一性（`plPlayerController.onStall == _onPlayerStall`）；
  新旧两页都是 `/videoV`，没有页面路径可区分 —— 所以"通过"的证据是旧节奏**消失**，
  而不是某行"已分离"的日志。
