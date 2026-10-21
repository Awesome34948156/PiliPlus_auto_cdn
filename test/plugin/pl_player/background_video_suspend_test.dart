import 'package:PiliPlus/plugin/pl_player/background_video_suspend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 全部门都放开的基线；每条用例只改它关心的那几项。
  BackgroundVideoSuspendBlocker? check({
    bool hasPlayer = true,
    bool isLive = false,
    bool onlyPlayAudio = false,
    bool playing = true,
    bool processing = false,
    bool rebuildingRenderContext = false,
    bool seeking = false,
    bool completed = false,
    bool seekable = true,
    Duration duration = const Duration(minutes: 5),
    int videoTrackCount = 3,
    String selectedVideoTrackId = 'auto',
  }) => checkBackgroundVideoSuspend(
    hasPlayer: hasPlayer,
    isLive: isLive,
    onlyPlayAudio: onlyPlayAudio,
    playing: playing,
    processing: processing,
    rebuildingRenderContext: rebuildingRenderContext,
    seeking: seeking,
    completed: completed,
    seekable: seekable,
    duration: duration,
    videoTrackCount: videoTrackCount,
    selectedVideoTrackId: selectedVideoTrackId,
  );

  test('全部门放开时可以关', () {
    expect(check(), isNull);
  });

  test('播放器不存在', () {
    expect(check(hasPlayer: false), BackgroundVideoSuspendBlocker.noPlayer);
  });

  test('直播不动', () {
    expect(check(isLive: true), BackgroundVideoSuspendBlocker.live);
  });

  test('听视频优先于其它时序态：用户的选择不能被覆盖', () {
    expect(
      check(onlyPlayAudio: true, processing: true, seeking: true),
      BackgroundVideoSuspendBlocker.onlyPlayAudio,
    );
  });

  test('没有真实视频轨（只剩 auto / no 两条合成项）', () {
    expect(
      check(videoTrackCount: 2),
      BackgroundVideoSuspendBlocker.noVideoTrack,
    );
  });

  test('已经关掉了：不必等装载结束', () {
    expect(
      check(selectedVideoTrackId: 'no', processing: true),
      BackgroundVideoSuspendBlocker.alreadyOff,
    );
  });

  test('装载 / seek / 重建在途：过一会儿再试', () {
    final cases = {
      BackgroundVideoSuspendBlocker.loading: check(processing: true),
      BackgroundVideoSuspendBlocker.seeking: check(seeking: true),
      BackgroundVideoSuspendBlocker.rebuilding: check(
        rebuildingRenderContext: true,
      ),
    };
    for (final MapEntry(key: expected, value: actual) in cases.entries) {
      expect(actual, expected);
      expect(actual!.retryable, isTrue, reason: '$expected 应该可重试');
    }
  });

  test('已播完', () {
    const completed = BackgroundVideoSuspendBlocker.completed;
    expect(check(completed: true), completed);
    expect(completed.retryable, isFalse, reason: '播完了不会自己变回来，重试没有意义');
  });

  test('不可 seek / 时长未知：恢复会位置倒退 + 爆音，宁可不省', () {
    const notSeekable = BackgroundVideoSuspendBlocker.notSeekable;
    expect(check(seekable: false), notSeekable);
    expect(check(duration: Duration.zero), notSeekable);
    expect(notSeekable.retryable, isFalse);
  });

  test('暂停中：等真正播放起来再关', () {
    final blocker = check(playing: false);
    expect(blocker, BackgroundVideoSuspendBlocker.paused);
    expect(blocker!.waitForPlayback, isTrue);
    expect(blocker.retryable, isFalse);
  });
}
