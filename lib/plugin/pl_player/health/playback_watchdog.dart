import 'package:PiliPlus/plugin/pl_player/player_tuning.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// [PlaybackWatchdog] 要看的现场与要发的动作。
///
/// 适配器留在 `controller.dart` 里、只做一行转发；本文件绝不 import
/// controller（分层闸门要求 health/ 不成环）。
abstract interface class PlaybackWatchdogHost {
  /// 前方余量（`buffered - position`，负数按 0）。
  int get bufferedAhead;

  /// 整秒播放位置（日志里的 `@Ns`）。
  int get positionSecs;

  /// 整秒总时长。
  int get durationSecs;

  bool get isBuffering;

  /// 回调的实参：播放器自己的位置（`videoPlayerController?.state.position`）。
  Duration get reportPosition;

  /// 读 mpv 选项表里的一个键（`buffer[key]`）。
  String? mpvOption(String key);

  void reportStall(Duration at);

  void reportBufferStarve(Duration at);

  void reportTelemetryDiverged(Duration at);

  void reportRebuffer(Duration at);
}

/// 卡顿看门狗的账本与两条采样判据。
///
/// 1. 位置连续 [PlayerTuning.stallSeconds] 秒没有推进，再以 [PlaybackWatchdogHost.isBuffering] 作确认。
///    不能只看 [PlaybackWatchdogHost.isBuffering] —— 普通重新缓冲也会让它为 true，会造成切换风暴。
/// 2. [sampleRebuffer]：窗口内缓冲归零的上升沿达到 [PlayerTuning.rebufferTrigger] 次。
///    判据 1 看不到反复小卡顿（位置一恢复就清零），由判据 2 补上。
/// 3. [sampleStarve]：前向缓冲长期趴在低位。判据 1、2 都要求 buffered 归零，
///    而 mpv 有 cache-secs 打底、换源型卡顿时位置又由音频时钟推着走，
///    两者都见不到"余量在变少"——这条只看 buffered，是唯一的早期信号。
///
/// ticker 与判据 1 的 8 秒冻结计数仍留在 controller（评审 S4 未做）：这里只搬
/// 账本和两条采样。2026-10-22 评审 Phase 5 / S3 整块搬出。
final class PlaybackWatchdog {
  PlaybackWatchdog(this._host);

  final PlaybackWatchdogHost _host;

  final List<DateTime> _rebufferEvents = [];
  DateTime _rebufferSuppressUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _wasStalled = false;

  /// 余量是否已经归零过（[PlaybackWatchdogHost.reportRebuffer] 的上升沿去重）。
  bool _wasEmpty = false;
  int _starveSeconds = 0;

  /// 当前这段饥饿的最后一次上报时刻；null = 没有正在上报的饥饿段。
  ///
  /// 兼作去重状态：非空即"这段已经报过"，只有余量真的涨回水位才清空（见
  /// [sampleStarve]）。存时刻而不是 bool 是为了补报 —— 见 [PlayerTuning.starveRepeat]。
  DateTime? _starveLastReportAt;

  /// 遥测是否已经失真：前方余量离谱地大于 mpv 的缓存上限。
  ///
  /// 判据见 [PlayerTuning.divergedFactor]。这是"只有声音、画面冻住"唯一可靠的信号 ——
  /// 那时位置由音频时钟推着走、`buffered` 被音频轨抬到上千秒、[PlaybackWatchdogHost.isBuffering]
  /// 是假，判据 1、2 都看不见，判据 3 的"趴在低位"也只防了反的一侧。
  bool get telemetryDiverged {
    final limit = _divergedAheadSec;
    return limit > 0 && _host.bufferedAhead > limit;
  }

  /// 清空三条判据的状态并进入静默期。任何一次装载（开播、换源、换 P、切换
  /// CDN）都会让 buffered 归零，必须显式调用。
  ///
  /// 判据 1 那两个计数（`_stallLastSecond` / `_stallFrozen`）由 controller 自己
  /// 在调用前后维护，顺序见 `_resetStallWatchdog`。
  void reset() {
    _rebufferEvents.clear();
    armSuppress();
  }

  /// 重新武装三条判据的去重状态，效果等同于刚装载。
  ///
  /// 静默期的含义是"这段时间里的归零一律不算数"：只要进入静默时不把"已归零/
  /// 已上报"的记录一并清掉，静默结束后的第一次归零就会被读成"还没报过"。
  /// 两个采样函数因此只在静默期内返回，武装统一收敛到 [armSuppress]。
  void _disarmTriggers() {
    _wasStalled = false;
    _wasEmpty = false;
    _starveSeconds = 0;
    _starveLastReportAt = null;
  }

  /// 进入/推进静默期。任何一次装载（开播、换源、换 P、切换 CDN）以及 seek
  /// 都会让缓冲归零，必须先把这段时间静音掉，否则等长冻结判据会把自己的动作
  /// 读成卡顿。
  void armSuppress() {
    _rebufferSuppressUntil = DateTime.now().add(PlayerTuning.rebufferSuppress);
    _disarmTriggers();
  }

  /// ticker 闸门里"播放器不在正常播放"那一支的复位。
  ///
  /// 刻意**不整套换成** [_disarmTriggers]：它连 [_wasEmpty] 一起清，而暂停正好
  /// 停在一次卡顿中间时，恢复后的第一次归零不该被当成新的一次。[_wasEmpty] 只在
  /// 真正的装载边界和静默期起点重置。
  void relaxTriggers() {
    _wasStalled = false;
    _starveSeconds = 0;
    // 换源后是全新一轮，允许再报一次。
    _starveLastReportAt = null;
  }

  /// 饥饿阈值：mpv 回填水位（`demuxer-hysteresis-secs`）的
  /// [PlayerTuning.starveFloorFraction]。低于 [PlayerTuning.starveMinSeconds] 视为没有观测余量，
  /// 返回 0 表示不启用。
  ///
  /// 取值要从 mpv 真正拿到的 buffer 里读，而不是用当前倍速重算：`buffer` 是
  /// 首次装载时定下的 late final，`setPlaybackSpeed` 不会重建它，两者会不一致
  /// （例如按 1x 装载后改成 2x，水位仍是按 1x 算的，而缓冲消耗速度已翻倍）。
  double get starveThresholdSec {
    final floor =
        double.tryParse(_host.mpvOption('demuxer-hysteresis-secs') ?? '') ?? 0;
    final threshold = floor * PlayerTuning.starveFloorFraction;
    return threshold < PlayerTuning.starveMinSeconds ? 0 : threshold;
  }

  /// 是否已进入片尾 —— 剩余时长不足 [starveThresholdSec]。
  ///
  /// 判据 2（余量归零的上升沿）和判据 3（缓冲饥饿）在片尾都
  /// **必然**成立，跟网速多快无关：余量是 `demuxer-cache-time - position`，而
  /// cache-time 不可能超过文件总长，所以 `余量 <= 剩余时长` 恒成立 —— 播放位置
  /// 一进最后 `threshold` 秒，余量就必定掉到阈值以下并最终归零。片尾也无源可换
  /// （没有剩余数据要下）。
  ///
  /// 实测两次误报都严丝合缝卡在这个边界上：145.403s 的视频从 133s 起计数
  /// （剩余 12.4s）误报 `缓冲饥饿`、@145s 误报 `余量归零`；95.712s 的视频
  /// 分别在 83s（剩余 12.7s）和 @95s 各一次。
  ///
  /// 用 `<` 而不是 `<=`：position / duration 都是整秒，剩余 13s 时余量真的
  /// 低于阈值仍是有效观测，只放过可证明为假的那一档。duration 为 0（直播 /
  /// 时长未知）时返回 false —— 那类流没有片尾。
  bool get _atFileTail {
    final threshold = starveThresholdSec;
    if (threshold <= 0 || _host.durationSecs <= 0) return false;
    return _host.durationSecs - _host.positionSecs < threshold;
  }

  /// 失真阈值：mpv 缓存上限 `cache-secs` 的 [PlayerTuning.divergedFactor] 倍。读不到就
  /// 不启用（返回 0）—— 直播走的是 liveBuffer，压根没有这个键，本地点播
  /// 文件更是 `cache: no`，两者的 `demuxer-cache-time` 语义本来也不同，不该
  /// 套这条判据。跟 [starveThresholdSec] 用"返回 0 表示不启用"是同一套约定。
  double get _divergedAheadSec {
    final cache = double.tryParse(_host.mpvOption('cache-secs') ?? '') ?? 0;
    return cache > 0 ? cache * PlayerTuning.divergedFactor : 0;
  }

  /// 判据 3：只盯余量，不看位置也不要求 [PlaybackWatchdogHost.isBuffering]——换源型卡顿时位置一直
  /// 在推进，core-idle / paused-for-cache 也未必为真。两头都要防：
  /// 余量长期趴在低位是"供不上"，余量涨到 [telemetryDiverged] 是"遥测被音频
  /// 拖走了"，后者正是"只有声音、画面冻住"。
  ///
  /// 每段饥饿只上报一次，直到缓冲真的补回 mpv 自己的水位才算结束；**但那一段
  /// 还没结束时每 [PlayerTuning.starveRepeat] 补报一次**（理由是坏镜像让"结束"永不发生，
  /// 见 [PlayerTuning.starveRepeat]）。
  ///
  /// **片尾必须放行**：余量的上界就是剩余时长，所以视频最后 `threshold` 秒里
  /// 这条判据*必然*成立，跟网速多快无关（推导见 [_atFileTail]）。
  void sampleStarve(DateTime now) {
    final threshold = starveThresholdSec;
    // 静默期内不采样：加载/换源/seek 之后 buffered 本来就是 0。去重状态在
    // 进入静默的那一处就重新武装好了（见 [armSuppress]）。
    if (threshold <= 0 || now.isBefore(_rebufferSuppressUntil)) return;
    // 片尾放行：推导见 [_atFileTail]。归零是为了不让这点残数被 seek 回中段
    // 之后接着用。
    if (_atFileTail) {
      _starveSeconds = 0;
      return;
    }
    if (_host.bufferedAhead < threshold) {
      if (++_starveSeconds < PlayerTuning.starveSeconds) return;
      if (!_starveReportDue(now)) return;
      final repeat = _starveLastReportAt != null;
      _starveLastReportAt = now;
      debugPrint(
        repeat
            ? 'CDN 缓冲饥饿: 仍在饥饿，再次上报（余量 ${_host.bufferedAhead}s < '
                  '${threshold.toStringAsFixed(1)}s）@${_host.positionSecs}s'
            : 'CDN 缓冲饥饿: 前方余量 ${_host.bufferedAhead}s < '
                  '${threshold.toStringAsFixed(1)}s (连续 ${PlayerTuning.starveSeconds} s) '
                  '@${_host.positionSecs}s',
      );
      _host.reportBufferStarve(_host.reportPosition);
      return;
    }
    _starveSeconds = 0;
    // 余量涨到失真：音频在走、画面冻着。`demuxer-cache-time` 被音频轨抬离了
    // 播放位置，余量因此超过缓存上限好几倍 —— 位置还在推进、[PlaybackWatchdogHost.isBuffering]
    // 也是假，判据 1、2 都看不见，只有这里能拦住。同样每段只报一次（可按
    // [PlayerTuning.starveRepeat] 补报，跟上面那条共用一个去重状态）。
    //
    // 出口是 [PlaybackWatchdogHost.reportTelemetryDiverged]，**不是**上面那条
    // 低水位支走的 [PlaybackWatchdogHost.reportBufferStarve]：两副面孔的恢复
    // 手段不同，理由见那个字段。
    if (telemetryDiverged) {
      if (!_starveReportDue(now)) return;
      final repeat = _starveLastReportAt != null;
      _starveLastReportAt = now;
      debugPrint(
        repeat
            ? 'CDN 遥测失真: 仍在失真（余量 ${_host.bufferedAhead}s）'
                  '@${_host.positionSecs}s'
            : 'CDN 遥测失真: 余量 ${_host.bufferedAhead}s 超过缓存上限 '
                  '${_divergedAheadSec.toStringAsFixed(1)}s 的 '
                  '${PlayerTuning.divergedFactor}x (音频在走，画面已冻) @${_host.positionSecs}s',
      );
      _host.reportTelemetryDiverged(_host.reportPosition);
      return;
    }
    // 只有补回 mpv 自己的水位才算这段饥饿真的结束了。
    if (_host.bufferedAhead >= threshold / PlayerTuning.starveFloorFraction) {
      if (_starveLastReportAt != null) {
        debugPrint('CDN 缓冲饥饿: 已恢复 (${_host.bufferedAhead}s)');
      }
      _starveLastReportAt = null;
    }
  }

  /// 该不该就"还在挨饿"这件事再出声一次：没报过，或者距上次已过 [PlayerTuning.starveRepeat]。
  ///
  /// `now.isBefore(last)` 是系统时钟回拨（NTP 校时、用户改表）的护栏：回拨后差值
  /// 恒为负，这段**持续饥饿**的补报会一直不满足，整段盲掉。同文件的
  /// `DecodeLedger` 与页面侧的 `_awaitVideoChainWarm` 都有这条护栏。
  bool _starveReportDue(DateTime now) {
    final last = _starveLastReportAt;
    return last == null ||
        now.isBefore(last) ||
        now.difference(last) >= PlayerTuning.starveRepeat;
  }

  /// 统计"缓冲归零"的上升沿 —— 即加载中转圈出现的次数。
  ///
  /// 必须数上升沿而不是数采样：`buffered` 每次 stream.buffer 推送都会重写，
  /// 一秒内可能变几十次，数零值会把一次卡顿记成几十次。
  void sampleRebuffer(DateTime now) {
    if (now.isBefore(_rebufferSuppressUntil)) return;
    // 片尾放行：推导见 [_atFileTail]。这里余量归零是必然而非故障，不放过的话
    // 每个视频的最后一秒都会误报一次"小卡顿"。_wasEmpty 不动 —— 片尾之外
    // 余量一涨回就会把它清掉，向后 seek 之后自然重新武装。
    if (_atFileTail) return;

    // 最敏感的一条：余量归零的上升沿立刻上报，不等 isBuffering、不等攒够次数。
    // 每一次归零只报一次，补回来才重新武装。
    if (_host.bufferedAhead == 0) {
      if (!_wasEmpty) {
        _wasEmpty = true;
        debugPrint('CDN 余量归零 @${_host.positionSecs}s，上报小卡顿');
        _host.reportRebuffer(_host.reportPosition);
      }
    } else {
      _wasEmpty = false;
    }

    final stalled = _host.isBuffering && _host.bufferedAhead == 0;
    if (stalled && !_wasStalled) {
      _rebufferEvents.add(now);
      // 未来时刻也要清：时钟回拨后它们与 `now` 的差值是负的，用 `>` 永远淘汰
      // 不掉，回拨后的第三个上升沿会把旧账一起算进这一次卡顿。
      _rebufferEvents.removeWhere(
        (t) =>
            t.isAfter(now) || now.difference(t) > PlayerTuning.rebufferWindow,
      );
      debugPrint(
        'CDN 卡顿计数: ${_rebufferEvents.length}/${PlayerTuning.rebufferTrigger} '
        '(窗口 ${PlayerTuning.rebufferWindow.inSeconds}s)',
      );
      if (_rebufferEvents.length >= PlayerTuning.rebufferTrigger) {
        _rebufferEvents.clear();
        _host.reportStall(_host.reportPosition);
      }
    }
    _wasStalled = stalled;
  }
}
