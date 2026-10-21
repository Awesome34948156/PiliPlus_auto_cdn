import 'package:PiliPlus/plugin/pl_player/reload_strategy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

/// 原地换流的**判据**真值表。
///
/// 为什么只测这一片：真正调用 `replaceSingle` 需要 libmpv（`Player.create` 在
/// 测试进程里起不来），而它到底有没有保住音频输出**只能真机看日志**（判据：
/// 换流后不再出现新的 `ao/audiounit: requested format`）。这里能锁住的是
/// 「什么时候允许走这条路」与「回落语义」—— 一旦有人把 `!isLive`、`!completed`
/// 或 `playlistLength == 1` 删掉，本文件立刻变红。
void main() {
  group('canReloadInPlace', () {
    bool allow({
      bool isIOS = true,
      bool isLive = false,
      bool isNetworkSource = true,
      int playlistLength = 1,
      bool completed = false,
    }) => canReloadInPlace(
      isIOS: isIOS,
      isLive: isLive,
      isNetworkSource: isNetworkSource,
      playlistLength: playlistLength,
      completed: completed,
    );

    test('iOS 点播网络源、播放列表只有当前这条 —— 允许', () {
      expect(allow(), isTrue);
    });

    test('非 iOS 一律不走（Android/桌面行为逐字不变）', () {
      expect(allow(isIOS: false), isFalse);
    });

    test('直播不碰：切流行为没验证过', () {
      expect(allow(isLive: true), isFalse);
    });

    test('文件源没有这个账要算', () {
      expect(allow(isNetworkSource: false), isFalse);
    });

    test('播放列表不是恰好 1 条：replaceSingle 的 assert 会炸', () {
      expect(allow(playlistLength: 0), isFalse);
      expect(allow(playlistLength: 2), isFalse);
    });

    test('已播完时不走：Player.play() 会当成重播，把 start= 覆盖掉', () {
      expect(allow(completed: true), isFalse);
    });
  });

  group('resumeMedia', () {
    const current = Media(
      'https://example.com/a.m4s',
      extras: {'cache': 'yes', 'cache-secs': '32.000'},
      start: Duration.zero,
    );

    test('uri 与 extras 原样保留，只把起点换成本次位置', () {
      final media = resumeMedia(
        current: current,
        position: const Duration(seconds: 1237),
        isLive: false,
      );
      expect(media.uri, current.uri);
      expect(media.extras, current.extras);
      expect(media.start, const Duration(seconds: 1237));
    });

    test('位置是 0 也要写进去（不能落回旧 start）', () {
      final media = resumeMedia(
        current: const Media(
          'https://example.com/a.m4s',
          start: Duration(seconds: 9),
        ),
        position: Duration.zero,
        isLive: false,
      );
      expect(media.start, Duration.zero);
    });

    test('直播不动起点：原样返回同一条 Media', () {
      expect(
        identical(
          resumeMedia(
            current: current,
            position: const Duration(seconds: 5),
            isLive: true,
          ),
          current,
        ),
        isTrue,
      );
    });
  });

  group('tryInPlaceReload', () {
    test('判据不允许时连试都不试，返回 false 让调用方回落 open()', () async {
      var called = false;
      final used = await tryInPlaceReload(
        allowed: false,
        replace: () async {
          called = true;
        },
      );
      expect(used, isFalse);
      expect(called, isFalse);
    });

    test('替换成功返回 true', () async {
      var called = false;
      final used = await tryInPlaceReload(
        allowed: true,
        replace: () async {
          called = true;
        },
      );
      expect(used, isTrue);
      expect(called, isTrue);
    });

    test('替换自己抛了（disposed / assert）不往上炸，返回 false 并回报', () async {
      Object? reported;
      final used = await tryInPlaceReload(
        allowed: true,
        replace: () async => throw StateError('player disposed'),
        onReplaceError: (error, _) => reported = error,
      );
      expect(used, isFalse);
      expect(reported, isA<StateError>());
    });
  });
}
