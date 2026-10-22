/// 解码账本：两族解码报错的记账、冷却与时间窗。
///
/// 2026-10-22 全量评审 Phase 5 / S1：从 `PlPlayerController` 整块搬出来。这里只
/// 回答「这一条报错算什么、该不该动手、动哪一手」；**动作与日志留在 controller**
/// —— 换源回执（带返回值）、`refreshPlayer()`、重挂视频轨都是宿主的事，账本不碰
/// 播放器，因此可以拿假时钟单测。
///
/// 两族的动作相反，账本必须分开记：
/// - **坏字节**（[isDecoderCorruptionLog]）：镜像给的字节解不出来 → 换源。
/// - **本机解码会话废了**（[isDecoderSessionFailureLog]）：字节是好的，解码链被
///   系统作废 → 重建本机解码器。回前台续播那一段也记在这里，是同一个病。
library;

import 'package:PiliPlus/plugin/pl_player/background_video_suspend.dart';
import 'package:PiliPlus/plugin/pl_player/player_tuning.dart';
import 'package:PiliPlus/utils/decode_error.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// 账本要问宿主的事：全是**实时读**，不许在构造时快照。
///
/// 尤其是后台进/出时刻与几道闸门 —— 它们由生命周期回调和页面在账本之外改写，
/// 快照一份就会在「回前台第一拍」判错。
abstract interface class DecodeLedgerHost {
  /// 回调实参：`videoPlayerController?.state.position ?? Duration.zero`。
  Duration get reportPosition;

  bool get isSeeking;
  bool get processing; // controller 的 `_processing`（换源在途）
  bool get onlyPlayAudio;
  bool get isBuffering;
  int get bufferedAhead;
  bool get hasVideoTrack;
  bool get appInBackground;

  /// 直播流。推迟下来的重建走 `vid=no → auto`，在直播上等于"跳到最新"，
  /// 与后台省电那条路一样必须排除（见 [_deferredRebuild]）。
  bool get isLive;

  /// 后台会话起点 / 回前台时刻（`null` = 没有这一趟）。
  DateTime? get backgroundEnteredAt;
  DateTime? get backgroundExitedAt;

  /// 画中画**小窗真的在显示**：重挂视频轨会让小窗冻 300ms，账本据此让位。
  ///
  /// 只认 `IOSPipHelper.isActive`，不认 `needsUpdate` —— 后者含"自动进入画中画"
  /// 的意图位，整个会话都为真；开了自动 PiP 但这一次没起来时会白白让位。
  bool get pipActive;

  /// 上报一次坏字节风暴；**返回页面收不收**（false = 在途轮次太忙）。
  bool reportDecodeError(Duration at);

  /// 重开同一个 Media（`refreshPlayer()`）。
  void refreshMedia();

  /// 只重挂视频轨（`vid=no → auto`），不碰音频、不切 hwdec。
  void remountVideoTrack();
}

/// 解码账本。
final class DecodeLedger {
  DecodeLedger(this._host);

  final DecodeLedgerHost _host;

  /// 落在 [PlayerTuning.decodeErrorWindow] 里的解码报错时刻，窗口自己滑动淘汰。
  ///
  /// 刻意**不随每次装载清零**：换源重载期间旧流还在往外吐报错，那些报错说明的
  /// 正是刚才那段字节是坏的，必须继续记账（见 [sampleCorruption]）。只在
  /// 播放器创建（controller 的 `_startListeners`）和换集/换画质
  /// （`resetDecodeErrorAccounting`）时清。
  final List<DateTime> _decodeErrors = [];

  /// 落在 [PlayerTuning.decodeErrorDenseWindow] 里的坏字节**原始行**时刻（不去重）。
  ///
  /// 和 [_decodeErrors] 同一族、同一个病，只是数法不同：那个去重、这个不去重。
  /// 窗口只有 100ms，所以它常年只装十几条 —— 为它单开一个 list 换来的好处是
  /// 两个档互不干扰：调稀疏档的窗口/门槛不会动到密集档，反之亦然。
  /// 清零时机与 [_decodeErrors] 完全相同。
  final List<DateTime> _decodeErrorDense = [];

  /// 解码错误风暴的静默期截止时刻。见 [PlayerTuning.decodeErrorCooldown]。
  DateTime _decodeErrorUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// 最近一条解码器坏字节报错的时刻，**不受 [PlayerTuning.decodeErrorCooldown] 限制**。
  ///
  /// [CdnSwitchMixin] 换源后用它判断"这条镜像已经干净了"：坏镜像的特征恰恰是
  /// 缓冲填得满、位置还在被音频时钟推着走，所以位置和余量都判不出恢复，只有
  /// "不再吐坏字节"才是真话。
  DateTime? _lastCorruptionAt;

  /// 落在 [PlayerTuning.sessionFailWindow] 里的「本机解码会话废了」的报错时刻，
  /// 窗口自己滑动淘汰。与 [_decodeErrors] 分开记账：两族的窗口、门槛、以及
  /// **该做的事**都不同。
  ///
  /// 回前台续播的那一段（见 [_inForegroundResumeWindow]）也记在这里：它和硬解
  /// 会话失效是同一个病（本机解码链需要重建），只是报错的字样不同。
  final List<DateTime> _sessionFailures = [];

  /// 重建解码器的冷却截止时刻。见 [PlayerTuning.sessionFailCooldown]。
  DateTime _sessionHealUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// 会话族「回声」的截止时刻：会话族种子出现后开这么长一扇窗，窗内
  /// [isDecoderSessionEchoLog] 那两条通用症状也计入 [_sessionFailures]。
  /// 见 [PlayerTuning.sessionFailEchoWindow] 与 [classifyDecoderSessionLine]。
  DateTime? _sessionEchoUntil;

  /// 回前台开始续播的时刻；窗口长度见 [PlayerTuning.foregroundResumeWindow]。
  ///
  /// 由 [markVideoChainRebuild] 在**发命令之前**置上。窗口内解码器吐出的
  /// 坏字节签名不算镜像的账：那是切 hwdec / 从 GOP 中间续解的正常产物
  /// （`Missing Sequence Header` + `Missing reference frame`，紧随其后的是成片的
  /// OBU 报错），字节本身是好的。2026-10-20 20:47 真机：回前台 0.35s 后 68ms 内
  /// 153 行 libdav1d 报错，被当成"镜像喂坏字节"强制换源，还把一条健康的 ali 拉黑了。
  ///
  /// 它同时是 `videoChainRebuiltAt`（换源侧要避开解码器刚起来的冷启动段）。
  DateTime? _foregroundResumedAt;

  /// 后台攒下了「硬解会话失效」但没动手重建，等回前台再修。
  ///
  /// 重建会把音频输出一起拆掉、断音 1~3 秒。iOS 在断音那一瞬间就把「正在播放」
  /// 交给了上一个播放器，之后声音回来了、播放器卡片也回不来（2026-10-21 真机：
  /// 回主页 → 重建 → 2 秒断音 → 灵动岛变苹果音乐，重新认领也抢不回）。
  /// 后台本来就没有画面，重建没有意义，推迟到回前台。
  bool _deferredRebuild = false;

  DateTime? get lastCorruptionAt => _lastCorruptionAt;

  DateTime? get videoChainRebuiltAt => _foregroundResumedAt;

  int get sessionFailureCount => _sessionFailures.length;

  bool get deferredRebuild => _deferredRebuild;

  /// 回前台把推迟的重建补上时消费这张票（controller 的
  /// `resumeDeferredDecoderRebuild`）。
  void consumeDeferredRebuild() => _deferredRebuild = false;

  /// 换集 / 换画质 / 播放器创建：两族账本一起作废。
  ///
  /// 后台进/出时刻**不在这里**：前者是后台会话的（换集不重新计时），后者由
  /// controller 的 `_clearDecodeAccounting` 一并清。之所以拆成两处，是因为那份
  /// 「只留一份」的清法还要顺手复位后台省电的几个字段（定时器、暂停待办等）。
  void clear() {
    _decodeErrors.clear();
    _decodeErrorDense.clear();
    _decodeErrorUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _lastCorruptionAt = null;
    _sessionFailures.clear();
    _sessionHealUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _sessionEchoUntil = null;
    // 换成另一个视频/画质之后，"回前台续播"这个上下文也作废：新对象的头几秒
    // 报错该按它自己的镜像算，不能继承上一段续播的豁免。
    _foregroundResumedAt = null;
    // 后台攒下的那次重建属于**上一个**视频：换集/换画质会新建整条播放链，
    // 回前台再拿新对象去 `vid=no → vid=auto` 一遍，是白丢 300ms 视频轨。
    _deferredRebuild = false;
  }

  /// 视频链开始重建：记下时刻（[videoChainRebuiltAt]），并把此前攒的会话证据作废。
  ///
  /// 证据已经被这次重建消费了。不作废的话，重建自己吐出的 `Missing Sequence
  /// Header` 会立刻凑满账里残留的那 6 条回声（还不到 3 秒），把一次**廉价重挂**
  /// 直接升级成 `refreshPlayer()` —— 断音 1~3 秒，正是 [_deferredRebuild] 要避免
  /// 的那件事（见 [_noteForegroundResumeFailure] 与本账本共用）。
  void markVideoChainRebuild(DateTime now) {
    _foregroundResumedAt = now;
    _sessionFailures.clear();
  }

  /// 测试缝：把"回前台续播窗口"的起点摆到指定时刻。
  void noteForegroundResumeAt(DateTime at) => _foregroundResumedAt = at;

  /// 解码错误的采样：攒够 [PlayerTuning.decodeErrorBurst]（**或** [PlayerTuning.decodeErrorDenseBurst]）
  /// 条就上报一次坏字节风暴。
  ///
  /// 和另外三条采样不同，它不由 `_startStallTicker` 的心跳驱动，而是被
  /// `stream.log` 推进 —— 报错是**事件**不是采样量，ticker 那一秒一拍的
  /// 节奏会把它抹平（实测那一局 6 秒里就有几十条）。
  ///
  /// **两个档，任一满足即上报**：量的是同一个病、走的也是同一个动作。
  ///
  /// - 稀疏档：[PlayerTuning.decodeErrorBurst] 条 / [PlayerTuning.decodeErrorWindow]，含同包去重 ——
  ///   抓"成百条不停地刷"那种持续风暴。
  /// - 密集档：[PlayerTuning.decodeErrorDenseBurst] 行 / [PlayerTuning.decodeErrorDenseWindow]，
  ///   **不去重** —— 抓"几十毫秒里挤了几百条"那种短促爆发，也就是去重会把它们
  ///   整段数没的那一档（来由见 [PlayerTuning.decodeErrorDenseBurst]）。
  void sampleCorruption(String text, {DateTime? at}) {
    final now = at ?? DateTime.now();
    // 回前台续播窗口：这一段报错是"本机解码链还没接上"，不是"镜像给了坏字节"。
    // 两族的动作相反（换源 vs 重建解码器），窗口内一律让位给后者。
    //
    // **不能**更新 [_lastCorruptionAt]：换源恢复判据拿它当"新镜像还在吐
    // 坏字节"的证据，记上的话会把本机续解算到镜像头上，[CdnSwitchMixin] 要么
    // 判定未恢复继续换，要么把一条健康镜像拉黑。
    //
    // 窗口内认两族：坏字节签名（风暴主体）和续解签名（头几行 `Missing Sequence
    // Header` / `Missing reference frame`，它们本身不是坏字节）。
    if (_inForegroundResumeWindow(now)) {
      if (isDecoderCorruptionLog(text) || isDecoderContinuationLog(text)) {
        _noteForegroundResumeFailure(now);
      }
      return;
    }
    if (!isDecoderCorruptionLog(text)) return;
    // 不受静默期限制的"最后一次坏字节"时刻：给换源后的干净窗口判据用。
    _lastCorruptionAt = now;
    // 记账（含窗口淘汰与同包去重）在 [recordDecodeErrorHit] 里，是纯函数。
    final sparseReached = recordDecodeErrorHit(
      _decodeErrors,
      now,
      window: PlayerTuning.decodeErrorWindow,
      burst: PlayerTuning.decodeErrorBurst,
      lineDedupe: PlayerTuning.decodeLineDedupe,
    );
    // 密集档把去重窗设成 0：`now.difference(last) < Duration.zero` 恒为假，
    // 于是**每一条原始行都算数** —— 正是这一档要的语义，不必另写一个函数。
    final denseReached = recordDecodeErrorHit(
      _decodeErrorDense,
      now,
      window: PlayerTuning.decodeErrorDenseWindow,
      burst: PlayerTuning.decodeErrorDenseBurst,
      lineDedupe: Duration.zero,
    );
    if (!sparseReached && !denseReached) return;
    // **先记账、再判静默期**：静默期压的是上报，不是计数。换源重载期间旧流的
    // 报错照记 —— 它们说明的正是刚才那段字节是坏的。这样静默期一过，只要风暴
    // 还在继续，下一条报错就能立刻再上报一次，而不是从头再攒 12 条（换过去的
    // 镜像一样坏时，那 12 条就是白白多冻几秒）。所以静默期内**不清空**窗口。
    if (now.isBefore(_decodeErrorUntil)) return;
    _decodeErrors.clear();
    _decodeErrorDense.clear();
    _decodeErrorUntil = now.add(PlayerTuning.decodeErrorCooldown);
    // 报的是哪一档要写清楚：这两档在日志里长得像，而"44 毫秒 260 条"和
    // "6 秒 12 条"对不上账时，就靠这一行分辨盲区有没有回来。
    //
    // 两档都成立时报稀疏档那行 —— 那是原本就在的字符串，这样新字符串**只会**
    // 出现在旧代码打印不出任何东西的地方，读日志的老习惯（和清单里的速查表）
    // 一条都不用改。
    debugPrint(
      'CDN 看门狗: 解码错误风暴（'
      '${sparseReached ? '${PlayerTuning.decodeErrorWindow.inSeconds}s 内 '
                '${PlayerTuning.decodeErrorBurst} 条' : '${PlayerTuning.decodeErrorDenseWindow.inMilliseconds}ms'
                ' 内 ${PlayerTuning.decodeErrorDenseBurst} 行'}'
      '），当前镜像给的字节解不出画面 —— 上报换源',
    );
    // 回执：页面在途轮次收不下这一发（返回 false）时把静默期缩到 [PlayerTuning.decodeErrorRetryBackoff]
    // —— 两个窗口已经在上面清过，再攒够门槛就重报，风暴不会因为"页面正忙"永久丢失。
    // 用同一个 now（别重新取时钟：语义上应与这一次采样同一时刻）。没有页面挂上来
    // （null）时行为与旧版完全一致。
    if (!_host.reportDecodeError(_host.reportPosition)) {
      _decodeErrorUntil = now.add(PlayerTuning.decodeErrorRetryBackoff);
    }
  }

  /// 从 [start] 起算，[now] 落在 [window] 之内。
  ///
  /// [now] 早于起点（测试用的假时钟、或系统时钟回拨）时不算：那种情况没法判断
  /// "过了多久"。与 [recordDecodeErrorHit] 对回拨的处理不同是有意的 —— 那边宁可
  /// 多算一条坏字节，这边宁可少开一扇豁免窗。
  bool _since(DateTime? start, DateTime now, Duration window) =>
      start != null && !now.isBefore(start) && now.difference(start) < window;

  /// 这一次采样是不是落在回前台续播窗口里（见 [_foregroundResumedAt]）。
  bool _inForegroundResumeWindow(DateTime now) =>
      _since(_foregroundResumedAt, now, PlayerTuning.foregroundResumeWindow);

  /// 视频链刚重挂完、还在等首帧的静默期（见 [PlayerTuning.sessionFailRebuildSettle]）。
  bool _inVideoChainSettleWindow(DateTime now) =>
      _since(_foregroundResumedAt, now, PlayerTuning.sessionFailRebuildSettle);

  /// 这一次采样是不是落在后台/回前台过渡窗里（见
  /// [PlayerTuning.sessionFailTransitionWindow]）。
  bool _inBackgroundTransitionWindow(DateTime now) =>
      inBackgroundTransitionWindow(
        inBackground: _host.appInBackground,
        now: now,
        backgroundStartedAt: _host.backgroundEnteredAt,
        backgroundExitedAt: _host.backgroundExitedAt,
        afterResume: PlayerTuning.sessionFailTransitionWindow,
      );

  /// 回前台续播窗口里的解码报错：记进**会话族**，攒够就重建本机解码器。
  ///
  /// 与 [sampleSession] 共用账本和冷却，但**不走它那几道闸门**
  /// （`isBuffering` / `bufferedAhead <= 0` / `isSeeking`）：回前台第一拍这几样
  /// 恰恰全是"不健康"的样子（实测 `重新缓冲 true`、余量归零），而那正是要抓的
  /// 现场。闸门在这里放行是安全的 —— 窗口只有 [PlayerTuning.foregroundResumeWindow]
  /// 那么长，且来源被限定为"刚重建过解码链"。
  void _noteForegroundResumeFailure(DateTime now) {
    if (!recordDecodeErrorHit(
      _sessionFailures,
      now,
      window: PlayerTuning.sessionFailWindow,
      burst: PlayerTuning.sessionFailBurst,
      lineDedupe: PlayerTuning.decodeLineDedupe,
    )) {
      return;
    }
    // 闸门（与 [sampleSession] 的四道不同：这里只挡会**动手**的那两种）：
    //
    // - 已经在后台：窗口有 [PlayerTuning.foregroundResumeWindow] 那么长，
    //   用户完全可能回来瞄一眼又锁屏。重建会拆音频输出、断音 1~3 秒，iOS
    //   就在这一下把「正在播放」交出去，声音回来卡片也回不来。
    // - 装载在途：重建会和那一轮（换集 / 换源 / 回前台补做）抢播放器。
    //
    // 两处都**不烧冷却**：先记账不动手，等窗口里的下一条报错或装载结束。
    // 旧版在这里先写 [_sessionHealUntil] 再动手，被挡住的那些情形会白烧
    // 30 秒，等真需要救的时候反而被压住。
    if (_host.appInBackground || _host.processing) return;
    if (now.isBefore(_sessionHealUntil)) return;
    _sessionHealUntil = now.add(PlayerTuning.sessionFailCooldown);
    debugPrint(
      'CDN 看门狗: 回前台续播仍在刷解码报错（${PlayerTuning.sessionFailWindow.inSeconds}s 内 '
      '${PlayerTuning.sessionFailBurst} 条），本机解码链没接上 —— 重建解码器',
    );
    _host.refreshMedia();
  }

  /// 硬解会话失效的采样：攒够 [PlayerTuning.sessionFailBurst] 条就**重建视频链**。
  ///
  /// 与 [sampleCorruption] 是两个相反的结论，见 [isDecoderSessionFailureLog]：
  /// 那条路是"镜像给的字节解不出来" → 换源；这条路是"本机硬解会话被系统作废了"
  /// → 重建本机解码链。2026-10-11 实测那一局（退后台 6 分钟再回前台，0.881 秒
  /// 78 行、随后画面再没回来）正是后者：换源毫无用处 —— 字节是好的，位置和缓冲
  /// 余量全程健康。所以这里**不**上报坏字节风暴。
  ///
  /// 同样搭在 `stream.log` 上、同样因为"报错是事件不是采样量"，理由见
  /// [sampleCorruption] 的注释。
  void sampleSession(String text, {DateTime? at}) {
    final now = at ?? DateTime.now();
    // 后台/回前台过渡窗（见 [PlayerTuning.sessionFailTransitionWindow]）：播放中
    // 秒退秒回，iOS 作废硬解会话，mpv 可能**只吐回声、不吐种子**（2026-10-22
    // 12:18：2.06 秒 65 行、零种子）。窗内回声单独也算数，窗外照旧只认种子 ——
    // 这是"窗外的回声谁都不算、坏字节风暴不会被抢走换源动作"的唯一例外，而它
    // 被限定在"真进过后台"的一趟往返里。
    final inTransition = _inBackgroundTransitionWindow(now);
    // 种子（`invalid session` 之类）开一扇回声窗；窗内的 `HW accel end frame fail`
    // 这类通用症状也算数 —— 会话作废那一下种子可能只有 1 行，后面几十行全是回声
    // （2026-10-22 00:59：1 行种子 + 99 行回声，够不到 6 条门槛，画面闪了 3.3 秒）。
    final line = classifyDecoderSessionLine(
      text,
      now,
      echoUntil: _sessionEchoUntil,
      echoWindow: PlayerTuning.sessionFailEchoWindow,
      backgroundTransition: inTransition,
    );
    _sessionEchoUntil = line.echoUntil;
    if (!line.counts) return;
    // 让位于坏字节：两族的动作相反，同时开火会互相拆台（见那个常量的注释）。
    // 过渡窗也不例外 —— 真坏字节风暴同样会刷这两条回声，而它自带的坏字节签名
    // 一直续在 [_lastCorruptionAt] 上。
    final lastBadBytes = _lastCorruptionAt;
    if (lastBadBytes != null &&
        now.difference(lastBadBytes) < PlayerTuning.sessionFailDeferBadBytes) {
      return;
    }
    // 闸门：拆链 / 重载的缝隙里，会话报错是**正常**产物，不该拿去重建。本故障
    // 那一刻这几样全是健康的（实测：余量 28s、重新缓冲 false、输出参数
    // 1920x1080），所以它照样进得来。
    //
    // 换源在途由 `processing` 挡（页面 `playerInit` 会置它）；`refreshPlayer`
    // 不走那条路、自己不会置它，所以另用 `isBuffering` 与余量把
    // "任何一次重载的拆装抖动"一起挡在外面。
    //
    // 过渡窗里放过 `isBuffering` 与余量：回前台第一拍它们本来就可能是"不健康"
    // 的样子（实测 `重新缓冲 true`、余量归零），而那正是要抓的现场 —— 理由同
    // [_noteForegroundResumeFailure]。`isSeeking` / `processing` 照挡。
    if (_host.isSeeking ||
        _host.processing ||
        _host.onlyPlayAudio ||
        (!inTransition && (_host.isBuffering || _host.bufferedAhead <= 0)) ||
        // 输出参数是好的 ⇒ 坏在解码链上，不是无视频轨那条死锁 ——
        // 那条自己有自愈，两边不能同时动手。
        !_host.hasVideoTrack) {
      return;
    }
    if (!recordDecodeErrorHit(
      _sessionFailures,
      now,
      window: PlayerTuning.sessionFailWindow,
      burst: PlayerTuning.sessionFailBurst,
      lineDedupe: PlayerTuning.decodeLineDedupe,
    )) {
      return;
    }
    // 先记账、再判冷却：同 [sampleCorruption]，冷却压的是"动手"不是计数。
    // 这里不用清 [_sessionFailures] —— 冷却（30s）比窗口（3s）长得多，到那时
    // 旧记录早就自己出窗了，清是句死代码。
    //
    // 后台不重建：重建会拆掉音频输出、断音 1~3 秒，iOS 会趁这一下把「正在播放」
    // 交给别的 App，声音回来卡片也回不来（2026-10-21 真机，见 [_deferredRebuild]）。
    // 后台没有画面，回前台再修。
    if (_host.appInBackground) {
      // 直播不推迟：回前台那条 `vid=no → auto` 在直播上是"跳到最新"（refresh
      // seek），与后台省电那条路排除直播（`BackgroundVideoSuspendBlocker.live`）
      // 同一个理由。回前台后若还在刷，常规分支会用 `refreshMedia()` 重建。
      if (_host.isLive) {
        debugPrint('CDN 看门狗: 硬解会话失效，但在后台（直播不推迟重挂视频轨）');
        return;
      }
      if (!_deferredRebuild) {
        _deferredRebuild = true;
        debugPrint('CDN 看门狗: 硬解会话失效，但在后台 —— 推迟到回前台再重建');
      }
      return;
    }
    // 回前台的过渡窗：这一趟已经因为后台往返失效了，用**最便宜**的动作修 ——
    // 只重挂视频轨（不碰音频、不从 GOP 中间切 hwdec，实测首帧 0.43~0.6s），
    // 而不是重开 Media（1~3s，断音且丢「正在播放」的机会更大）。
    if (inTransition) {
      // 重挂刚发出去、链还在冷启动：这期间的报错是产物，别再叠第二个动作。
      // 静默期也用掉这一趟的唯一名额，所以下面**不设** [_sessionHealUntil]。
      if (_inVideoChainSettleWindow(now)) return;
      // 画中画里还有画面要看：重挂会让小窗冻 300ms。
      if (_host.pipActive) return;
      if (now.isBefore(_sessionHealUntil)) return;
      if (_since(
        _foregroundResumedAt,
        now,
        PlayerTuning.foregroundResumeWindow,
      )) {
        // 这一趟已经重挂过一次还在刷 —— 重挂治不了，升级成重开 Media。这里才设
        // 冷却：它压的是"重开 Media"，不该把 3 秒后那次廉价升级也一起压掉。
        _sessionHealUntil = now.add(PlayerTuning.sessionFailCooldown);
        debugPrint(
          'CDN 看门狗: 后台往返后重挂视频轨仍在刷解码报错（'
          '${PlayerTuning.sessionFailWindow.inSeconds}s 内 '
          '${PlayerTuning.sessionFailBurst} 条），本机解码链没接上 —— 重开 Media',
        );
        _host.refreshMedia();
        return;
      }
      // 第一次：只重挂视频轨。重挂自己写的 `videoChainRebuiltAt` 就是这一发的闩
      // （见上面的静默期）—— 3 秒后还在刷就升级，别让用户对着冻画面等满 30 秒冷却。
      _deferredRebuild = false;
      markVideoChainRebuild(now);
      debugPrint(
        'CDN 看门狗: 后台往返后仍在刷解码报错（'
        '${PlayerTuning.sessionFailWindow.inSeconds}s 内 '
        '${PlayerTuning.sessionFailBurst} 条），硬解会话已作废 —— 原地重挂视频轨',
      );
      _host.remountVideoTrack();
      return;
    }
    // 冷却期内又失效：不再干等着看画面冻多久。
    //
    // 冷却本身是对的（风暴里连着重建只会一次次把链路拆掉），错的是让位之后
    // **什么都不做**：2026-10-13 04:26 真机，重建后 7 秒系统又作废一次，被这
    // 30 秒压掉，最终是 mpv 自己掉到软解才活过来 —— 不是 app 救的。这里补上和
    // 上面过渡窗同形的梯子：先做最便宜的动作（只重挂视频轨，不碰音频、不动
    // hwdec），3 秒后还在刷再升级成重开 Media。
    if (now.isBefore(_sessionHealUntil)) {
      // 重挂刚发出去、链还在冷启动：这期间的报错是产物，别再叠第二个动作。
      if (_inVideoChainSettleWindow(now)) return;
      // 画中画里还有画面要看：重挂会让小窗冻 300ms。
      if (_host.pipActive) return;
      // 距上一次动手（冷却起点）过了多久 —— 日志要回答的就是"冻了多久"。
      // 必须在覆盖 [_sessionHealUntil] 之前算。
      final elapsed = now.difference(
        _sessionHealUntil.subtract(PlayerTuning.sessionFailCooldown),
      );
      final reason =
          '${PlayerTuning.sessionFailWindow.inSeconds}s 内 '
          '${PlayerTuning.sessionFailBurst} 条';
      if (_since(
        _foregroundResumedAt,
        now,
        PlayerTuning.foregroundResumeWindow,
      )) {
        // 这一轮已经重挂过一次还在刷 —— 重挂治不了，升级成重开 Media。
        _sessionHealUntil = now.add(PlayerTuning.sessionFailCooldown);
        debugPrint(
          'CDN 看门狗: 冷却期内再次失效、重挂视频轨仍没接上（$reason，'
          '距上次重建 ${elapsed.inSeconds}s，余量 ${_host.bufferedAhead}s）'
          ' —— 重开 Media',
        );
        _host.refreshMedia();
        return;
      }
      // 第一次：只重挂视频轨。重挂自己写的 `videoChainRebuiltAt` 就是这一发的
      // 闩（见上面的静默期）—— 3 秒后还在刷就升级，别让用户对着冻画面等满
      // 一个冷却。
      _deferredRebuild = false;
      markVideoChainRebuild(now);
      debugPrint(
        'CDN 看门狗: 冷却期内再次失效（$reason，距上次重建 ${elapsed.inSeconds}s，'
        '余量 ${_host.bufferedAhead}s）—— 原地重挂视频轨（硬解不动）',
      );
      _host.remountVideoTrack();
      return;
    }
    _sessionHealUntil = now.add(PlayerTuning.sessionFailCooldown);
    debugPrint(
      'CDN 看门狗: 硬解会话失效（${PlayerTuning.sessionFailWindow.inSeconds}s 内 '
      '${PlayerTuning.sessionFailBurst} 条），本机解码器被系统作废 —— 重建解码器',
    );
    // 重开同一个 Media：位置保留（见 `refreshPlayer` 里的 `start: state.position`），
    // 解码器和视频输出都是全新的。代价是缓冲从头攒、1~3 秒卡顿 —— 比永久黑屏值。
    _host.refreshMedia();
  }
}
