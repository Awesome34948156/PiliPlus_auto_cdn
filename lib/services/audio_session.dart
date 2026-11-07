import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/now_playing_guard.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;

/// The audio-session operations used by [AudioSessionHandler].
///
/// Production uses the `audio_session` plugin. Tests inject a fake without
/// initializing platform channels or waiting for real audio hardware.
abstract interface class AudioSessionPort {
  Future<void> get ready;

  Future<AVAudioSessionCategory> get category;

  Future<AVAudioSessionCategoryOptions> get categoryOptions;

  Stream<AudioInterruptionEvent> get interruptionEvents;

  Stream<void> get becomingNoisyEvents;

  Future<void> configureMusic();

  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
  });
}

/// Player actions needed while handling an audio interruption.
///
/// Kept behind a small interface so the interruption ordering can be tested
/// without constructing the global video player controller.
abstract interface class AudioInterruptionActions {
  PlayerStatus? get playerStatus;

  void duckVolume(bool down);

  void pauseAsInterruption();

  void resumeAfterInterruption();

  void pauseForNoisyRoute();
}

class _PluginAudioSessionPort implements AudioSessionPort {
  late final Future<AudioSession> _session = AudioSession.instance;

  @override
  Future<void> get ready async {
    await _session;
  }

  @override
  Future<AVAudioSessionCategory> get category => AVAudioSession().category;

  @override
  Future<AVAudioSessionCategoryOptions> get categoryOptions =>
      AVAudioSession().categoryOptions;

  @override
  Stream<AudioInterruptionEvent> get interruptionEvents =>
      Stream.fromFuture(_session).asyncExpand(
        (session) => session.interruptionEventStream,
      );

  @override
  Stream<void> get becomingNoisyEvents =>
      Stream.fromFuture(_session).asyncExpand(
        (session) => session.becomingNoisyEventStream,
      );

  @override
  Future<void> configureMusic() async {
    final session = await _session;
    await session.configure(const AudioSessionConfiguration.music());
  }

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
  }) async {
    final session = await _session;
    return session.setActive(
      active,
      avAudioSessionSetActiveOptions: avAudioSessionSetActiveOptions,
    );
  }
}

class _PlayerAudioInterruptionActions implements AudioInterruptionActions {
  @override
  PlayerStatus? get playerStatus =>
      PlPlayerController.getPlayerStatusIfExists();

  @override
  void duckVolume(bool down) {
    PlPlayerController.setVolumeIfExists(
      (PlPlayerController.getVolumeIfExists() ?? 0) * (down ? 0.5 : 2),
      showIndicator: false,
    );
  }

  @override
  void pauseAsInterruption() {
    PlPlayerController.pauseIfExists(isInterrupt: true);
  }

  @override
  void resumeAfterInterruption() {
    PlPlayerController.playIfExists();
  }

  @override
  void pauseForNoisyRoute() {
    PlPlayerController.pauseIfExists();
  }
}

class AudioSessionHandler implements NowPlayingGuard {
  AudioSessionHandler({
    AudioSessionPort? port,
    AudioInterruptionActions? actions,
    bool? isIOS,
  }) : _port = port ?? _PluginAudioSessionPort(),
       _actions = actions ?? _PlayerAudioInterruptionActions(),
       _isIOS = isIOS ?? Platform.isIOS {
    _ready = initSession();
  }

  final AudioSessionPort _port;
  final AudioInterruptionActions _actions;
  final bool _isIOS;
  late final Future<void> _ready;
  bool _playInterrupted = false;
  bool _externalInterruption = false;

  /// 播放期间盯住会话选项的定时器，见 [startNowPlayingGuard]。
  Timer? _mixGuard;

  /// Incremented whenever an in-flight guard check must become stale.
  int _guardEpoch = 0;

  /// 当前持有守卫的宿主（视频控制器 / 音频页控制器）。
  ///
  /// 守卫是**进程级**的（[AudioSessionHandler] 在 service locator 里只有一个），
  /// 而两个宿主会同时播放：视频在播 → 打开音频页（start 幂等）→ 视频暂停
  /// （stop）。只有计数/名册才分得清"这是最后一个持有者，可以停"。按名字记而
  /// 不是纯计数：某个宿主没 start 就 stop（例如页面没播过就 dispose）时，纯计数
  /// 会把另一个宿主的守卫一起关掉。
  final Set<Object> _guardHolders = {};

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
  @override
  void start(Object holder) => startNowPlayingGuard(holder);

  @override
  void stop(Object holder) => stopNowPlayingGuard(holder);

  void startNowPlayingGuard(Object holder) {
    _guardHolders.add(holder);
    _ensureNowPlayingGuard();
  }

  void _ensureNowPlayingGuard() {
    if (!_isIOS ||
        _externalInterruption ||
        _guardHolders.isEmpty ||
        _mixGuard != null) {
      return;
    }
    final epoch = _guardEpoch;
    _mixGuard = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _assertExclusive(epoch),
    );
  }

  /// 暂停/销毁时停下。mpv 只在起音频输出那一刻改会话，暂停期间不用盯。
  ///
  /// 只有**最后一个**持有者退出时才真的停：视频暂停时音频页可能还在播，
  /// 停了守卫、mpv 一旦把会话改回混音，锁屏卡片就跟着消失。
  void stopNowPlayingGuard(Object holder) {
    _guardHolders.remove(holder);
    if (_guardHolders.isNotEmpty) return;
    _guardEpoch++;
    _mixGuard?.cancel();
    _mixGuard = null;
  }

  bool _guardCanRun(int epoch) =>
      _isIOS &&
      !_externalInterruption &&
      _guardEpoch == epoch &&
      _mixGuard != null;

  Future<void> _assertExclusive(int epoch) async {
    if (!_guardCanRun(epoch)) return;
    try {
      await _port.ready;
      if (!_guardCanRun(epoch)) return;
      final options = await _port.categoryOptions;
      if (!_guardCanRun(epoch)) return;
      final category = await _port.category;
      if (!_guardCanRun(epoch)) return;
      if (options.contains(AVAudioSessionCategoryOptions.mixWithOthers) ||
          category != AVAudioSessionCategory.playback) {
        await _port.configureMusic();
        if (!_guardCanRun(epoch)) {
          await _releaseAfterStaleGuard();
          return;
        }
        debugPrint('[锁屏控制] mpv 把会话改回了混音，已重新钉成独占');
      }
      // mpv 每重建一次音频输出，就会先把会话 deactivate 再 activate。回主页后
      // 它重建时如果没把我们重新激活，iOS 就不再把我们当选「正在播放」——
      // 卡片直接换成上一个播放器（真机 2026-10-21：回主页几秒后变苹果音乐）。
      // 激活是幂等的，活动期间每拍都确认一次。
      if (!_guardCanRun(epoch)) return;
      final active = await _port.setActive(true);
      if (!_guardCanRun(epoch)) {
        await _releaseAfterStaleGuard();
        return;
      }
      if (!active) debugPrint('[锁屏控制] 会话重新激活失败');
      // 2026-10-21 实验结论：后台每 3 秒做一次完整「重新认领」（钉会话 +
      // 重写 Now Playing + 拿回遥控）**抢不回卡片** —— 系统一旦把「正在播放」
      // 交给别的 App 就不会还。所以不再自动 reclaim，改从根上避免断音
      // （后台推迟解码器重建，见 PlPlayerController._deferredDecoderRebuild）。
    } catch (_) {
      // 取不到选项就等下一拍，不能影响播放。
    }
  }

  Future<void> _releaseAfterStaleGuard() async {
    if (!_externalInterruption) return;
    try {
      await _port.setActive(
        false,
        avAudioSessionSetActiveOptions:
            AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
      );
    } catch (_) {
      // The interruption may already have deactivated the session.
    }
  }

  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
  }) async {
    // 构造是同步的、initSession 是异步的；不等它就可能撞上 `late session`。
    await _ready;
    try {
      final options = !active && _isIOS
          ? avAudioSessionSetActiveOptions ??
                AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation
          : avAudioSessionSetActiveOptions;
      return await _port.setActive(
        active,
        avAudioSessionSetActiveOptions: options,
      );
    } catch (e) {
      if (_isIOS) debugPrint('[锁屏控制] setActive($active) 失败: $e');
      rethrow;
    }
  }

  Future<void> initSession() async {
    await _port.ready;
    await _port.configureMusic();

    _port.interruptionEvents.listen(_handleInterruption);

    // 耳机拔出暂停
    _port.becomingNoisyEvents.listen((_) => _actions.pauseForNoisyRoute());
  }

  void _handleInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      _suspendNowPlayingGuardForInterruption();
      final playerStatus = _actions.playerStatus;
      if (playerStatus != PlayerStatus.playing) return;
      switch (event.type) {
        case AudioInterruptionType.duck:
          _actions.duckVolume(true);
        case AudioInterruptionType.pause || AudioInterruptionType.unknown:
          _actions.pauseAsInterruption();
          _playInterrupted = true;
      }
      return;
    }

    _externalInterruption = false;
    switch (event.type) {
      case AudioInterruptionType.duck:
        _actions.duckVolume(false);
      case AudioInterruptionType.pause:
        if (_playInterrupted) _actions.resumeAfterInterruption();
      case AudioInterruptionType.unknown:
        break;
    }
    _playInterrupted = false;
    if (_shouldResumeGuardAfterInterruption()) {
      _ensureNowPlayingGuard();
      debugPrint('[锁屏控制] 中断结束，恢复会话守卫');
    }
  }

  void _suspendNowPlayingGuardForInterruption() {
    if (_externalInterruption) return;
    _externalInterruption = true;
    _guardEpoch++;
    _mixGuard?.cancel();
    _mixGuard = null;
    debugPrint('[锁屏控制] 外部音频中断，停止重抢会话');
    if (!_isIOS) return;
    unawaited(_releaseAudioSessionForInterruption());
  }

  Future<void> _releaseAudioSessionForInterruption() async {
    try {
      final active = await setActive(
        false,
        avAudioSessionSetActiveOptions:
            AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
      );
      debugPrint(
        active ? '[锁屏控制] 会话已让出（notifyOthersOnDeactivation）' : '[锁屏控制] 会话本来已不活跃',
      );
    } catch (e) {
      debugPrint('[锁屏控制] 让出音频会话失败: $e');
    }
  }

  bool _shouldResumeGuardAfterInterruption() {
    if (_guardHolders.isEmpty) return false;
    if (_actions.playerStatus == PlayerStatus.playing) return true;
    return switch (WidgetsBinding.instance.lifecycleState) {
      AppLifecycleState.paused ||
      AppLifecycleState.hidden ||
      AppLifecycleState.detached => false,
      _ => true,
    };
  }
}
