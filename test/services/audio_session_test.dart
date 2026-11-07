import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/audio_session.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAudioSessionPort implements AudioSessionPort {
  final interruptionController =
      StreamController<AudioInterruptionEvent>.broadcast();
  final noisyController = StreamController<void>.broadcast();

  Completer<void>? categoryOptionsGate;
  AVAudioSessionCategory categoryValue = AVAudioSessionCategory.playback;
  AVAudioSessionCategoryOptions optionsValue =
      AVAudioSessionCategoryOptions.none;
  int configureCalls = 0;
  final List<bool> activeCalls = [];
  final List<AVAudioSessionSetActiveOptions?> activeOptions = [];

  @override
  Future<void> get ready async {}

  @override
  Future<AVAudioSessionCategory> get category async => categoryValue;

  @override
  Future<AVAudioSessionCategoryOptions> get categoryOptions async {
    await categoryOptionsGate?.future;
    return optionsValue;
  }

  @override
  Stream<AudioInterruptionEvent> get interruptionEvents =>
      interruptionController.stream;

  @override
  Stream<void> get becomingNoisyEvents => noisyController.stream;

  @override
  Future<void> configureMusic() async {
    configureCalls++;
  }

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
  }) async {
    activeCalls.add(active);
    activeOptions.add(avAudioSessionSetActiveOptions);
    return true;
  }

  Future<void> close() async {
    await interruptionController.close();
    await noisyController.close();
  }
}

class _FakeInterruptionActions implements AudioInterruptionActions {
  @override
  PlayerStatus? playerStatus = PlayerStatus.paused;

  int duckDownCalls = 0;
  int duckUpCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int noisyCalls = 0;

  @override
  void duckVolume(bool down) {
    if (down) {
      duckDownCalls++;
    } else {
      duckUpCalls++;
    }
  }

  @override
  void pauseAsInterruption() {
    pauseCalls++;
    playerStatus = PlayerStatus.paused;
  }

  @override
  void resumeAfterInterruption() {
    resumeCalls++;
    playerStatus = PlayerStatus.playing;
  }

  @override
  void pauseForNoisyRoute() {
    noisyCalls++;
    playerStatus = PlayerStatus.paused;
  }
}

void main() {
  testWidgets('中断发生在守卫检查途中时，旧检查不得重新激活会话', (tester) async {
    final port = _FakeAudioSessionPort()
      ..categoryOptionsGate = Completer<void>();
    final actions = _FakeInterruptionActions();
    final handler = AudioSessionHandler(
      port: port,
      actions: actions,
      isIOS: true,
    );
    final holder = Object();

    await tester.pump();
    handler.startNowPlayingGuard(holder);
    await tester.pump(const Duration(seconds: 1));

    port.interruptionController.add(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    await tester.pump();
    port.categoryOptionsGate!.complete();
    await tester.pump();

    expect(port.activeCalls.where((active) => active), isEmpty);
    expect(
      port.activeOptions.where(
        (option) =>
            option == AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
      ),
      isNotEmpty,
    );

    handler.stopNowPlayingGuard(holder);
    await port.close();
  });

  testWidgets('暂停宽限状态被中断时只让出会话，不拉起视频', (tester) async {
    final port = _FakeAudioSessionPort();
    final actions = _FakeInterruptionActions();
    AudioSessionHandler(
      port: port,
      actions: actions,
      isIOS: true,
    );

    await tester.pump();
    port.interruptionController.add(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    await tester.pump();
    port.interruptionController.add(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await tester.pump(const Duration(seconds: 2));

    expect(actions.pauseCalls, 0);
    expect(actions.resumeCalls, 0);
    expect(port.activeCalls.where((active) => active), isEmpty);
    expect(
      port.activeCalls.where((active) => !active),
      isNotEmpty,
    );

    await port.close();
  });

  testWidgets('播放中被中断会暂停，结束后恢复既有续播和守卫路径', (tester) async {
    final port = _FakeAudioSessionPort();
    final actions = _FakeInterruptionActions()
      ..playerStatus = PlayerStatus.playing;
    final handler = AudioSessionHandler(
      port: port,
      actions: actions,
      isIOS: true,
    );
    final holder = Object();

    await tester.pump();
    handler.startNowPlayingGuard(holder);
    await tester.pump(const Duration(seconds: 1));
    expect(port.activeCalls.where((active) => active), isNotEmpty);

    port.interruptionController.add(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    await tester.pump();
    // 真实播放器的 stream.playing=false 会同步摘掉守卫持有者。
    handler.stopNowPlayingGuard(holder);

    expect(actions.pauseCalls, 1);
    expect(actions.resumeCalls, 0);

    port.interruptionController.add(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await tester.pump();

    expect(actions.resumeCalls, 1);

    // 续播后的 stream.playing=true 会重新登记这个持有者。
    handler.startNowPlayingGuard(holder);
    await tester.pump(const Duration(seconds: 1));
    expect(port.activeCalls.where((active) => active).length, greaterThan(1));

    handler.stopNowPlayingGuard(holder);
    await port.close();
  });
}
