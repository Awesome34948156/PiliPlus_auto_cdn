/// iOS 后台播放省电：进后台一段时间后把视频轨关掉（`file-local-options/vid=no`），
/// 只留音频。这里只放**能不能关**的判据，动作与定时器在
/// [PlPlayerController] 里（照 `reload_strategy.dart` 的分法：判据纯函数、可单测）。
///
/// 为什么是关视频轨而不是别的：`vid=no` 之后 mpv 不再产帧，
/// `VideoOutput.updateCallback` 也就不再被调用 —— 视频解码和 GPU 纹理渲染一起停，
/// 而音频输出、Flutter texture、系统「正在播放」都不受影响。`open()` / `stop()`
/// 会拆 `ao_audiounit`，iOS 在这一下就把锁屏卡片交给别的 App（见
/// `reload_strategy.dart` 的注释），所以不能走那条路。
library;

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
