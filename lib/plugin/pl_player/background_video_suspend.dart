/// iOS 后台播放省电：进后台一段时间后把视频轨关掉（`file-local-options/vid=no`），
/// 只留音频。这里放**后台相关的判据**（能不能关、回前台补不补重建、算不算后台
/// 过渡期），动作与定时器在 [PlPlayerController] 里（照 `reload_strategy.dart`
/// 的分法：判据纯函数、可单测）。
///
/// 为什么是关视频轨而不是别的：`vid=no` 之后 mpv 不再产帧，
/// `VideoOutput.updateCallback` 也就不再被调用 —— 视频解码和 GPU 纹理渲染一起停，
/// 而音频输出、Flutter texture、系统「正在播放」都不受影响。`open()` / `stop()`
/// 会拆 `ao_audiounit`，iOS 在这一下就把锁屏卡片交给别的 App（见
/// `reload_strategy.dart` 的注释），所以不能走那条路。
library;

import 'dart:ui' show AppLifecycleState;

/// 回前台时 iOS 会先发一个 `hidden`：这一个是**过渡**，不是又一次进后台。
///
/// Flutter 把生命周期摆成一条链：往后台走是 `inactive → hidden → paused`，
/// 回前台是 `paused → hidden → inactive → resumed` —— `hidden` 两头都有。
/// 把回来那一侧的 `hidden` 当成"又进后台"，会拿**上一段后台会话**的起点去算
/// 等待时间（早就是 0 秒），于是解锁那一刻就排一个 0 秒定时器；用户若在锁屏上
/// 按过播放键，它会赶在紧随其后的 `inactive` 之前把视频轨关掉，`resumed` 再恢复
/// 一次 —— 白付一次 refresh seek。2026-10-22 00:07:28 真机就打出过
/// 「进入后台，0s 后关闭视频轨」，只是那次 `inactive` 快 1 毫秒、抢在定时器前面
/// 取消了。往后台走时 `hidden` 前面是 `inactive`，回来时前面才是 `paused`。
bool isForegroundTransitionHidden(AppLifecycleState? previous) =>
    previous == AppLifecycleState.paused;

/// 回前台时要不要**补一次解码链重建**（`hwdec` 重开 + seek 回原位）。
///
/// iOS 退后台会把 VideoToolbox 的解压会话作废。后台省电那条路只在**视频轨真被关掉**
/// 时顺带重建（`vid=auto` 的 refresh seek）；而暂停着退后台时轨不会关，回前台就没有
/// 任何东西重建它，死的会话一直留到用户按下播放 —— 2026-10-22 00:59 真机：
/// 回前台 2.7 秒后点播放，`invalid session` ×1 + `HW accel end frame fail` **99 行**
/// （30 行/秒，横跨 3.3 秒），画面在坏帧之间来回切。详见 [[background-video-suspend]]。
///
/// 只在**暂停态**补：暂停时没有音频输出，refresh seek 不产生 underrun，缓冲在用户
/// 点播放前就补回来了。播放态退后台时 mpv 当场就会刷 `invalid session`（同一份日志
/// 00:48:49，进后台 1.5 秒后），那种交给解码错误看门狗当场重建，不必在这里猜时长。
bool shouldReinitDecoderOnResume({
  required bool backgroundPlay,
  required bool enteredBackground,
  required bool playing,
  required bool isLive,
  required bool onlyPlayAudio,
  required bool pipActive,
}) =>
    backgroundPlay &&
    enteredBackground &&
    !playing &&
    !isLive &&
    !onlyPlayAudio &&
    !pipActive;

/// 现在是不是「后台解码过渡期」：后台会话进行中，或刚从一个**真实后台会话**回来。
///
/// 这个窗口只管一件事：让会话族**回声**单独也算数（见
/// `PlayerTuning.sessionFailTransitionWindow`）。2026-10-22 12:18 真机，播放中
/// 秒退秒回，iOS 作废 VideoToolbox 会话，mpv 只吐 65 行通用回声、零种子，
/// 旧判据一条都数不到。
///
/// [backgroundStartedAt] 由 `_onBackgroundForVideoTrack` 在省电/画中画那几道门
/// **之前**置上 —— 那几道门只决定"要不要关视频轨"，而会话作废与它们无关。
/// 所以"在后台"必须以它为证：单看 [inBackground] 的话，测试注入
/// （`debugForceAppInBackground`）和"根本没走过 iOS 生命周期"的状态也会开窗。
///
/// [backgroundExitedAt] 由 `_onForegroundForVideoTrack` 在
/// `enteredBackground == true` 时置上；控制中心那种 `inactive → resumed` 往返
/// 没有真进过后台，不会开窗。
///
/// 时钟回拨（`now` 早于 [backgroundExitedAt]）按"不在窗内"处理 —— 与
/// `_inForegroundResumeWindow` 同口径：差值没法判断，宁可少算这一窗。
bool inBackgroundTransitionWindow({
  required bool inBackground,
  required DateTime now,
  required DateTime? backgroundStartedAt,
  required DateTime? backgroundExitedAt,
  required Duration afterResume,
}) {
  if (inBackground) return backgroundStartedAt != null;
  if (backgroundExitedAt == null || now.isBefore(backgroundExitedAt)) {
    return false;
  }
  return now.difference(backgroundExitedAt) < afterResume;
}

/// 为什么这一轮不能关视频轨。`null` 表示可以关。
enum BackgroundVideoSuspendBlocker {
  noPlayer('播放器不存在'),
  live('直播'),
  onlyPlayAudio('听视频'),
  noVideoTrack('没有视频轨'),
  alreadyOff('视频轨已关闭'),
  loading('装载在途'),
  rebuilding('渲染重建中'),
  seeking('seek 中'),
  completed('已播完'),
  notSeekable('流不可 seek'),
  paused('暂停中');

  const BackgroundVideoSuspendBlocker(this.label);

  final String label;

  /// 过一会儿再看就有答案的：装载 / seek / 重建都会自己结束。
  bool get retryable =>
      this == loading || this == rebuilding || this == seeking;

  /// 暂停态：关轨没有省电收益（mpv 本来就不产帧），等真正播放起来再关。
  bool get waitForPlayback => this == paused;
}

/// 现在能不能把视频轨关掉。判据全部由调用方给出，方便单测摆时序。
///
/// 顺序是有意义的：先排掉「本来就不该关」的终端态，再排「现在别动」的时序态，
/// 最后才是暂停。`alreadyOff` 排在时序态之前 —— 已经关了就不必等装载结束。
BackgroundVideoSuspendBlocker? checkBackgroundVideoSuspend({
  required bool hasPlayer,
  required bool isLive,
  required bool onlyPlayAudio,
  required bool playing,
  required bool processing,
  required bool rebuildingRenderContext,
  required bool seeking,
  required bool completed,
  required bool seekable,
  required Duration duration,
  required int videoTrackCount,
  required String selectedVideoTrackId,
}) {
  if (!hasPlayer) return BackgroundVideoSuspendBlocker.noPlayer;
  if (isLive) return BackgroundVideoSuspendBlocker.live;
  // 用户自己选了听视频：切轨由 `file-local-options/vid` 管着，别去覆盖。
  if (onlyPlayAudio) return BackgroundVideoSuspendBlocker.onlyPlayAudio;
  // media_kit 的 `tracks.video` 恒含 auto / no 两条合成项。
  if (videoTrackCount <= 2) return BackgroundVideoSuspendBlocker.noVideoTrack;
  if (selectedVideoTrackId == 'no') {
    return BackgroundVideoSuspendBlocker.alreadyOff;
  }
  if (processing) return BackgroundVideoSuspendBlocker.loading;
  if (rebuildingRenderContext) {
    return BackgroundVideoSuspendBlocker.rebuilding;
  }
  if (seeking) return BackgroundVideoSuspendBlocker.seeking;
  if (completed) return BackgroundVideoSuspendBlocker.completed;
  // 恢复 `vid=auto` 会让 mpv 从关键帧重开视频链（refresh seek）。不可 seek 的
  // 流上实测位置 14.1s → 10.0s，还带一声 underrun 爆音（2026-10-15 墓碑）。
  // 播完的流和这类流一样：宁可不少这个电。
  if (!seekable || duration <= Duration.zero) {
    return BackgroundVideoSuspendBlocker.notSeekable;
  }
  if (!playing) return BackgroundVideoSuspendBlocker.paused;
  return null;
}
