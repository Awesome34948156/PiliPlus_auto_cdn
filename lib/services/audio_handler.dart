import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart' show DetailItem;
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/controller.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/player_tuning.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:get/get.dart';
import 'package:path/path.dart' as path;

Future<VideoPlayerServiceHandler> initAudioService() {
  return AudioService.init(
    builder: VideoPlayerServiceHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.piliplus.audio',
      androidNotificationChannelName: 'Audio Service ${Constants.appName}',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
      androidNotificationChannelDescription: 'Media notification channel',
      androidNotificationIcon: 'drawable/ic_notification_icon',
    ),
  );
}

typedef _StatusConfig = (
  PlayerStatus status,
  bool isBuffering,
  bool isLive,
  double speed,
  bool canSkipPrevious,
  bool canSkipNext,
);

/// 系统「正在播放」上要暴露哪些按钮。
///
/// iOS 只认 [PlaybackState.controls] 里出现过的动作，没发出去的遥控命令不会启用；
/// Android 的通知按钮也受这份列表影响，所以 skip 只在调用方算好可用性时才会进来。
@visibleForTesting
List<MediaControl> buildMediaControls({
  required bool playing,
  required bool isLive,
  required bool canSkipPrevious,
  required bool canSkipNext,
}) {
  return [
    if (!isLive && canSkipPrevious) MediaControl.skipToPrevious,
    if (!isLive)
      const MediaControl(
        androidIcon: 'drawable/ic_player_rewind_10s',
        label: 'Rewind',
        action: .rewind,
      ),
    if (playing)
      const MediaControl(
        androidIcon: 'drawable/ic_player_pause',
        label: 'Pause',
        action: .pause,
      )
    else
      const MediaControl(
        androidIcon: 'drawable/ic_player_play',
        label: 'Play',
        action: .play,
      ),
    if (!isLive)
      const MediaControl(
        androidIcon: 'drawable/ic_player_fast_forward_10s',
        label: 'Fast Forward',
        action: .fastForward,
      ),
    if (!isLive && canSkipNext) MediaControl.skipToNext,
  ];
}

class VideoPlayerServiceHandler extends BaseAudioHandler with SeekHandler {
  static final List<MediaItem> _item = [];
  // iOS 上设置里已把「后台音频服务」并进「后台播放」，这里跟着同一个开关走。
  bool enableBackgroundPlay = Platform.isIOS
      ? Pref.continuePlayInBackground
      : Pref.enableBackgroundPlay;

  /// 后台播放关着时，也缓存当前媒体条目，供退后台宽限卡片用。
  MediaItem? _lastKnownMediaItem;

  /// 宽限卡片是否亮着（后台播放关着、退后台后的宽限窗口内）。
  bool _graceActive = false;
  Timer? _graceTimer;

  /// [enableBackgroundPlay] 是不是「宽限卡上按了播放」临时打开的（只改内存）。
  ///
  /// 这种临时打开只对**当时那条视频**有效：换到别的视频必须还回去，否则整场
  /// App 都变成后台播放开着 —— 用户反馈「从卡上按过一次播放之后，看别的视频
  /// 退后台也一直在放了」就是这个漏出来的标记。
  bool _graceBackgroundPlay = false;

  /// 前台播放期间是否已经把系统「正在播放」认领下来（仅 iOS、后台播放关着）。
  ///
  /// 系统只在 App **真的在放声音**的时候把「正在播放」交给它：退后台暂停之后
  /// 再从后台写 `nowPlayingInfo` 一律不认（2026-10-21 实验：卡片被系统交给别的
  /// App 后，后台每 3 秒完整重新认领一次也抢不回来）。所以宽限卡要亮得起来，
  /// 认领必须发生在声音还在放的时候 —— 见 [claimPlaybackWhilePlaying]。
  bool _iosPlaybackClaim = false;

  /// 诊断探针的定时器（宽限窗口内几拍快照），收卡时一并取消。
  final List<Timer> _probeTimers = [];

  bool get _canPush =>
      enableBackgroundPlay || _graceActive || _iosPlaybackClaim;

  /// 诊断用：读系统「正在播放」那一侧的状态（原生 `NowPlayingProbePlugin`）。
  static const _probeChannel = MethodChannel(
    'com.example.piliplus/nowplaying_probe',
  );

  /// 诊断用：重推一次暂停态，验证「首推太早（那时 mpv 还没真暂停）」这条假设。
  static const bool _kRepushExperiment = false;

  /// 向原生申请一段后台执行时间，撑住整个宽限窗。
  ///
  /// 后台播放关着时 mpv 一停音频，iOS 一两秒内就把 App 冻住（真机 2026-10-23：
  /// 退后台 0.3 秒那行就是最后一行，4 分半后回前台所有定时器才一起补跑）：
  /// 到点收卡、会话守卫、探针全部作废。不申请这条断言，宽限卡在结构上就不可能成立。
  void _beginGraceTask() {
    // 把窗口长度一起带过去：iOS 给一个后台任务只有 ~30 秒，原生侧要靠这个
    // 期限决定到期时续不续一次任务（60 秒窗口得撑两段）。
    _probeChannel
        .invokeMethod<int>(
          'beginGrace',
          PlayerTuning.backgroundPlayGraceDuration.inMilliseconds + 2000,
        )
        .then(
          (id) => debugPrint('宽限卡: 后台任务已申请 id=$id'),
          onError: (Object e) => debugPrint('宽限卡: 后台任务申请失败 $e'),
        );
  }

  void _endGraceTask() {
    _probeChannel.invokeMethod<void>('endGrace').catchError((Object e) {
      debugPrint('宽限卡: 后台任务结束失败 $e');
    });
  }

  void _probeNowPlaying(String label) {
    _probeChannel
        .invokeMethod<Map<dynamic, dynamic>>('snapshot')
        .timeout(const Duration(milliseconds: 500))
        .then((m) {
          m ??= const {};
          debugPrint(
            '宽限卡探针[$label] info=${m['hasInfo']} title=${m['title']} '
            'rate=${m['rate']} elapsed=${m['elapsed']} dur=${m['duration']} '
            'state=${m['state']} cmd=${m['playEnabled']} cat=${m['cat']} '
            'opts=${m['opts']} mode=${m['mode']} other=${m['otherAudio']} '
            'app=${m['app']}',
          );
        })
        .catchError((Object e) {
          debugPrint('宽限卡探针[$label] 失败: $e');
        });
  }

  void _cancelProbeTimers() {
    for (final t in _probeTimers) {
      t.cancel();
    }
    _probeTimers.clear();
  }

  Future<void>? Function()? onPlay;
  Future<void>? Function()? onPause;
  Future<void>? Function(Duration position)? onSeek;
  void Function()? onSkipToNext;
  void Function()? onSkipToPrevious;

  /// 由拥有播放列表的页面（目前只有音频页）提供；为空时回退到 intro controller。
  bool Function()? onCanSkipToNext;
  bool Function()? onCanSkipToPrevious;

  @override
  Future<void> play() {
    if (_graceActive) {
      _graceActive = false;
      _graceTimer?.cancel();
      _graceTimer = null;
      _cancelProbeTimers();
      enableBackgroundPlay = true;
      // 记下这是「临时」打开的：换视频时要还回去（见 [onVideoDetailChange]）。
      _graceBackgroundPlay = true;
      // 马上要真的出声了，音频本身就能把 App 撑住，后台执行时间可以还回去。
      _endGraceTask();
      // 宽限期间开的会话守卫到此为止，接下去由真实播放态（stream.playing）
      // 重新认领，别让它残留成永久定时器。
      audioSessionHandler?.stopNowPlayingGuard(this);
      PlPlayerController.instance?.activateBackgroundPlayFromGrace();
    }
    return onPlay?.call() ??
        PlPlayerController.playIfExists() ??
        Future.syncValue(null);
  }

  @override
  Future<void> pause() {
    return onPause?.call() ??
        PlPlayerController.pauseIfExists() ??
        Future.syncValue(null);
  }

  /// 拿当前的 intro controller，失败一律返回 null。
  ///
  /// 会从播放器 stream 回调里调用，所以不能抛；也用于「上一集/下一集是否要显示」，
  /// 保证按钮显示与否和按下去执行的是同一份解析。
  /// GetX 按运行时具体类型注册，不能直接 `Get.find<CommonIntroController>`。
  CommonIntroController? _peekIntroController() {
    final playOwner = PlPlayerController.playOwner;
    if (playOwner == null) return null;
    final tag = playOwner.tag;
    try {
      final CommonIntroController? controller = switch (playOwner.type) {
        UgcIntroController =>
          Get.isRegistered<UgcIntroController>(tag: tag)
              ? Get.find<UgcIntroController>(tag: tag)
              : null,
        PgcIntroController =>
          Get.isRegistered<PgcIntroController>(tag: tag)
              ? Get.find<PgcIntroController>(tag: tag)
              : null,
        LocalIntroController =>
          Get.isRegistered<LocalIntroController>(tag: tag)
              ? Get.find<LocalIntroController>(tag: tag)
              : null,
        _ => null,
      };
      return controller == null || controller.isClosed ? null : controller;
    } catch (_) {
      return null;
    }
  }

  bool _canSkipToNext() {
    final resolve = onCanSkipToNext;
    if (resolve != null) return resolve();
    // 音频页在播时会把 onSkipToNext 设上；此时 playOwner 可能还停在底下的视频页。
    if (onSkipToNext != null) return false;
    try {
      return _peekIntroController()?.canSkipToNext ?? false;
    } catch (_) {
      return false;
    }
  }

  bool _canSkipToPrevious() {
    final resolve = onCanSkipToPrevious;
    if (resolve != null) return resolve();
    if (onSkipToPrevious != null) return false;
    try {
      return _peekIntroController()?.canSkipToPrevious ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> skipToNext() {
    final func = onSkipToNext ?? _peekIntroController()?.nextPlay;
    return func == null ? Future.syncValue(null) : Future.sync(func);
  }

  @override
  Future<void> skipToPrevious() {
    final func = onSkipToPrevious ?? _peekIntroController()?.prevPlay;
    return func == null ? Future.syncValue(null) : Future.sync(func);
  }

  @override
  Future<void> seek(Duration position) async {
    final seekInPage = onSeek;
    if (seekInPage != null) {
      // 音频页自己会刷新 PlaybackState，不重复发布。
      await seekInPage(position);
      return;
    }
    final seek = PlPlayerController.seekToIfExists(position, isSeek: false);
    if (seek == null) return;
    await seek;
    // 已经清空/关闭时不要再发状态，否则会把系统卡片唤回来。
    if (playbackState.value.processingState == .idle) return;
    // copyWith 会把 updateTime 重置为现在，暂停中拖动也能立刻重算系统进度。
    playbackState.add(playbackState.value.copyWith(updatePosition: position));
    _lastPos = position;
  }

  void setMediaItem(MediaItem newMediaItem) {
    if (!_canPush) return;
    // if (kDebugMode) {
    //   debugPrint("此时调用栈为：");
    //   debugPrint(newMediaItem);
    //   debugPrint(newMediaItem.title);
    //   debugPrint(StackTrace.current.toString());
    // }
    if (!mediaItem.isClosed) mediaItem.add(newMediaItem);
  }

  /// iOS、后台播放关着时，在**声音还在放的时候**先把系统「正在播放」认领下来。
  ///
  /// 这一步是宽限卡能不能出现的前提：退后台时我们先暂停、再写 Now Playing，
  /// 而系统不把「已经从后台才认领的暂停卡」当成正在播放的 App —— 真机 2026-10-23
  /// 那局 8 秒里 `info=true state=2 cmd=true cat=playback opts=0` 全对，三处却
  /// 一张卡都没有。改在播放期间就认领（此刻会话真在出声），退后台那一暂停才被
  /// 系统当成「同一个 App 暂停了」，卡片留得下来。代价是前台播放时锁屏/控制
  /// 中心也会有这张卡（暂停键可用）。
  void claimPlaybackWhilePlaying({required Duration position}) {
    if (!Platform.isIOS) return;
    if (enableBackgroundPlay || _iosPlaybackClaim || _graceActive) return;
    final item = _lastKnownMediaItem;
    if (item == null) return;
    debugPrint('宽限卡: 播放中先认领「正在播放」（position ${position.inSeconds}s）');
    _iosPlaybackClaim = true;
    _item.add(item);
    setMediaItem(item);
    _lastPos = position;
    _updateState(
      AudioProcessingState.ready,
      true,
      item.isLive ?? false,
      position: position,
      speed: 1.0,
    );
    _probeNowPlaying('claim');
  }

  /// 播放器销毁 / 离开播放页时把认领还回去。
  ///
  /// 幂等：宽限卡亮着时由 [cancelGrace] 负责收，这里不插手。
  void releasePlaybackClaim() {
    if (!_iosPlaybackClaim) return;
    _iosPlaybackClaim = false;
    if (_graceActive) return;
    if (playbackState.value.processingState == .idle) return;
    debugPrint('宽限卡: 释放「正在播放」认领');
    _withdrawCard();
    _item.clear();
    _lastConfig = null;
    _lastPos = null;
  }

  /// 退后台宽限窗：亮一张「暂停 + 播放键」的卡片，给用户手动续播的机会。
  ///
  /// 只在 iOS、后台播放关着、且还没亮过时生效。
  void showGraceCard({required Duration position}) {
    if (!Platform.isIOS) return;
    if (enableBackgroundPlay || _graceActive) {
      debugPrint(
        '宽限卡: 跳过（后台播放 $enableBackgroundPlay / 已在宽限 $_graceActive）',
      );
      return;
    }
    final item = _lastKnownMediaItem;
    if (item == null) {
      debugPrint('宽限卡: 跳过（没有可用的媒体条目缓存）');
      return;
    }
    debugPrint('宽限卡: 亮暂停卡（窗口 ${PlayerTuning.backgroundPlayGraceDuration.inSeconds}s，position ${position.inSeconds}s）');
    _graceActive = true;
    // 认领从此归宽限状态自己管（`_canPush` 里那条），标志清掉：到点收卡时
    // 不能再有一个「已认领」把卡片推回来。
    _iosPlaybackClaim = false;
    // 先把后台执行时间要下来，否则下面这些状态推完没多久 App 就被冻住了。
    _beginGraceTask();
    // 宽限窗口内盯住音频会话：mpv 起音频输出时会把会话改回混音、退后台暂停后
    // iOS 也可能把会话 deactivate，任一下都会让系统卡片整个消失。守卫每秒把
    // 会话重新钉成独占 + active，窗口内卡片才稳得住。
    audioSessionHandler?.startNowPlayingGuard(this);
    _item.add(item);
    setMediaItem(item);
    _lastPos = position;
    // 先推一次「播放中」：原生 AudioServicePlugin 只在 playing==true 时
    // activateCommandCenter，冷启动的暂停卡没有遥控中心、系统不认「正在播放」。
    // 紧接着推「暂停」把状态掰正；中间那个 true 只活一个微任务，不会被看到。
    _updateState(
      AudioProcessingState.ready,
      true,
      item.isLive ?? false,
      position: position,
      speed: 1.0,
    );
    _updateState(
      AudioProcessingState.ready,
      false,
      item.isLive ?? false,
      position: position,
      speed: 1.0,
    );
    _graceTimer?.cancel();
    _graceTimer = Timer(PlayerTuning.backgroundPlayGraceDuration, _endGrace);

    // 诊断：看窗口里系统侧是什么样（info 有没有写进去、会话类别、遥控中心、
    // App 有没有被挂起）。+6s 还有探针 = App 没被挂起。
    _probeNowPlaying('t+0');
    for (final ms in [300, 1200, 3000, 6000, 15000, 30000, 45000]) {
      _probeTimers.add(
        Timer(Duration(milliseconds: ms), () => _probeNowPlaying('t+$ms')),
      );
    }
    if (_kRepushExperiment) {
      _probeTimers.add(
        Timer(const Duration(milliseconds: 1500), () {
          // 原生只在字段真变时才重赋 nowPlayingInfo（AudioServicePlugin.m:300），
          // 位置加 1ms 才真的重写一次。
          debugPrint('宽限卡: 重推暂停态（实验）');
          _updateState(
            AudioProcessingState.ready,
            false,
            item.isLive ?? false,
            position: position + const Duration(milliseconds: 1),
            speed: 1.0,
          );
        }),
      );
      _probeTimers.add(
        Timer(
          const Duration(milliseconds: 1650),
          () => _probeNowPlaying('t+1650'),
        ),
      );
    }
  }

  Duration? _lastPos;
  _StatusConfig? _lastConfig;
  void onUpdateState(
    PlayerStatus status,
    bool isBuffering,
    bool isLive, {
    required Duration position,
    required double speed,
    String? debugLabel,
  }) {
    if (!_canPush || _item.isEmpty) return;

    if (onPlay != null && debugLabel == 'onVideoPaused') return;

    // 只在 iOS 且非直播时才算：直播没有上下集，Android 通知里也不放 skip。
    final canSkipPrevious = Platform.isIOS && !isLive && _canSkipToPrevious();
    final canSkipNext = Platform.isIOS && !isLive && _canSkipToNext();

    final newConfig = (
      status,
      isBuffering,
      isLive,
      speed,
      canSkipPrevious,
      canSkipNext,
    );
    final lastPos = _lastPos;
    // 每次都要更新基准，否则 config 变化后 _lastPos 会停在旧值。
    _lastPos = position;
    if (_lastConfig == newConfig && lastPos != null) {
      final pos = position.inSeconds;
      if (pos == lastPos.inSeconds && pos != 0) return;
    }
    _lastConfig = newConfig;

    final AudioProcessingState processingState;
    final bool playing;
    switch (status) {
      case .completed:
        playing = false;
        processingState = .completed;
      case .playing:
        playing = true;
        processingState = isBuffering ? .buffering : .ready;
      case .paused:
        playing = isBuffering;
        processingState = isBuffering ? .buffering : .ready;
    }
    _updateState(
      processingState,
      playing,
      isLive,
      position: position,
      speed: speed,
      canSkipPrevious: canSkipPrevious,
      canSkipNext: canSkipNext,
    );
  }

  void _updateState(
    AudioProcessingState state,
    bool playing,
    bool isLive, {
    required Duration position,
    required double speed,
    bool canSkipPrevious = false,
    bool canSkipNext = false,
  }) {
    playbackState.add(
      playbackState.value.copyWith(
        processingState: state,
        updatePosition: position,
        speed: speed,
        controls: buildMediaControls(
          playing: playing,
          isLive: isLive,
          canSkipPrevious: canSkipPrevious,
          canSkipNext: canSkipNext,
        ),
        playing: playing,
        systemActions: const {.seek},
      ),
    );
    if (Platform.isAndroid &&
        (AndroidHelper.isPipMode ||
            PlPlayerController.instance?.isAutoEnterPip == true)) {
      AndroidHelper.updatePipActions(
        PlatformDispatcher.instance.engineId!,
        isLive,
        playing,
      );
    }
  }

  void onVideoDetailChange(
    dynamic data,
    int cid,
    String herotag, {
    String? artist,
    String? cover,
  }) {
    // if (kDebugMode) {
    //   debugPrint('当前调用栈为：');
    //   debugPrint(StackTrace.current);
    // }
    if (data == null) return;

    Uri getUri(String? cover) => Uri.parse(ImageUtils.safeThumbnailUrl(cover));

    late final id = '$cid$herotag';
    final MediaItem mediaItem;
    switch (data) {
      case VideoDetailData(:final pages):
        if (pages != null && pages.length > 1) {
          final current = pages.firstWhereOrNull((e) => e.cid == cid);
          mediaItem = MediaItem(
            id: id,
            title: current?.part ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: current?.duration ?? 0),
            artUri: getUri(data.pic),
          );
        } else {
          mediaItem = MediaItem(
            id: id,
            title: data.title ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: data.duration ?? 0),
            artUri: getUri(data.pic),
          );
        }
      case EpisodeItem():
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle ?? data.longTitle ?? data.title ?? '',
          artist: artist,
          duration: data.from == 'pugv'
              ? Duration(seconds: data.duration ?? 0)
              : Duration(milliseconds: data.duration ?? 0),
          artUri: getUri(data.cover),
        );
      case RoomInfoH5Data():
        mediaItem = MediaItem(
          id: id,
          title: data.roomInfo?.title ?? '',
          artist: data.anchorInfo?.baseInfo?.uname,
          artUri: getUri(data.roomInfo?.cover),
          isLive: true,
        );
      case Part():
        mediaItem = MediaItem(
          id: id,
          title: data.part ?? '',
          artist: artist,
          duration: Duration(seconds: data.duration ?? 0),
          artUri: getUri(cover),
        );
      case DetailItem(:final arc):
        mediaItem = MediaItem(
          id: id,
          title: arc.title,
          artist: data.owner.name,
          duration: Duration(seconds: arc.duration.toInt()),
          artUri: getUri(arc.cover),
        );
      case BiliDownloadEntryInfo():
        final coverFile = File(
          path.join(data.entryDirPath, PathUtils.coverName),
        );
        final uri = coverFile.existsSync()
            ? coverFile.absolute.uri
            : getUri(data.cover);
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle,
          artist: data.ownerName,
          duration: Duration(milliseconds: data.totalTimeMilli),
          artUri: uri,
        );
      default:
        return;
    }
    // 宽限卡上临时打开的后台播放只认「按卡那一晚」的那条视频：换到别的视频
    // （换集/换片/直播/听视频都算）就还回去，别让它漏成整场 App 的设置。
    if (_graceBackgroundPlay &&
        _lastKnownMediaItem != null &&
        _lastKnownMediaItem!.id != mediaItem.id) {
      _graceBackgroundPlay = false;
      enableBackgroundPlay = false;
      // 认领（[_iosPlaybackClaim]）留着不动：卡片不用先收再推，换视频的
      // 空档里系统也不会把我们换下去。
      PlPlayerController.resetGraceBackgroundPlay();
      debugPrint('宽限卡: 换到别的视频了，撤掉临时打开的后台播放');
    }
    _lastKnownMediaItem = mediaItem;
    if (_canPush) {
      _item.add(mediaItem);
      setMediaItem(mediaItem);
      // 换集后重新评估「上一集/下一集」是否可用。
      _lastConfig = null;
    }
  }

  /// 关掉服务那一刻的系统状态。重新打开时先把它推回去：只 `setMediaItem`
  /// 恢复的是一张没有播放态、没有控制的卡片，要等下一次真实的状态变化才会补上
  /// （而那是暂停/播放才有的，可能几分钟都没有）。
  PlaybackState? _suspendedState;

  /// 把系统卡片收回去：audio_service 只在「非 idle → idle」时调 stopService，
  /// Darwin 端由此把 nowPlayingInfo 置 nil 并收回遥控。
  void _withdrawCard() {
    if (playbackState.value.processingState == .idle) {
      playbackState.add(PlaybackState(processingState: .completed));
    }
    playbackState.add(PlaybackState(processingState: .idle));
  }

  void _endGrace() => cancelGrace();

  /// 收起宽限卡并重置宽限状态。两个入口：窗口到点（[_endGrace]）、回前台
  /// （[PlPlayerController.cancelBackgroundGraceCard]），后者让下趟退后台不被
  /// 残留的 `_graceActive` 挡掉。
  void cancelGrace() {
    _graceTimer?.cancel();
    _graceTimer = null;
    _cancelProbeTimers();
    if (!_graceActive) return;
    _graceActive = false;
    // 「收卡」打出来 = 宽限定时器真的跑到了（App 没被挂起）；不打 = 被挂起。
    debugPrint('宽限卡: 收卡');
    // 宽限窗结束（到点 / 回前台），会话守卫和后台执行时间都不再需要。
    _endGraceTask();
    audioSessionHandler?.stopNowPlayingGuard(this);
    if (enableBackgroundPlay) return;
    _withdrawCard();
    _item.clear();
    _lastConfig = null;
    _lastPos = null;
  }

  /// 开关「后台音频服务」。
  ///
  /// 关闭时只撤掉系统播放器（锁屏/灵动岛/通知），不打断正在播放的声音，
  /// 并保留 [_item]，重新打开时还能把卡片恢复回来。
  void setEnableBackgroundPlay(bool value) {
    if (enableBackgroundPlay == value) return;

    if (value) {
      enableBackgroundPlay = true;
      // 用户自己开的开关：这就不是「宽限卡临时打开」了，换视频也别撤。
      _graceBackgroundPlay = false;
      _lastConfig = null;
      _lastPos = null;
      // 只在确实还有播放器/播放页时恢复卡片，避免关掉服务后残留的旧条目
      // 在设置页一开开关就冒出一张幽灵卡片。
      if (_item.isNotEmpty &&
          (PlPlayerController.instance != null || onPlay != null)) {
        setMediaItem(_item.last);
        final suspended = _suspendedState;
        _suspendedState = null;
        if (suspended != null && suspended.processingState != .idle) {
          playbackState.add(suspended);
        }
      }
      return;
    }

    // 关的是「后台播放」，不是「别再放声音」：正在前台播放就把卡片留着，
    // 认领从「后台播放开关」换成 [claimPlaybackWhilePlaying] 那一支 ——
    // 收掉再重推不如根本不收（卡片一闪，系统还可能把我们换下去）。
    if (Platform.isIOS &&
        PlPlayerController.getPlayerStatusIfExists() == PlayerStatus.playing) {
      enableBackgroundPlay = false;
      _graceBackgroundPlay = false;
      _iosPlaybackClaim = true;
      _suspendedState = null;
      _lastConfig = null;
      _lastPos = null;
      return;
    }

    // audio_service 只在「非 idle → idle」时调用 stopService；Darwin 端由此
    // 把 nowPlayingInfo 置 nil 并收回遥控。单独 mediaItem.add(null) 没用，
    // audio_service 的 _observeMediaItem 会直接忽略 null。
    _suspendedState = playbackState.value;
    _withdrawCard();
    enableBackgroundPlay = false;
    _graceBackgroundPlay = false;
    _iosPlaybackClaim = false;
    _lastConfig = null;
    _lastPos = null;
  }

  void onVideoDetailDispose(String herotag) {
    if (!_canPush) return;

    if (_item.isNotEmpty) {
      _item.removeWhere((item) => item.id.endsWith(herotag));
    }
    if (_item.isNotEmpty) {
      setMediaItem(_item.last);
      playbackState.add(
        playbackState.value.copyWith(processingState: .ready, playing: false),
      );
    }
  }

  void clearIfNeeded() {
    if (!_canPush) return;
    if (_item.isEmpty) clear();
  }

  void clear() {
    if (!_canPush) return;
    mediaItem.add(null);
    _item.clear();
    _lastPos = null;
    _lastConfig = null;
    /**
     * if (playbackState.processingState == AudioProcessingState.idle &&
            previousState?.processingState != AudioProcessingState.idle) {
          await AudioService._stop();
        }
     */
    if (playbackState.value.processingState == .idle) {
      playbackState.add(PlaybackState(processingState: .completed));
    }
    playbackState.add(PlaybackState(processingState: .idle));
  }
}
