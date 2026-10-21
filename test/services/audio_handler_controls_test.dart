import 'package:PiliPlus/services/audio_handler.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<MediaAction> actions({
    required bool playing,
    required bool isLive,
    required bool canSkipPrevious,
    required bool canSkipNext,
  }) {
    return buildMediaControls(
      playing: playing,
      isLive: isLive,
      canSkipPrevious: canSkipPrevious,
      canSkipNext: canSkipNext,
    ).map((e) => e.action).toList();
  }

  test('非 iOS 形态（无 skip）与改动前逐项一致', () {
    expect(
      actions(
        playing: true,
        isLive: false,
        canSkipPrevious: false,
        canSkipNext: false,
      ),
      [MediaAction.rewind, MediaAction.pause, MediaAction.fastForward],
    );
    expect(
      actions(
        playing: false,
        isLive: false,
        canSkipPrevious: false,
        canSkipNext: false,
      ),
      [MediaAction.rewind, MediaAction.play, MediaAction.fastForward],
    );
  });

  test('点播且前后都有内容：两侧都出现 skip', () {
    expect(
      actions(
        playing: true,
        isLive: false,
        canSkipPrevious: true,
        canSkipNext: true,
      ),
      [
        MediaAction.skipToPrevious,
        MediaAction.rewind,
        MediaAction.pause,
        MediaAction.fastForward,
        MediaAction.skipToNext,
      ],
    );
  });

  test('只有一侧有内容时只显示那一侧', () {
    expect(
      actions(
        playing: true,
        isLive: false,
        canSkipPrevious: false,
        canSkipNext: true,
      ),
      [
        MediaAction.rewind,
        MediaAction.pause,
        MediaAction.fastForward,
        MediaAction.skipToNext,
      ],
    );
    expect(
      actions(
        playing: false,
        isLive: false,
        canSkipPrevious: true,
        canSkipNext: false,
      ),
      [
        MediaAction.skipToPrevious,
        MediaAction.rewind,
        MediaAction.play,
        MediaAction.fastForward,
      ],
    );
  });

  test('直播只有播放/暂停', () {
    expect(
      actions(
        playing: true,
        isLive: true,
        canSkipPrevious: true,
        canSkipNext: true,
      ),
      [MediaAction.pause],
    );
    expect(
      actions(
        playing: false,
        isLive: true,
        canSkipPrevious: true,
        canSkipNext: true,
      ),
      [MediaAction.play],
    );
  });
}
