import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show debugPrint;

class AudioSessionHandler {
  late AudioSession session;
  late final Future<void> _ready;
  bool _playInterrupted = false;

  /// 播放期间盯住会话选项的定时器，见 [startNowPlayingGuard]。
  Timer? _mixGuard;

  /// 播放期间守住「独占」的音频会话。
  ///
  /// media_kit 内置的 mpv 在每次启动音频输出时都会把会话重设成
  /// `playback + mixWithOthers`。**带混音选项的会话不会被 iOS 选为
  /// 「正在播放」**，锁屏、控制中心、灵动岛上的播放器就整个不出现
  /// （2026-10-21 真机定位：把选项改回独占的同一秒卡片出现，mpv 下次
  /// 起播又改回混音时卡片跟着消失）。
  ///
  /// 这里每秒看一眼实际选项，真被改坏了才重新配置 —— 只在需要时动手，
  /// 免得反复 setCategory 白白打断声音。
  void startNowPlayingGuard() {
    if (!Platform.isIOS || _mixGuard != null) return;
    _mixGuard = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _assertExclusive(),
    );
  }

  /// 暂停/销毁时停下。mpv 只在起音频输出那一刻改会话，暂停期间不用盯。
  void stopNowPlayingGuard() {
    _mixGuard?.cancel();
    _mixGuard = null;
  }

  Future<void> _assertExclusive() async {
    if (_mixGuard == null) return;
    try {
      await _ready;
      final av = AVAudioSession();
      final options = await av.categoryOptions;
      final category = await av.category;
      if (_mixGuard == null) return;
      if (options.contains(AVAudioSessionCategoryOptions.mixWithOthers) ||
          category != AVAudioSessionCategory.playback) {
        await session.configure(const AudioSessionConfiguration.music());
        debugPrint('[锁屏控制] mpv 把会话改回了混音，已重新钉成独占');
      }
      // mpv 每重建一次音频输出，就会先把会话 deactivate 再 activate。回主页后
      // 它重建时如果没把我们重新激活，iOS 就不再把我们当选「正在播放」——
      // 卡片直接换成上一个播放器（真机 2026-10-21：回主页几秒后变苹果音乐）。
      // 激活是幂等的，活动期间每拍都确认一次。
      final active = await session.setActive(true);
      if (!active) debugPrint('[锁屏控制] 会话重新激活失败');
      // 2026-10-21 实验结论：后台每 3 秒做一次完整「重新认领」（钉会话 +
      // 重写 Now Playing + 拿回遥控）**抢不回卡片** —— 系统一旦把「正在播放」
      // 交给别的 App 就不会还。所以不再自动 reclaim，改从根上避免断音
      // （后台推迟解码器重建，见 PlPlayerController._deferredDecoderRebuild）。
    } catch (_) {
      // 取不到选项就等下一拍，不能影响播放。
    }
  }

  Future<bool> setActive(bool active) async {
    // 构造是同步的、initSession 是异步的；不等它就可能撞上 `late session`。
    await _ready;
    try {
      return await session.setActive(active);
    } catch (e) {
      if (Platform.isIOS) debugPrint('[锁屏控制] setActive($active) 失败: $e');
      rethrow;
    }
  }

  AudioSessionHandler() {
    _ready = initSession();
  }

  Future<void> initSession() async {
    session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    session.interruptionEventStream.listen((event) {
      final playerStatus = PlPlayerController.getPlayerStatusIfExists();
      // final player = PlPlayerController.getInstance();
      if (event.begin) {
        if (playerStatus != PlayerStatus.playing) return;
        // if (!player.playerStatus.playing) return;
        switch (event.type) {
          case AudioInterruptionType.duck:
            PlPlayerController.setVolumeIfExists(
              (PlPlayerController.getVolumeIfExists() ?? 0) * 0.5,
              showIndicator: false,
            );
            // player.setVolume(player.volume.value * 0.5);
            break;
          case AudioInterruptionType.pause:
            PlPlayerController.pauseIfExists(isInterrupt: true);
            // player.pause(isInterrupt: true);
            _playInterrupted = true;
            break;
          case AudioInterruptionType.unknown:
            PlPlayerController.pauseIfExists(isInterrupt: true);
            // player.pause(isInterrupt: true);
            _playInterrupted = true;
            break;
        }
      } else {
        switch (event.type) {
          case AudioInterruptionType.duck:
            PlPlayerController.setVolumeIfExists(
              (PlPlayerController.getVolumeIfExists() ?? 0) * 2,
              showIndicator: false,
            );
            // player.setVolume(player.volume.value * 2);
            break;
          case AudioInterruptionType.pause:
            if (_playInterrupted) PlPlayerController.playIfExists();
            //player.play();
            break;
          case AudioInterruptionType.unknown:
            break;
        }
        _playInterrupted = false;
      }
    });

    // 耳机拔出暂停
    session.becomingNoisyEventStream.listen((_) {
      PlPlayerController.pauseIfExists();
      // final player = PlPlayerController.getInstance();
      // if (player.playerStatus.playing) {
      //   player.pause();
      // }
    });
  }
}
