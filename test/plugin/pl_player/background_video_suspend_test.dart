import 'dart:ui' show AppLifecycleState;

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

  group('hidden 辨方向', () {
    // 往后台：inactive → hidden → paused；回前台：paused → hidden → inactive。
    test('紧跟在 paused 后面的 hidden 是回前台过渡', () {
      expect(isForegroundTransitionHidden(AppLifecycleState.paused), isTrue);
    });

    test('往后台那个 hidden 前面是 inactive，照常算进后台', () {
      expect(isForegroundTransitionHidden(AppLifecycleState.inactive), isFalse);
      expect(isForegroundTransitionHidden(AppLifecycleState.resumed), isFalse);
      expect(isForegroundTransitionHidden(null), isFalse);
    });
  });

  group('回前台补重建解码链', () {
    // 2026-10-22 00:59 真机那一场：暂停着退后台 → 视频轨没关 → 回前台什么都不做
    // → 点播放时 `invalid session` ×1 + `HW accel end frame fail` 99 行、闪 3.3 秒。
    bool resume({
      bool backgroundPlay = true,
      bool enteredBackground = true,
      bool playing = false,
      bool isLive = false,
      bool onlyPlayAudio = false,
      bool pipActive = false,
    }) => shouldReinitDecoderOnResume(
      backgroundPlay: backgroundPlay,
      enteredBackground: enteredBackground,
      playing: playing,
      isLive: isLive,
      onlyPlayAudio: onlyPlayAudio,
      pipActive: pipActive,
    );

    test('暂停着退过后台、没人重建过视频链 —— 要补', () {
      expect(resume(), isTrue);
    });

    test('播放中不动：拨 hwdec 要断音 1.5 秒，那种交给解码看门狗当场重建', () {
      expect(resume(playing: true), isFalse);
    });

    test('这一趟没进过后台（只是 inactive / 启动）不动', () {
      expect(resume(enteredBackground: false), isFalse);
    });

    test('后台播放关着不动：view 那条路已经在做同一件事，别重复', () {
      expect(resume(backgroundPlay: false), isFalse);
    });

    test('直播 / 听视频 / 画中画都不动', () {
      expect(resume(isLive: true), isFalse);
      expect(resume(onlyPlayAudio: true), isFalse);
      expect(resume(pipActive: true), isFalse);
    });
    // 视频轨真被关过的那一趟不走这条判据 —— 调用点
    // （`_onForegroundForVideoTrack`）只在 `!_videoSuspendedForBackground` 分支
    // 才问它，那条路的 `vid=auto` refresh seek 已经重建了解码链。
  });
}
