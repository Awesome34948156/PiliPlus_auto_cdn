/// 回前台恢复播放的时序外壳。
///
/// iOS 从后台回来时，必须先让解码链重建完成，再根据最新现场决定是否续播。
/// 这两步分开写在 UI 回调里时，先发起的 `play` 可能排在补重建的 `pause` 前面，
/// 最后反而把用户刚恢复的播放又按停。
///
/// 只表达时序、不持有播放器状态，便于用 Completer 单测证明“重建完成前绝不
/// 续播”，也避免继续把生命周期判断塞进播放器视图。
Future<bool> reinitThenResumePlayback({
  required Future<void> Function() reinit,
  required bool Function() canResume,
  required Future<void> Function() resume,
}) async {
  await reinit();
  if (!canResume()) return false;
  await resume();
  return true;
}
