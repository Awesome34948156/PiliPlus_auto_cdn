import 'package:media_kit/media_kit.dart';

/// 重载能不能**不走** `Player.open()`、直接原地替换当前那条 Media。
///
/// `open()` 进来第一件事是 `stop` + `playlist-clear` + `playlist-play-index none`
/// （fork 的 `native/player/real.dart`），mpv 因此拆掉 `ao_audiounit`；它的
/// `uninit()` 会调 `AVAudioSession setActive:NO`，iOS 就在这一下把系统「正在播放」
/// 交给别的 App，声音回来卡片也回不来（详见 `lib/services/audio_session.dart`）。
/// fork 另有一条 `NativePlayer.replaceSingle`：append → 跳 → 删旧的，不 stop、
/// 不 clear，走的是 mpv 正常的「播放下一条」路径，`--gapless-audio` 生效时
/// 音频输出原地复用（`player/audio.c`：`gapless_audio > 0` 直接复用现有 ao）。
///
/// 只在 iOS 开：这是「保灵动岛」的专用办法，别的平台没有这个账要算。
/// 直播也先排除：切流行为没在这个改动里验证过，别把实时流一起卷进来。
bool canReloadInPlace({
  required bool isIOS,
  required bool isLive,
  required bool isNetworkSource,
  required int playlistLength,
  required bool completed,
}) =>
    isIOS &&
    !isLive &&
    isNetworkSource &&
    // `replaceSingle` 自己 `assert(current.length == 1)`；这里先当运行时判据，
    // 数量不对就老老实实走 open()，别拿 assert 赌。
    playlistLength == 1 &&
    // 已播完时 `Player.play()` 会当成「重播」：seek 0 并把 playlist 拉回第 0 条，
    // 把新 Media 的 `start=` 覆盖掉。这种边界交给 open()。
    !completed;

/// [PlPlayerController.refreshPlayer] 重开当前条目时用的 Media：保留 uri/extras
/// （headers / cache / demuxer 参数都在 extras 里），只把起点换成本次位置。
Media resumeMedia({
  required Media current,
  required Duration position,
  required bool isLive,
}) => isLive ? current : current.copyWith(start: position);

/// 先试原地替换，不行返回 false 由调用方回落 `open()`。
///
/// media_kit 的 `command`/`_setProperty` **不会因为 mpv 返回错误码而抛异常**
/// （错误走 `stream.error`，仍由既有恢复链处理），所以这里的 catch 只兜
/// 「播放器已销毁」与 `replaceSingle` 的 assert 这类同步失败。
Future<bool> tryInPlaceReload({
  required bool allowed,
  required Future<void> Function() replace,
  void Function(Object error, StackTrace stack)? onReplaceError,
}) async {
  if (!allowed) return false;
  try {
    await replace();
    return true;
  } catch (error, stack) {
    onReplaceError?.call(error, stack);
    return false;
  }
}
