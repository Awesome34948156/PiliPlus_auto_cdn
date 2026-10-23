/// 这里只放**证据背书的调参值**，不放逻辑。
///
/// 每个数字的来历都写在它自己的注释里（真机日志、实测样本、为什么是这个
/// 量级）。改之前先读注释 —— 这些不是"看着顺眼"的默认值，窗口开短一点
/// 就会误伤健康装载，开长一点那族病就永远等不到救援。
///
/// 需要读取它们的地方（页面、测试、脚本）一律用 `PlayerTuning.xxx`，不要再抄一遍
/// 数字。
library;

/// 播放器看门狗的调参值。
abstract final class PlayerTuning {
  /// 位置连续冻结多少秒才算卡顿。普通重新缓冲一般 1~3 秒。
  static const int stallSeconds = 8;

  /// 短卡顿计数：窗口内"缓冲归零"的上升沿达到阈值同样判定为卡顿。
  /// 长冻结看门狗看不到"播放 3 秒卡 5 秒"这种反复小卡顿——它只累计连续冻结
  /// 秒数，位置一恢复就清零，永远到不了 [PlayerTuning.stallSeconds]。
  static const int rebufferTrigger = 3;
  static const Duration rebufferWindow = Duration(seconds: 60);

  /// 加载/换源后的静默期。刚开始缓冲时 `buffered` 本来就是 0，
  /// 不静默的话每次开播都会白记一次。
  static const Duration rebufferSuppress = Duration(seconds: 8);

  /// 解码错误风暴：这么短的时间内攒够这么多条解码报错，就认定这段流已经解不
  /// 出画面了。
  ///
  /// 数的是**去重后**的条数（同包在 `av1:` / `libdav1d:` / `NULL:` 层的重复行，
  /// 以及 `mpv [error] ffmpeg:` 与 `mpv error:` 两条路径的重复行，都按
  /// [PlayerTuning.decodeLineDedupe] 合并），不是原始行数 —— 换算比由爆发有多密决定，
  /// **不是固定的 3:1**。实测依据（档案 log 4 / log 7，2026-10-12 复核）：
  /// log 4 的 524 行全挤在 44 毫秒里、去重后**只剩 9 条**（够不到 12）；
  /// log 7 的 58 行横跨 2.4 秒、去重后 6 秒窗内峰值 **17 条**（够得到，余量
  /// 1.42×，首次达标 13:56:11.600）。所以这一档**不是够不到的死代码**。
  ///
  /// 12 条 / 6 秒是照着实测的两组数字卡在中间的：正常播放里解码器是**哑的**
  /// （那局日志里 8 个视频、二十多分钟，一条解码报错都没有），换集/seek 边界上
  /// 会冒 1~2 条（`Invalid NAL unit size` 那种，单个损坏的 GOP，几秒后自己就过
  /// 去了），而坏镜像的指纹是**成百行不停地刷**。两者差一个数量级，门槛落在中间
  /// 既不会漏报也不会被边界噪音打穿。
  ///
  /// ⚠️ 这一档管的是**横跨数秒**的风暴。挤在百毫秒里那种（log 4 就是）它够不到
  /// ——44 毫秒里只数得出 9 条，且放宽窗口也无用（整段就 44ms）—— 那一段由
  /// [PlayerTuning.decodeErrorDenseBurst]（20 行 / 100ms、不去重）兜。两档任一成立即上报。
  static const int decodeErrorBurst = 12;

  /// 上面那 12 条的统计窗口。风暴是"持续"的，用固定窗口而不是累计计数：累计
  /// 计数会让一次长时间的偶发报错（每个视频一两条）早晚凑够阈值，而窗口只在
  /// "短时间内密集发生"时才成立。
  static const Duration decodeErrorWindow = Duration(seconds: 6);

  /// 报过一次之后隔多久才允许**再报**（计数不受它影响，见 [_sampleDecodeError]）。
  ///
  /// 一轮换源要重载播放器，重载期间旧流的日志还在往外吐（解码器在把已经读进
  /// 来的字节消化完），不压住的话一次故障会连触发好几轮换源。取 30s：比
  /// 一轮换源（实测 5~10s）长得多，又比 CDN 那边放弃后的冷却（60s）短，于是
  /// 换到坏镜像上时还能再挣扎一次。
  static const Duration decodeErrorCooldown = Duration(seconds: 30);

  /// 页面在途轮次收不下解码风暴时的**退避**：这一发记成"稍后重报"，而不是等满
  /// [PlayerTuning.decodeErrorCooldown]（30s）。缩短是有意的 —— 在途轮次通常几秒到几十秒就收尾。
  /// 但也不立即解锁：拒收期间坏字节可能每秒几十条，不给下限就会刷屏（见
  /// [_sampleDecodeError] 的回执分支）。
  static const decodeErrorRetryBackoff = Duration(seconds: 2);

  /// 同一个坏包在 ffmpeg 的不同层会各记一行（`av1:` / `libdav1d:` / `NULL:`），
  /// 三行的时刻几乎相同。不合并的话 [PlayerTuning.decodeErrorBurst] 的 12 条门槛实际只等于
  /// 4 个坏包。记下一条之后，这么短时间内再来的都算同一个包，不再计入。
  /// 取 5ms：三层会跨毫秒边界，同毫秒太紧。
  static const Duration decodeLineDedupe = Duration(milliseconds: 5);

  /// 密集突发档：这么短的窗口里攒够这么多**原始行**就上报 —— **不做同包去重**，
  /// 这正是它存在的理由。
  ///
  /// 为什么需要第二个档：上面那条去重把命中率封在 1/[`PlayerTuning.decodeLineDedupe`]，
  /// 于是 [PlayerTuning.decodeErrorBurst] 的 12 条需要**至少 55ms 的跨度**。比这更密的爆发
  /// 反而数不满 —— 2026-10-11 实测那一场（日志 4，`22:53:59.334` → `.378`）
  /// **260 条坏字节挤在 44 毫秒里**，去重后只攒到 9 条，`解码错误风暴` 一条都
  /// 没出，而 44ms 之后风暴就结束了、窗口空着等 6 秒过期。**越密越看不见**，
  /// 是纯结构性盲区（条目 17）。
  ///
  /// 20 行 / 100ms 是照着"一个坏包在 ffmpeg 各层报 2~3 行"折算的：约等于
  /// 7~10 个坏包挤在 100ms 里。那场实测是 260 条，13 倍余量；反例侧同样宽 ——
  /// 换集 / seek 边界上的单个损坏 GOP 只有 1~2 行，差一个数量级。
  ///
  /// **只加给坏字节这一族。** 会话失效那一族不能加：我们自己的 `video-reload`
  /// 事故（见 [_rebuildRenderContextOnNoVideo] 上方那段墓碑注释）刷的 92 行里
  /// 就有 `invalid session`，加进来会把"镜像给的字节"和"本机解码器"两个相反的
  /// 结论搅在一起。
  static const int decodeErrorDenseBurst = 20;

  /// 上面那 20 行的窗口。要的是"挤在一起"而不是"跨得够久"：比稀疏档数不满的
  /// 最短跨度（55ms）宽近一倍，又短到不会把"慢慢刷"算进来。
  static const Duration decodeErrorDenseWindow = Duration(milliseconds: 100);

  /// 硬解会话失效：这么短的时间内攒够这么多条「本机解码会话废了」的报错，就重建
  /// 解码器。判据见 [isDecoderSessionFailureLog]。
  ///
  /// 6 条 / 3 秒是照着实测那一场卡的：0.881 秒里 26 条（会话层那两条，
  /// `invalid session` ×1 + `output image buffer is null` ×25）—— 4 倍余量。
  /// 不能只认单条：单条 `invalid session` 在 seek / 拆链的缝隙里也可能冒出来，
  /// 那时候重建是白扔一整个缓冲。
  static const int sessionFailBurst = 6;

  /// 上面那 6 条的统计窗口。同 [PlayerTuning.decodeErrorWindow]：要的是"短时间内密集"，
  /// 不是"累计"。
  static const Duration sessionFailWindow = Duration(seconds: 3);

  /// 重建过一次之后隔多久才允许再重建。一轮重建要重开播放器、缓冲从头攒
  /// （1~3 秒卡顿），不压住的话一次会话失效会连着重建好几轮。取 30s，与
  /// [PlayerTuning.decodeErrorCooldown] 同量级。
  static const Duration sessionFailCooldown = Duration(seconds: 30);

  /// 让位窗：距最近一条**坏字节**报错（[lastDecoderCorruptionAt]）不到这么久，
  /// 就不把会话失效当回事 —— 那说明真正发生的是"镜像喂了坏字节"，该走换源。
  ///
  /// 两族在同一场故障里可能交错出现（坏字节同样会让硬解拿不到输出缓冲），少了
  /// 这一条就会一边换源一边重建解码器，两个动作互相拆台。取 2s：坏字节是**成百行
  /// 不停地刷**的（实测档案 log 7：58 行横跨 2.4 秒；log 4：524 行挤在 44 毫秒里），
  /// 风暴期内 2 秒内必有新的一条续上。
  static const Duration sessionFailDeferBadBytes = Duration(seconds: 2);

  /// 回声窗：会话族**种子**出现后这么久之内，[isDecoderSessionEchoLog] 那两条
  /// 通用症状（`HW accel end frame fail` / `Error while decoding frame (hardware
  /// decoding)`）也计入会话族。
  ///
  /// 2026-10-22 00:59 真机：`invalid session` 只有 **1 行**，随后 3.3 秒里
  /// **99 行** `HW accel end frame fail`（30 行/秒）—— 只数种子的话
  /// [sessionFailBurst] 永远够不到，画面在坏帧之间闪了 3.3 秒没人管。
  /// 取 3 秒与 [sessionFailWindow] 同值：回声是种子那一场的尾巴，不该把窗口拖得
  /// 比计数窗口更远（回声不续期，见 `classifyDecoderSessionLine`）。
  static const Duration sessionFailEchoWindow = Duration(seconds: 3);

  /// 回前台续播后，多长一段窗口里的解码报错算「本机解码链没接上」而不是
  /// 「镜像给了坏字节」。
  ///
  /// 病因是 `reinitDecoderAfterBackground` 自己：切 hwdec 会清空参考帧池，续播
  /// 位置又在 GOP 中间，解码器于是先报 `Missing Sequence Header` /
  /// `Missing reference frame`，接着把整段 OBU 都解不出来。2026-10-20 20:47 实测：
  /// 回前台 0.35s 后 68ms 内 153 行 libdav1d 报错，按坏字节换了源、拉黑了一条
  /// 健康的 ali。窗口内不再更新 `lastDecoderCorruptionAt`，这些报错改记到会话族，
  /// 攒够就重建本机解码器（那之后画面确实能回来）。
  ///
  /// 取 5s：实测风暴在回前台后 1s 内结束，5s 已留 5 倍余量；再长就会把一条
  /// **真的**在吐坏字节的镜像多放过几秒。窗口一过，坏字节签名照常定罪换源。
  static const Duration foregroundResumeWindow = Duration(seconds: 5);

  /// 后台/回前台过渡窗：后台会话进行中，或从一个**真进过后台**的会话回来这么久
  /// 之内，[isDecoderSessionEchoLog] 那两条回声**单独**也计入会话族。
  ///
  /// 2026-10-22 12:18 真机：播放中秒退秒回（划走约 1 秒），iOS 作废 VideoToolbox
  /// 会话，mpv 刷了 **65 行** `vd: Error while decoding frame (hardware decoding)!`
  /// （12:18:57.958 → 12:19:00.016），**零种子** —— [PlayerTuning.sessionFailEchoWindow]
  /// 那种"1 颗种子 + 99 行回声"的兜底也开不了窗，计数为 0，画面一直冻到 mpv 自己
  /// 缓过来（可见约 1.25 秒）。同一份日志 11:54 的同类现场刷了完整三件套，被
  /// 「推迟到回前台 → 原地重挂视频轨」接住了 —— 缺的只是"只吐回声时也要认"。
  ///
  /// 取 5s：实测回声从进后台 0.13s 起、回前台后 1.2s 才停，5s 留 4 倍余量；
  /// 与 [foregroundResumeWindow] 同值。**再长就会把真坏字节风暴多放过几秒**，
  /// 而且过渡窗之外一律不认回声（见 `classifyDecoderSessionLine`）。
  static const Duration sessionFailTransitionWindow = Duration(seconds: 5);

  /// 视频链刚重挂完的静默期：这段时间里的会话报错是重挂的产物，不再叠第二个动作。
  ///
  /// 重挂本身有 300ms 无视频，冷启动出首帧实测最长 1.15s；3s 与
  /// [noVideoWindow] 同一把尺（健康装载最晚 2.22s），所以健康链不会被它误挡，
  /// 而"重挂没治好"的现场在 3s 之后才升级成重开 Media。
  static const Duration sessionFailRebuildSettle = Duration(seconds: 3);

  /// iOS 后台播放时，关闭视频轨前的等待时间。
  ///
  /// 取 10 秒是用户拍的板：锁屏看通知、切一下 App 这类几秒的短切换不触发，
  /// 回前台时也就不白付一次 refresh seek（恢复 `vid=auto` 会让 mpv 从关键帧
  /// 重开视频链，不可 seek 的流上实测过位置倒退 + 爆音，见 `_reloadVideoTrack`
  /// 上方的墓碑）；而后台真待上十几秒的情况已经能吃到大部分省电。
  ///
  /// 别往 0 改：那等于每次锁屏都关一次，而收益要在分钟尺度上才看得出来。
  static const Duration backgroundVideoSuspendDelay = Duration(seconds: 10);

  /// 后台播放关着时，退后台留给「手动按播放续播」的暂停卡片存活时长。
  ///
  /// 60 秒是用户定的（原来 8 秒，手慢一点就没了）。iOS 的后台任务额度只有
  /// 30 秒左右，原生侧会续一次任务把窗口撑满；真被系统提前冻住，卡片本身
  /// 还挂在锁屏上，到点收卡要等 App 被唤醒才会补做。
  static const Duration backgroundPlayGraceDuration = Duration(seconds: 60);

  /// 到点时装载 / seek / 重建在途时的重试间隔。
  static const Duration backgroundVideoSuspendRetry = Duration(seconds: 5);

  /// 恢复 `vid=auto` 后，等 `track-list` 事件回来的校验延迟。
  ///
  /// 不能用宽高判断：`vid=no` 时 media_kit 根本不会清零 `state.width/height`。
  static const Duration backgroundVideoResumeVerifyDelay = Duration(
    milliseconds: 500,
  );

  /// 暂停态补重建解码链之后，重新断言暂停的兜底窗口。
  ///
  /// `set hwdec` 重建轨道之后那一次 `ctr.pause()` 不总黏：2026-10-22 15:50 真机
  /// 报 `restart complete (paused)` 之后 `starting audio playback` 照样出现，
  /// 6.6 秒后心跳仍是 `播放中 false`、位置已前进 6 秒；17:45 那趟同形，最多放了
  /// 8.9 秒。漂移在 0.3~0.5s 内就开始，2 秒够覆盖三到四次采样；也不能再长 ——
  /// 窗口里用户点了播放就要立刻让位（见 `_resumePauseEpoch`）。
  static const Duration resumePauseRealignWindow = Duration(seconds: 2);

  /// 上面那扇窗的采样间隔。200ms 与漂移出现的时间尺度（几百毫秒）同量级，
  /// 又比 1 秒心跳细，能赶在用户听出「明明暂停了还在放」之前按住。
  static const Duration resumePauseRealignInterval = Duration(
    milliseconds: 200,
  );

  /// 兜底窗里位置走过多少才算「播放器自己跑起来了」。
  ///
  /// 刚发过 `seek`，落点抖动在几十毫秒内；500ms 之外就不可能还是抖动。
  static const Duration resumePauseRealignDrift = Duration(milliseconds: 500);

  /// 饥饿阈值取 mpv 回填水位的这个比例。水位是
  /// `demuxer-hysteresis-secs`（见 Pref.initBuffer）：mpv 补到 `cache-secs`
  /// 后停读，等掉回水位才续读，所以健康播放的锯齿在
  /// `[cache-secs, demuxer-hysteresis-secs]` 之间摆动、从来不会接近 0。
  /// 取 0.6 即 `cache-secs * 0.4`，比锯齿下沿还低 40%，健康播放碰不到。
  static const double starveFloorFraction = 0.6;

  /// 连续多少个 1s 采样低于阈值才算饥饿。健康锯齿只在谷底停留一两拍。
  static const int starveSeconds = 4;

  /// 一段饥饿**持续**期间，每隔多久补报一次 [onBufferStarve]（以及 [onTelemetryDiverged]，
  /// 两支共用这一份节奏和去重状态）。
  ///
  /// 判据 3 原来是"一段饥饿只报一次"，而"这段饥饿结束"的判据是余量涨回 mpv
  /// 自己的水位（见 [_sampleStarve] 末尾）—— 镜像持续供不上（或像 2026-10-12
  /// 那次一样持续喂坏字节）时余量一直趴在低位，那段饥饿**永远不会结束**，
  /// 于是那一次上报就是最后一次：那次唯一的 `缓冲饥饿` 上报被页面侧的放弃冷却
  /// 吞掉之后，后面 52 秒再没有任何信号，只能等 2 分钟定期档兜底。
  ///
  /// 补报没有改"这段饥饿报过没有"的语义，只是把它变成"每 [PlayerTuning.starveRepeat]
  /// 报一次"。页面侧那几道冷却（20s 无法测出 / 30s 小卡顿 / 60s 放弃）本来就是
  /// "现在别动"的判决，两边节奏相当，重复的上报会被它们照旧吃掉 —— 这本该如此：
  /// 播放器只管让"还在饿"这件事**持续可见**，切不切由页面判。
  static const Duration starveRepeat = Duration(seconds: 20);

  /// 看门狗心跳间隔。三条判据都只在出事时才出声，没有心跳就无法区分
  /// "一切正常"和"看门狗根本没跑"——两者留下的日志一模一样。
  static const int heartbeatSeconds = 10;

  /// 「闸门全开 + 画面为空」要**连续**攒满这么久，才认定是死锁。
  ///
  /// 判据从"数几探"换成了"时间窗"：ticker 1s 一拍、每拍都来看一眼，这段状态只要
  /// 没被打断（某道门成立、或 [_hasVideoTrack] 翻真）窗口就一直开着。
  /// 旧判据的死穴是采样节奏与装载时刻相位随机 —— 真机实测"2 探"花了 7.16s、
  /// "4 探"10.9s（2026-10-15），而"播放已经跑起来之后画面还空着"这件事与探了几拍
  /// 无关。
  ///
  /// **为什么是 3s 而不是更短**：它必须**严格超过健康装载的最晚值**。两局共 32 次
  /// 装载实测「选流 → mpv 配上视频输出」= 0.54~2.22s，而窗口是从"闸门开"起算的，
  /// 闸门开必然晚于选流 ⇒ 3s 的窗对任何健康装载都不可能误报（余量 ≥0.78s）。
  /// 这一条同时管住了"重建之后立刻再定罪"：重载一次 = 一次新选流，同样落在 2.22s 内。
  /// 所以本文件**不需要**再加"两次重建之间至少隔多久"的冷却 —— 窗口长度本身就是
  /// 那个冷却。若把窗降到 1.5s（≈2 拍），就**必须**另加冷却，否则第一次重建刚落地
  /// 就会烧掉第二次额度。
  static const Duration noVideoWindow = Duration(seconds: 3);

  /// 没有"解码器真的开了"这条证据时（[_noVideoStrongFingerprint] 不成立）的窗口。
  ///
  /// 比 [PlayerTuning.noVideoWindow] 长，是为了放过另一族病：**视频轨饿死**（视频轨那条 URL
  /// 坏了、压根没有帧）。它的形状与输出死锁一模一样（音频在走、画面恒空），但正解是
  /// 换源，不是拆播放器 —— 而它的指纹通常就是弱的（解码器起不来 ⇒ `hwdec-current`
  /// 空）。这一档取 8s ≈ 旧弱指纹路的量级（4 探 × 真机 2.86s/探），等于"没有证据就
  /// 不抢跑"。
  static const Duration noVideoWindowWeak = Duration(seconds: 8);

  /// 一种媒体最多就地重建几次渲染上下文。
  ///
  /// 第一次可能正好撞上 mpv 拆旧/建新的缝，第二次几乎不要钱；再多就是拿黑屏时间换
  /// 递减的收益（每次重建 ≈ 旧 player dispose 2s + 重载 1~3s）。用完之后回到老出路：
  /// 用户手动退出视频页再进来。
  static const int noVideoRebuildMax = 2;

  /// 阈值低于这个秒数就不再启用：回填水位太浅，没有可观测的余量。
  static const double starveMinSeconds = 4.0;

  /// 余量超过 mpv 缓存上限 `cache-secs` 的这么多倍，就认为遥测已经失真。
  ///
  /// 健康播放的锯齿在 `[demuxer-hysteresis-secs, cache-secs]` 之间摆动，永远
  /// 到不了 2 倍。而"只有声音、画面冻住"时音频轨的读指针还在推进，
  /// `demuxer-cache-time` 被音频一路抬到上千秒，于是余量涨成上限的几十倍 ——
  /// **离谱地大**本身就是故障指纹，跟判据 3 的"趴在低位"是同一个故障的两副
  /// 面孔 —— 但页面侧的处置完全不同（一个换源就够，一个只有重开连接才治），
  /// 所以走 [onTelemetryDiverged]，不跟"趴在低位"共用 [onBufferStarve]。
  static const double divergedFactor = 3.0;
}
