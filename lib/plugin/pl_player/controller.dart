import 'dart:async' show StreamSubscription, Timer;
import 'dart:convert' show ascii, utf8;
import 'dart:io' show Platform;
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_shot/data.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/double_tap_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/duration.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/console_log.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/asset_utils.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/box_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/ios/pip_helper.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart'
    show DeviceOrientation, HapticFeedback, KeyDownEvent;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:path/path.dart' as path;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

typedef PlayCallback = Future<void>? Function();
typedef PlayOwner = ({String tag, Type type});

class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;

  static PlPlayerController? _instance;

  PlayerStatus playerStatus = .paused;

  final Rx<DataStatus> dataStatus = Rx(.none);

  Duration? seekToPos;
  bool hasToasted = false;
  final RxBool isSeeking = false.obs;

  final RxInt position = RxInt(0);
  final RxInt seekPosition = RxInt(0);
  int get progress => isSeeking.value ? seekPosition.value : position.value;

  int get positionInMilliseconds =>
      videoPlayerController?.state.position.inMilliseconds ?? 0;

  /// mpv 的 `demuxer-cache-time` 原样搬过来 —— 那是**文件时间轴上的绝对时刻**
  /// （缓存末端的时间戳），不是"缓冲了多少秒"。缓存非空时它一路跟着读指针走，
  /// 空了就停在最后一次的值上，所以它看起来几乎等于 [position]（实测位置
  /// 917s 时它是 921s）。把它当"前方余量"用会得出荒谬的结论：一个 37 分钟的
  /// 视频不可能缓冲了 1240 秒。
  final RxInt buffered = RxInt(0);

  /// 真正的前方缓冲余量：缓存末端减去播放位置，负数归零。
  ///
  /// 实测健康时 20~32s（mpv 配的是 `cache-secs: 32`，补满就停读、掉到
  /// `demuxer-hysteresis-secs` 才续读，于是锯齿在两者之间摆动）；CDN 供不上时
  /// 会趴在 0~4s 并且再也不涨 —— 那正是"画面在走但一直在小卡"的真身。
  int get bufferedAhead {
    final ahead = buffered.value - position.value;
    return ahead > 0 ? ahead : 0;
  }

  /// 遥测是否已经失真：前方余量离谱地大于 mpv 的缓存上限。
  ///
  /// 判据见 [_kDivergedFactor]。这是"只有声音、画面冻住"唯一可靠的信号 ——
  /// 那时位置由音频时钟推着走、[buffered] 被音频轨抬到上千秒、[isBuffering]
  /// 是假，判据 1、2 都看不见，判据 3 的"趴在低位"也只防了反的一侧。
  bool get telemetryDiverged {
    final limit = _divergedAheadSec;
    return limit > 0 && bufferedAhead > limit;
  }

  final RxInt duration = RxInt(0);

  int durationInMilliseconds = 0;

  void updateDuration(Duration value) {
    duration.value = value.inSeconds;
    durationInMilliseconds = value.inMilliseconds;
  }

  int _playerCount = 0;

  late double lastPlaybackSpeed = 1.0;
  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  late final RxDouble _longPressSpeed = Pref.longPressSpeedDefault.obs;

  final RxDouble volume = RxDouble(
    PlatformUtils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final setSystemBrightness = Pref.setSystemBrightness;

  final RxDouble brightness = (-1.0).obs;

  final RxBool showControls = false.obs;

  final RxBool showBrightnessStatus = false.obs;

  final RxBool longPressStatus = false.obs;

  final RxBool controlsLock = false.obs;

  final RxBool isFullScreen = false.obs;
  bool isLive = false;

  bool _isVertical = false;

  final Rx<VideoFitType> videoFit = Rx(.contain);

  late final RxBool continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  bool _autoPlay = false;

  // 记录历史记录
  int? _aid;
  String? _bvid;
  int? cid;
  int? _epid;
  int? _seasonId;
  int? _pgcType;
  VideoType _videoType = VideoType.ugc;
  int _heartDuration = 0;
  int? width;
  int? height;

  late final tryLook = !Accounts.get(AccountType.video).isLogin && Pref.p1080;

  late DataSource dataSource;

  Timer? _timer;
  StreamSubscription? _subForSeek;

  Box setting = GStorage.setting;

  // final Durations durations;

  String get bvid => _bvid!;

  /// 视频播放速度
  double get playbackSpeed => _playbackSpeed.value;

  // 长按倍速
  double get longPressSpeed => _longPressSpeed.value;

  /// [videoPlayerController] instance of Player
  Player? get videoPlayerController => _videoPlayerController;

  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;

  bool isMuted = false;

  /// 听视频
  late final RxBool onlyPlayAudio = false.obs;

  /// 镜像
  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  final RxBool isBuffering = true.obs;

  /// 卡顿回调。播放器本身与 CDN 无关，只上报"播放状态下位置长时间不推进"
  /// 这一事实，如何恢复由页面决定。每段冻结只触发一次。
  ValueChanged<Duration>? onStall;

  /// 缓冲饥饿回调：播放中前向缓冲 [buffered] 连续 [_kStarveSeconds] 秒低于
  /// 饥饿阈值时上报一次。与 [onStall] 互补——"画面冻住但音频在走"这种换源型
  /// 故障不会让 buffered 归零（mpv 有 cache-secs 打底），位置又一直在推进，
  /// 两种卡顿判据都看不到，只有缓冲余量在悄悄变少。
  /// 与 [onStall] 一样，播放器只上报事实，如何恢复由页面决定。
  ///
  /// 同一条判据还负责另一半：余量**离谱地大**（见 [_kDivergedFactor]）同样是
  /// 这个故障的指纹——那时不是"余量变少"而是音视频两轨的时间轴已经分家。只防
  /// 低的一侧会让画面冻着而三个判据同时失明，实测就是这样。
  ValueChanged<Duration>? onBufferStarve;

  /// 最敏感的一条：前向余量**一归零**就上报一次（每次归零只报一次，补回来
  /// 才重新武装）。前三条判据都要等 —— [onStall] 等 8 秒冻结、[_sampleRebuffer]
  /// 攒够 [_kRebufferTrigger] 次、[onBufferStarve] 连续 [_kStarveSeconds] 秒低于
  /// 阈值 —— 而"卡一下又接着播"这种小卡顿一条都凑不满，等凑满时用户已经看了
  /// 半分钟转圈。这里只报事实，节流与"要不要真去测速"由页面决定（测速会跟
  /// 播放器抢带宽，不能由播放器自己决定）。
  ///
  /// 刻意不要求 [isBuffering]：换源型卡顿时 core-idle / paused-for-cache 未必
  /// 为真，`stream.buffer` 才是唯一一定会动的信号。
  ValueChanged<Duration>? onRebuffer;

  /// 位置连续冻结多少秒才算卡顿。普通重新缓冲一般 1~3 秒。
  static const int _kStallSeconds = 8;

  /// 短卡顿计数：窗口内"缓冲归零"的上升沿达到阈值同样判定为卡顿。
  /// 长冻结看门狗看不到"播放 3 秒卡 5 秒"这种反复小卡顿——它只累计连续冻结
  /// 秒数，位置一恢复就清零，永远到不了 [_kStallSeconds]。
  static const int _kRebufferTrigger = 3;
  static const Duration _kRebufferWindow = Duration(seconds: 60);

  /// 加载/换源后的静默期。刚开始缓冲时 `buffered` 本来就是 0，
  /// 不静默的话每次开播都会白记一次。
  static const Duration _kRebufferSuppress = Duration(seconds: 8);

  /// 饥饿阈值取 mpv 回填水位的这个比例。水位是
  /// `demuxer-hysteresis-secs`（见 Pref.initBuffer）：mpv 补到 `cache-secs`
  /// 后停读，等掉回水位才续读，所以健康播放的锯齿在
  /// `[cache-secs, demuxer-hysteresis-secs]` 之间摆动、从来不会接近 0。
  /// 取 0.6 即 `cache-secs * 0.4`，比锯齿下沿还低 40%，健康播放碰不到。
  static const double _kStarveFloorFraction = 0.6;

  /// 连续多少个 1s 采样低于阈值才算饥饿。健康锯齿只在谷底停留一两拍。
  static const int _kStarveSeconds = 4;

  /// 看门狗心跳间隔。三条判据都只在出事时才出声，没有心跳就无法区分
  /// "一切正常"和"看门狗根本没跑"——两者留下的日志一模一样。
  static const int _kHeartbeatSeconds = 10;

  /// 「无视频轨」自己的采样节奏。心跳是 10s，等它两拍要 20s —— 而黑屏是死锁，
  /// 每多等一秒用户就多对着黑屏一秒。改成 2s 一探，[_kNoVideoProbes] 拍就动手。
  static const Duration _kNoVideoProbe = Duration(seconds: 2);

  /// 连续几探"音频在推进、画面仍是空"才认定是死锁。
  ///
  /// 取 4 探（~8s）是放过起播慢的大文件：视频参数本来就比音频晚到，只是不会
  /// 晚到 8 秒。2026-10-11 那次 iOS 黑屏从起播到被探到也远不到 8s。
  static const int _kNoVideoProbes = 4;

  /// 钉住尺寸后等 mpv 走一次 render 往返再看结果。
  static const Duration _kHealWait = Duration(milliseconds: 1200);

  /// 自愈最多钉几次尺寸。第一次 render 可能正好落在 mpv 拆完旧输出、新输出
  /// 还没建好的缝里，再推一次几乎不要钱（不 seek、不重载、不动位置）。
  static const int _kHealAttempts = 2;

  /// 阈值低于这个秒数就不再启用：回填水位太浅，没有可观测的余量。
  static const double _kStarveMinSeconds = 4.0;

  /// 余量超过 mpv 缓存上限 `cache-secs` 的这么多倍，就认为遥测已经失真。
  ///
  /// 健康播放的锯齿在 `[demuxer-hysteresis-secs, cache-secs]` 之间摆动，永远
  /// 到不了 2 倍。而"只有声音、画面冻住"时音频轨的读指针还在推进，
  /// `demuxer-cache-time` 被音频一路抬到上千秒，于是余量涨成上限的几十倍 ——
  /// **离谱地大**本身就是故障指纹，跟判据 3 的"趴在低位"是同一个故障的两副
  /// 面孔，所以共用一条回调。
  static const double _kDivergedFactor = 3.0;

  Timer? _stallTicker;
  int _stallLastSecond = 0;
  int _stallFrozen = 0;
  final List<DateTime> _rebufferEvents = [];
  DateTime _rebufferSuppressUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _wasStalled = false;
  /// 余量是否已经归零过（[onRebuffer] 的上升沿去重）。
  bool _wasEmpty = false;
  int _starveSeconds = 0;
  bool _starveFired = false;
  DateTime _lastHeartbeat = DateTime.fromMillisecondsSinceEpoch(0);

  /// 全屏方向
  // ignore: unnecessary_getters_setters
  bool get isVertical => _isVertical;

  set isVertical(bool value) {
    _isVertical = value;
  }

  /// 弹幕开关
  late final RxBool enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmakuAdaptive =>
      isLive ? enableShowLiveDanmaku : enableShowDanmaku;

  late final bool autoPiP = Pref.autoPiP;
  bool get isPipMode =>
      (Platform.isAndroid && AndroidHelper.isPipMode) ||
      (PlatformUtils.isDesktop && isDesktopPip);
  late bool isDesktopPip = false;
  late Rect _lastWindowBounds;
  static Rect? _lastPipBounds;

  Rect _adjustPipBounds(Rect lastRect, Size size, double aspectRatio) {
    final lastSize = lastRect.size;
    final lastOrientation = lastSize.orientation;
    final orientation = size.orientation;

    if (lastOrientation != orientation) {
      final double width, height;
      switch (orientation) {
        case .portrait:
          if (lastSize.width > size.height) {
            height = min(lastSize.width, _lastWindowBounds.size.height);
            width = height * aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
        case .landscape:
          if (lastSize.height > size.width) {
            width = lastSize.height;
            height = width / aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
      }

      return _lastPipBounds = Rect.fromLTWH(
        lastRect.left,
        lastRect.top,
        width,
        height,
      );
    }
    return _lastPipBounds = Rect.fromLTWH(
      lastRect.left,
      lastRect.top,
      lastSize.width,
      lastSize.width / aspectRatio,
    );
  }

  bool updatePipBounds() {
    if (isDesktopPip) {
      windowManager.getBounds().then((rect) {
        if (isDesktopPip) _lastPipBounds = rect;
      });
      return true;
    }
    return false;
  }

  late final showWindowTitleBar = Pref.showWindowTitleBar;
  late final RxBool isAlwaysOnTop = false.obs;
  Future<void> setAlwaysOnTop(bool value) {
    isAlwaysOnTop.value = value;
    return windowManager.setAlwaysOnTop(value);
  }

  Future<void> exitDesktopPip() {
    isDesktopPip = false;
    return Future.wait([
      if (showWindowTitleBar)
        windowManager.setTitleBarStyle(TitleBarStyle.normal),
      windowManager.setMinimumSize(const Size(400, 700)),
      windowManager.setBounds(_lastWindowBounds),
      setAlwaysOnTop(false),
      windowManager.setAspectRatio(0),
    ]);
  }

  Future<void> enterDesktopPip() async {
    if (isFullScreen.value) return;

    isDesktopPip = true;

    _lastWindowBounds = await windowManager.getBounds();

    if (showWindowTitleBar) {
      windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }

    const shortSide = 280.0;
    const minShortSide = 160.0;
    final Size size;
    final Size minimumSize;
    final state = videoPlayerController!.state;
    int width = state.width;
    int height = state.height;
    if (width == 0) width = this.width ?? 16;
    if (height == 0) height = this.height ?? 9;
    final aspectRatio = width / height;
    if (height > width) {
      size = Size(shortSide, shortSide / aspectRatio);
      minimumSize = Size(minShortSide, minShortSide / aspectRatio);
    } else {
      size = Size(shortSide * aspectRatio, shortSide);
      minimumSize = Size(minShortSide * aspectRatio, minShortSide);
    }

    await windowManager.setMinimumSize(minimumSize);
    setAlwaysOnTop(true);
    if (_lastPipBounds != null) {
      windowManager.setBounds(
        _adjustPipBounds(_lastPipBounds!, size, aspectRatio),
      );
    } else {
      windowManager.setSize(size);
    }
    windowManager.setAspectRatio(width / height);
  }

  void toggleDesktopPip() {
    if (isDesktopPip) {
      exitDesktopPip();
    } else {
      enterDesktopPip();
    }
  }

  late bool _isAutoEnterPip = false;
  bool get isAutoEnterPip => _isAutoEnterPip;

  static bool get _isCurrVideoPage {
    final routing = Get.routing;
    if (routing.route is! GetPageRoute) {
      return false;
    }
    return _isVideoPage(routing.current);
  }

  static bool _isVideoPage(String routeName) {
    return routeName == '/videoV' || routeName == '/liveRoom';
  }

  void enterPip({bool autoEnter = false}) {
    if (videoPlayerController case NativePlayer(:final state)) {
      if (Platform.isIOS) {
        if (videoController?.id.value case final textureId?) {
          IOSPipHelper.enter(
            textureId,
            width: state.width == 0 ? width : state.width,
            height: state.height == 0 ? height : state.height,
            autoEnter: autoEnter,
            state: _iosPipState(state),
          );
        }
        return;
      }
      PageUtils.enterPip(
        autoEnter: autoEnter,
        width: state.width == 0 ? width : state.width,
        height: state.height == 0 ? height : state.height,
        isLive: isLive,
        isPlaying: playerStatus.isPlaying,
      );
    }
  }

  void _disableAutoEnterPip() {
    if (_isAutoEnterPip) {
      if (Platform.isIOS) {
        IOSPipHelper.disableAutoEnter();
      } else {
        PiliAndroidHelper.disableAutoEnterPip();
      }
    }
  }

  Map<String, Object> _iosPipState(PlayerState state, [Duration? position]) {
    return {
      'isPlaying': playerStatus.isPlaying,
      'isBuffering': isBuffering.value,
      'isLive': isLive,
      'position': (position ?? state.position).inMilliseconds,
      'duration': durationInMilliseconds,
      'speed': state.rate,
    };
  }

  void _updateIOSPip([Duration? position]) {
    if (Platform.isIOS && IOSPipHelper.needsUpdate) {
      if (_videoPlayerController case final player?) {
        IOSPipHelper.update(_iosPipState(player.state, position));
      }
    }
  }

  // 弹幕相关配置
  late final enableTapDm = PlatformUtils.isMobile && Pref.enableTapDm;
  late RuleFilter filters = Pref.danmakuFilterRule;
  // 关联弹幕控制器
  DanmakuController<DanmakuExtra>? danmakuController;
  bool showDanmaku = true;
  Set<int> dmState = <int>{};
  late final mergeDanmaku = Pref.mergeDanmaku;
  late final String midHash = getCrc32(
    ascii.encode(Accounts.main.mid.toString()),
    0,
  ).toRadixString(16);
  late final RxDouble danmakuOpacity = Pref.danmakuOpacity.obs;

  late List<double> speedList = Pref.speedList;
  late bool enableAutoLongPressSpeed = Pref.enableAutoLongPressSpeed;
  late final showControlDuration = Pref.enableLongShowControl
      ? const Duration(seconds: 30)
      : const Duration(seconds: 3);
  // 字幕
  late double subtitleFontScale = Pref.subtitleFontScale;
  late double subtitleFontScaleFS = Pref.subtitleFontScaleFS;
  late int subtitlePaddingH = Pref.subtitlePaddingH;
  late int subtitlePaddingB = Pref.subtitlePaddingB;
  late double subtitleBgOpacity = Pref.subtitleBgOpacity;
  final bool showVipDanmaku = Pref.showVipDanmaku; // loop unswitching
  late double subtitleStrokeWidth = Pref.subtitleStrokeWidth;
  late int subtitleFontWeight = Pref.subtitleFontWeight;

  // settings
  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final darkVideoPage = Pref.darkVideoPage;
  late final enableSlideVolumeBrightness = Pref.enableSlideVolumeBrightness;
  late final enableSlideFS = Pref.enableSlideFS;
  late final enableDragSubtitle = Pref.enableDragSubtitle;
  late final fastForBackwardDuration = Duration(
    seconds: Pref.fastForBackwardDuration,
  );

  late final horizontalSeasonPanel = Pref.horizontalSeasonPanel;
  late final preInitPlayer = Pref.preInitPlayer;
  late final showRelatedVideo = Pref.showRelatedVideo;
  late final showVideoReply = Pref.showVideoReply;
  late final showBangumiReply = Pref.showBangumiReply;
  late final reverseFromFirst = Pref.reverseFromFirst;
  late final horizontalPreview = Pref.horizontalPreview;
  late final showDmChart = Pref.showDmChart;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final keyboardControl = Pref.keyboardControl;
  late final uiScale = Pref.uiScale;

  late final bool autoEnterFullScreen = Pref.autoEnterFullScreen;
  late final bool autoExitFullscreen = Pref.autoExitFullscreen;
  late final bool autoPlayEnable = Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  late final bool tempPlayerConf = Pref.tempPlayerConf;

  late int? cacheVideoQa = PlatformUtils.isMobile ? null : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;
  late final String? hwdec = Pref.enableHA ? Pref.hardwareDecoding : null;

  late final progressType = Pref.btmProgressBehavior;
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale => isRelative ? durationInMilliseconds * offset : offset;

  // 播放顺序相关
  late PlayRepeat playRepeat = Pref.playRepeat;

  TextStyle get subTitleStyle => TextStyle(
    height: 1.5,
    fontSize:
        16 * (isFullScreen.value ? subtitleFontScaleFS : subtitleFontScale),
    letterSpacing: 0.1,
    wordSpacing: 0.1,
    color: Colors.white,
    fontWeight: FontWeight.values[subtitleFontWeight],
    backgroundColor: subtitleBgOpacity == 0
        ? null
        : Colors.black.withValues(alpha: subtitleBgOpacity),
  );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = getSubConfig.obs;

  SubtitleViewConfiguration get getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    return SubtitleViewConfiguration(
      style: subTitleStyle,
      strokeStyle: subtitleBgOpacity == 0
          ? subTitleStyle.copyWith(
              color: null,
              background: null,
              backgroundColor: null,
              foreground: Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = subtitleStrokeWidth,
            )
          : null,
      padding: EdgeInsets.only(
        left: subtitlePaddingH.toDouble(),
        right: subtitlePaddingH.toDouble(),
        bottom: subtitlePaddingB.toDouble(),
      ),
      textScaleFactor: 1,
    );
  }

  void updateSubtitleStyle() {
    subtitleConfig.value = getSubConfig;
  }

  void onUpdatePadding(EdgeInsets padding) {
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    putSubtitleSettings();
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(
    PlayCallback? playCallBack, {
    PlayOwner? playOwner,
  }) {
    _playCallBack = playCallBack;
    _playOwner = playOwner;
  }

  static PlayOwner? _playOwner;
  static PlayOwner? get playOwner => _playOwner;
  static PlayCallback? _playCallBack;

  static Future<void>? playIfExists() {
    return _playCallBack?.call();
  }

  // try to get PlayerStatus
  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus;
  }

  static Future<void>? pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) {
    if (_instance?.playerStatus.isPlaying ?? false) {
      return _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
    return null;
  }

  static Future<void>? seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) {
    return _instance?.seekTo(position, isSeek: isSeek);
  }

  static double? getVolumeIfExists() {
    return _instance?.volume.value;
  }

  static Future<void>? setVolumeIfExists(
    double volumeNew, {
    bool showIndicator = true,
  }) {
    return _instance?.setVolume(volumeNew, showIndicator: showIndicator);
  }

  Box video = GStorage.video;

  bool visible = true;

  DeviceOrientation? _orientation;
  late final checkIsAutoRotate = Platform.isAndroid && mode != .gravity;
  StreamSubscription<OrientationParams>? _orientationListener;

  void _stopOrientationListener() {
    _orientationListener?.cancel();
    _orientationListener = null;
  }

  void _onOrientationChanged(OrientationParams param) {
    _orientation = param.orientation;
    if (Platform.isIOS && !visible) return;
    final orientation = param.orientation;
    final isFullScreen = this.isFullScreen.value;
    if (checkIsAutoRotate &&
        param.isAutoRotate != true &&
        (!isFullScreen ||
            _isVertical ||
            orientation == .portraitUp ||
            orientation == .portraitDown)) {
      return;
    }
    switch (orientation) {
      case .portraitUp:
        if (!_isVertical && controlsLock.value) return;
        if (!horizontalScreen && !_isVertical && isFullScreen) {
          if (!isManualFS) {
            triggerFullScreen(status: false, orientation: orientation);
          }
        } else {
          portraitUpMode();
        }
      case .portraitDown:
        if (!horizontalScreen) return;
        if (!_isVertical && controlsLock.value) return;
        portraitDownMode();
      case .landscapeLeft:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeLeftMode();
        }
      case .landscapeRight:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeRightMode();
        }
    }
  }

  // 添加一个私有构造函数
  PlPlayerController._() {
    if (PlatformUtils.isMobile) {
      _orientationListener = NativeDeviceOrientationPlatform.instance
          .onOrientationChanged(
            checkIsAutoRotate: checkIsAutoRotate,
            angleDegrees: Platform.isAndroid ? Pref.angleDegrees : null,
          )
          .listen(_onOrientationChanged);
    }

    if (!Accounts.heartbeat.isLogin || Pref.historyPause) {
      enableHeart = false;
    }

    if (Platform.isAndroid && autoPiP) {
      if (DeviceUtils.sdkInt < 31) {
        final func = Runnable.implement($Runnable(run: _onUserLeaveHint));
        AndroidHelper$ToDart.onUserLeaveHint = func;
        func.release();
      } else {
        _isAutoEnterPip = true;
      }
    } else if (Platform.isIOS && autoPiP && IOSPipHelper.isAvailable) {
      _isAutoEnterPip = true;
    }
  }

  void _onUserLeaveHint() {
    if (playerStatus.isPlaying && _isCurrVideoPage) {
      enterPip();
    }
  }

  // 获取实例 传参
  static PlPlayerController getInstance({bool isLive = false}) {
    // 如果实例尚未创建，则创建一个新实例
    return (_instance ??= PlPlayerController._())
      ..isLive = isLive
      .._playerCount += 1;
  }

  bool _processing = false;
  bool get processing => _processing;

  // offline
  bool get isFileSource => dataSource is FileSource;

  // 初始化资源
  Future<void> setDataSource(
    DataSource dataSource, {
    bool isLive = false,
    bool autoplay = true,
    // 初始化播放位置
    Duration? seekTo,
    // 初始化播放速度
    double speed = 1.0,
    int? width,
    int? height,
    Duration? duration,
    // 方向
    bool? isVertical,
    // 记录历史记录
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    VideoType? videoType,
    VoidCallback? onInit,
    Volume? volume,
    bool autoFullScreenFlag = false,
  }) async {
    try {
      _processing = true;
      // 装载会让 buffered 归零，显式重置看门狗：切换可能在 1 s 内结束，
      // ticker 来不及采样到 _processing。
      _resetStallWatchdog();
      this.isLive = isLive;
      _videoType = videoType ?? VideoType.ugc;
      this.width = width;
      this.height = height;
      this.dataSource = dataSource;
      _autoPlay = autoplay;
      // 初始化数据加载状态
      dataStatus.value = DataStatus.loading;
      // 初始化全屏方向
      _isVertical = isVertical ?? false;
      _aid = aid;
      _bvid = bvid;
      this.cid = cid;
      _epid = epid;
      _seasonId = seasonId;
      _pgcType = pgcType;

      if (showSeekPreview) {
        _clearPreview();
      }
      cancelLongPressTimer();
      if (_videoPlayerController != null &&
          _videoPlayerController!.state.playing) {
        await pause(notify: false);
      }

      if (_playerCount == 0) {
        return;
      }
      // 配置Player 音轨、字幕等等
      await _createVideoController(dataSource, seekTo, volume);

      if (_playerCount == 0) {
        _removeListeners();
        _videoPlayerController?.dispose();
        _videoPlayerController = null;
        _videoController = null;
        return;
      }

      updateDuration(duration ?? _videoPlayerController!.state.duration);
      position.value = buffered.value = seekTo?.inSeconds ?? 0;

      dataStatus.value = .loaded;

      if (autoFullScreenFlag && autoEnterFullScreen) {
        triggerFullScreen(status: true);
      }

      await _initializePlayer();
      onInit?.call();
    } catch (err, stackTrace) {
      dataStatus.value = DataStatus.error;
      if (kDebugMode) {
        debugPrint(stackTrace.toString());
        debugPrint('plPlayer err:  $err');
      }
    } finally {
      _processing = false;
    }
  }

  String? shadersDirPath;
  Future<String> get copyShadersToExternalDirectory async {
    if (shadersDirPath != null) {
      return shadersDirPath!;
    }

    return shadersDirPath = await AssetUtils.getOrCopy(
      'assets/shaders',
      Assets.mpvAnime4KShaders.followedBy(Assets.mpvAnime4KShadersLite),
      path.join(appSupportDirPath, 'anime_shaders'),
    );
  }

  late final isAnim = _pgcType == 1 || _pgcType == 4;
  late final Rx<SuperResolutionType> superResolutionType =
      (isAnim ? Pref.superResolutionType : SuperResolutionType.disable).obs;
  Future<void> setShader([SuperResolutionType? type, NativePlayer? pp]) async {
    if (type == null) {
      type = superResolutionType.value;
    } else {
      superResolutionType.value = type;
      if (isAnim && !tempPlayerConf) {
        setting.put(SettingBoxKey.superResolutionType, type.index);
      }
    }
    pp ??= _videoPlayerController!;
    switch (type) {
      case SuperResolutionType.disable:
        return pp.command(const ['change-list', 'glsl-shaders', 'clr', '']);
      case SuperResolutionType.efficiency:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShadersLite,
          ),
        ]);
      case SuperResolutionType.quality:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShaders,
          ),
        ]);
    }
  }

  Future<Player> _initPlayer() async {
    assert(_videoPlayerController == null);
    final opt = {
      'video-sync': Pref.videoSync,
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      'volume':
          (PlatformUtils.isMobile ? Pref.playerVolume : volume.value * 100)
              .toString(),
    };
    final autosync = Pref.autosync;
    if (autosync != '0') {
      opt['autosync'] = autosync;
    }

    final player = await Player.create(
      configuration: PlayerConfiguration(
        // mpv 的 `v` 档（含 fatal/error/warn/info/v）里才有轨道表、解码器初始化、
        // 视频输出、hwdec —— 播放器类故障（例如"只有声音没画面"）的唯一证词在
        // 这里，光靠 PiliPlus 的 debugPrint 查不出来。
        //
        // 但它是**全局最吵的一档**，且现在每一行都要落盘，所以两个条件都满足才开：
        // 日志确实在落盘（否则收了也没地方放），且用户显式开了 [Pref.mpvVerboseLog]。
        // 默认档不放宽：那次黑屏已经修了，不能为了"万一以后再出"让所有人一直付
        // 电量和存储的账。error 及以上在默认档里照样记。
        logLevel: consoleLogActive && Pref.mpvVerboseLog
            ? .v
            : (kDebugMode ? .warn : .error),
        options: opt,
      ),
    );

    assert(_videoController == null);

    _videoController = await VideoController.create(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: hwdec != null,
        // Size the Android surface before rendering a paused first frame.
        androidAttachSurfaceAfterVideoParameters: true,
        hwdec: hwdec,
      ),
    );

    if (Platform.isAndroid) {
      // Avoid sizing the surface using mpv's idle window between media loads.
      player.setProperty('force-window', 'no');
    }

    player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);

    _startListeners(player);

    return player;
  }

  late final buffer = Pref.initBuffer(_playbackSpeed.value);
  late final liveBuffer = Pref.initLiveBuffer();

  // 配置播放器
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume,
  ) async {
    isBuffering.value = false;
    _heartDuration = 0;
    danmakuController?.clear();
    // 换了媒体，「音频在、画面不在」的计数与自愈额度都重新来过。
    _noVideoProbes = 0;
    _noVideoHealed = false;

    var player = _videoPlayerController;

    if (player == null) {
      player = await _initPlayer();
      if (_playerCount == 0) {
        _removeListeners();
        player.dispose();
        player = null;
        _videoController = null;
        return;
      }
      _videoPlayerController = player;
      if (isAnim && superResolutionType.value != .disable) {
        await setShader();
      }
    }

    final Map<String, String> extras = {
      if (dataSource is FileSource)
        'cache': 'no'
      else if (isLive)
        ...liveBuffer
      else
        ...buffer,
    };

    String video = dataSource.videoSource;
    if (dataSource.audioSource case final audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        // dely_open need provide length
        video =
            ('edl://'
            '!no_chapters;'
            // '!delay_open,media_type=video;'
            '%${isFileSource ? utf8.encode(video).length : video.length}%$video;'
            '!new_stream;!no_chapters;'
            // '!delay_open,media_type=audio;'
            '%${isFileSource ? utf8.encode(audio).length : audio.length}%$audio');
      }
      audioFilterExtras(volume, map: extras);
    }

    assert(!isLive || seekTo == null);
    await player.open(
      Media(
        video,
        start: seekTo,
        extras: extras.isEmpty ? null : extras,
      ),
      play: false,
    );
  }

  Future<void>? refreshPlayer() {
    if (dataSource is FileSource) {
      return null;
    }
    // 重新打开同一个 Media，缓冲从头再来，看门狗同步重置。
    _resetStallWatchdog();
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      var media = ctr.current.last;
      if (!isLive) media = media.copyWith(start: ctr.state.position);
      return ctr.open(media, play: true);
    }
    return null;
  }

  // 开始播放
  Future<void> _initializePlayer() async {
    if (_instance == null) return;
    // 设置倍速
    if (_videoPlayerController != null) {
      final speed = isLive ? 1.0 : playbackSpeed;
      if (_videoPlayerController!.state.rate != speed) {
        await setPlaybackSpeed(speed);
      }
    }
    _initVideoFit();

    // 自动播放
    if (_autoPlay) {
      playIfExists();
    }
  }

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};

  Timer? _wakeLockTimer;

  void _startWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = Timer(
      const Duration(milliseconds: 500),
      _stopWakeLock,
    );
  }

  void _stopWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = null;
  }

  void _stopWakeLock() {
    WakelockPlus.disable();
    _updatePlaybackState(debugLabel: 'onVideoPaused');
  }

  void _updatePlaybackState({Duration? position, String? debugLabel}) {
    videoPlayerServiceHandler?.onUpdateState(
      playerStatus,
      isBuffering.value,
      isLive,
      position: position ?? _videoPlayerController!.state.position,
      speed: playbackSpeed,
      debugLabel: debugLabel,
    );
    _updateIOSPip(position);
  }

  /// 播放事件监听
  void _startListeners(NativePlayer player) {
    assert(_subscriptions == null);
    final stream = player.stream;
    _subscriptions = [
      /// playing
      stream.playing.listen((bool playing) {
        if (playing) {
          playerStatus = .playing;
          _stopWakeLockTimer();
          _updatePlaybackState();
          WakelockPlus.enable();

          if (_isAutoEnterPip) {
            if (_isCurrVideoPage) {
              enterPip(autoEnter: true);
            } else {
              _disableAutoEnterPip();
            }
          }
        } else {
          playerStatus = .paused;
          _startWakeLockTimer();
          _disableAutoEnterPip();
          _updateIOSPip();
        }

        for (final element in _statusListeners) {
          element(playing ? .playing : .paused);
        }

        final seconds = videoPlayerController!.state.position.inSeconds;
        if (seconds != 0) {
          makeHeartBeat(seconds, type: .status);
        }
      }),

      ///completed
      stream.completed.listen((bool completed) {
        if (completed) {
          playerStatus = .completed;
          _startWakeLockTimer();

          for (final element in _statusListeners) {
            element(.completed);
          }

          makeHeartBeat(-1, type: .completed);
        }
      }),

      /// position
      stream.position.listen((Duration position) {
        final posInSeconds = position.inSeconds;

        if (posInSeconds != this.position.value) {
          if (posInSeconds == 0 && playerStatus.isPlaying) {
            _updatePlaybackState(position: position);
          }

          this.position.value = posInSeconds;

          makeHeartBeat(posInSeconds);
        }

        for (final element in _positionListeners) {
          element(position);
        }
      }),
      stream.duration.listen((Duration duration) {
        updateDuration(duration);
        _updateIOSPip();
      }),
      stream.buffer.listen((Duration buffer) {
        buffered.value = buffer.inSeconds;
      }),
      stream.buffering.listen((bool buffering) {
        isBuffering.value = buffering;
        if (!playerStatus.isCompleted) {
          _stopWakeLockTimer();
          _updatePlaybackState();
        }
      }),
      // 只要日志能落盘就收 mpv 的日志，release 也不例外 —— 否则事后取回来的
      // pili-console.log 里会"什么都没有"，那是通道没开，不是没有问题。
      // 注意这里收到多少由 mpv 自己的档位决定（见上面的 `logLevel`）：默认档下
      // 只有 error 及以上会到这儿，那正是最该落盘的一批，所以订阅本身不跟着关。
      if (kDebugMode || consoleLogActive)
        stream.log.listen(((PlayerLog log) {
          if (log.level == 'error' || log.level == 'fatal') {
            Utils.reportError(
              '${log.level}: ${log.prefix}: ${log.text}\n${player.state.playlist}',
              null,
            );
          }
          // 错误也落盘：以前 error 只走 reportError，日志文件里反而看不到。
          debugPrint('mpv [${log.level}] ${log.prefix}: ${log.text}');
        })),
      stream.error.listen((String event) {
        // 这一条在 release 里原本只走 reportError，日志文件里同样看不到 ——
        // 而它正是"流打不开"的直接证词，先落盘，再走原来的恢复逻辑。
        debugPrint('mpv error: $event');
        if (dataSource is FileSource &&
            event.startsWith("Failed to open file")) {
          return;
        }
        if (isLive) {
          if (event.startsWith('tcp: ffurl_read returned ') ||
              event.startsWith("Failed to open https://") ||
              event.startsWith("Can not open external file https://")) {
            Timer(const Duration(milliseconds: 3000), refreshPlayer);
          }
          return;
        }
        if (event.startsWith("Failed to open https://") ||
            event.startsWith("Can not open external file https://") ||
            //tcp: ffurl_read returned 0xdfb9b0bb
            //tcp: ffurl_read returned 0xffffff99
            event.startsWith('tcp: ffurl_read returned ')) {
          EasyThrottle.throttle(
            'controllerStream.error.listen',
            const Duration(milliseconds: 10000),
            () {
              Timer(const Duration(milliseconds: 3000), () {
                // if (kDebugMode) {
                //   debugPrint("isBuffering.value: ${isBuffering.value}");
                // }
                // if (kDebugMode) {
                //   debugPrint("_buffered.value: ${_buffered.value}");
                // }
                // `buffered == 0` 只有还没起播时才成立（见 [buffered] 的注释），
                // 所以这条"打开失败就重试"的恢复路径原本一次都没跑过，跟看门狗
                // 犯的是同一个错。要判断的是前方余量，而且别在 seek 中途重载。
                if ((bufferedAhead <= 0 || telemetryDiverged) &&
                    !isSeeking.value) {
                  SmartDialog.showToast(
                    '视频链接打开失败，重试中',
                    displayTime: const Duration(milliseconds: 500),
                  );
                  refreshPlayer();
                }
              });
            },
          );
        } else if (event.startsWith('Could not open codec')) {
          SmartDialog.showToast('无法加载解码器, $event，可能会切换至软解');
        } else if (!onlyPlayAudio.value) {
          if (event.startsWith("error running") ||
              event.startsWith("Failed to open .") ||
              event.startsWith("Cannot open") ||
              event.startsWith("Can not open")) {
            return;
          }
          if (!kDebugMode) {
            Utils.reportError('$event\n${player.state.playlist}');
          }
          // SmartDialog.showToast('视频加载错误, $event');
        }
      }),
    ];
    _startStallTicker();
  }

  /// 连续多少探"音频在、画面不在"。见 [_checkNoVideoTrack]。
  int _noVideoProbes = 0;

  /// 上一次采样时刻。自带 [_kNoVideoProbe] 的节奏，不等 10s 心跳。
  DateTime _lastNoVideoProbe = DateTime.fromMillisecondsSinceEpoch(0);

  /// 本次媒体是否已经跑过一轮自愈。每换一次媒体在 [_createVideoController]
  /// 里重置 —— 一轮就够，别跟用户的手动操作抢。
  bool _noVideoHealed = false;

  /// 自愈是否正在跑（里面有 await，采样回调可能重入）。
  bool _healingNoVideo = false;

  /// 读一个 mpv 属性，读不到就当空串。
  ///
  /// [NativePlayer.getProperty] 在 player 已 dispose 时会抛，而这里是定时器
  /// 回调，抛出去没人接 —— 诊断代码绝不能把播放搞挂。
  String _safeProp(String name) {
    try {
      return _videoPlayerController?.getProperty(name) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 「只有声音没画面」的现场判据。
  ///
  /// 音频参数正常、视频轨却始终为空 —— 这正是 2026-10-11 那次 iOS 黑屏的形态
  /// （当时拍到的「播放信息」里 Resolution 0x0、VideoParams 全空），而 CDN 与
  /// 编码可用性都已排除。build 5483 的 mpv 日志把病因定到了**视频输出**一侧：
  /// 解码、滤镜、音轨全部正常，唯独那一次没有建出视频输出 —— 日志里没有
  /// `VO: [libmpv]` / `vo/libmpv: reconfig` / `libmpv_render: Window size` 这三行。
  /// （别拿 `mpv_render_context_render() not being called or stuck.` 当判据：
  /// 正常播放的每一段里都有它，只是排队晚了一点点。）
  /// 以前这个状态一行日志都不留，只能靠用户手动抄「播放信息」；现在它自己会
  /// 连着 [_kNoVideoProbes] 探报到日志里，并触发一次 [_healNoVideoTrack]。
  ///
  /// 连空几探才算：视频参数本来就比音频晚到，起播那一两探看到空属于正常。
  /// 采样从 10s 心跳提到 2s 之后，seek / 换源 / 重新缓冲这三个"参数本来就该
  /// 是空的"窗口必须显式放过，否则会把自己的动作当成死锁。
  void _checkNoVideoTrack() {
    if (onlyPlayAudio.value ||
        isLive ||
        position.value <= 0 ||
        isSeeking.value ||
        _processing ||
        isBuffering.value) {
      _noVideoProbes = 0;
      return;
    }
    if (_hasVideoTrack) {
      _noVideoProbes = 0;
      return;
    }
    if (++_noVideoProbes < _kNoVideoProbes) return;
    debugPrint(
      '无视频轨: 音频正常但画面始终为空 (audio ${_safeProp('audio-codec')} '
      'video ${_safeProp('video-codec')} hwdec ${_safeProp('hwdec-current')} '
      '位置 ${position.value}s)${_noVideoHealed ? ' [本次媒体已自愈过]' : ''}',
    );
    if (!_noVideoHealed) {
      _noVideoHealed = true;
      _healNoVideoTrack();
    }
  }

  /// 画面是否已经起来。判据与 [_checkNoVideoTrack] 相同：宽或视频参数任一非零。
  bool get _hasVideoTrack {
    final state = _videoPlayerController?.state;
    return (state?.width ?? 0) > 0 || (state?.videoParams.w ?? 0) > 0;
  }

  /// 「只有声音没画面」的自愈。
  ///
  /// 病根在 media_kit 的 iOS 视频输出一侧，不在流、不在解码器：
  /// `VideoOutput._updateCallback` 只在 mpv 的 `video-out-params` 报出非零 dw/dh
  /// 时才去 `texture.render()` —— 也就是只有在视频输出**已经配好之后**它才会去
  /// 驱动 `mpv_render_context_render`。于是只要某次加载停在"输出还没配、参数还
  /// 是空"的状态上，两边就互等成死锁：mpv 一直抱怨没人调 render，画面永远不出
  /// 来；而音频走的是独立的 AO，所以听得到声音、看不到画面。
  ///
  /// 只有一个动作：**钉住输出尺寸**。这直接绕过上面那个判断 —— 尺寸由我们从
  /// demuxer 那边取来（见 [_nudgeSize]），mpv 报不报都不影响 —— 一次 render
  /// 就能让 mpv 把视频输出配上，随后立刻把尺寸交还 mpv 自己算。
  ///
  /// 5484 那次线上验证把另外两级砍掉了，它们不修病、只伤身（详情见下面）。
  /// 全败也不算白跑：日志会记下放弃，用户手动退出视频页再进来仍然能恢复 ——
  /// 那会新建渲染上下文，是这个死锁的另一条出路。
  Future<void> _healNoVideoTrack() async {
    if (_videoPlayerController == null || _healingNoVideo) {
      return;
    }
    _healingNoVideo = true;
    final (w, h) = _nudgeSize;

    /// 把尺寸交还 mpv：钉住只是为了松开死锁，一直挂着会让竖屏这类非 16:9
    /// 的视频按错的尺寸渲染。
    Future<void> unpin() async {
      try {
        await videoController?.setSize(width: null, height: null);
      } catch (e) {
        debugPrint('无视频轨自愈收尾抛错: $e');
      }
    }

    try {
      for (var attempt = 1; attempt <= _kHealAttempts; attempt++) {
        debugPrint(
          '无视频轨自愈 $attempt/$_kHealAttempts: 钉住输出尺寸 ${w}x$h '
          '(位置 ${position.value}s)',
        );
        try {
          await videoController?.setSize(width: w, height: h);
        } catch (e) {
          debugPrint('无视频轨自愈 $attempt/$_kHealAttempts 抛错: $e');
        }
        await Future.delayed(_kHealWait);
        if (_hasVideoTrack) {
          debugPrint('无视频轨自愈成功: 钉住输出尺寸（第 $attempt 次）');
          return;
        }
        // 先交还再重来：第一次 render 可能正好落在 mpv 拆完旧输出、新输出
        // 还没建好的缝里。重来一次不 seek、不重载、不动位置，几乎不要钱。
        // 只在"还要再来一次"时交还 —— 最后一趟的收尾由下面 finally 负责，
        // 否则同一个 setSize(null) 会白发两遍，多一次 render 往返。
        if (attempt < _kHealAttempts) await unpin();
      }
      debugPrint('无视频轨自愈失败: 钉住尺寸没能让视频输出起来，退出视频页再进来可恢复');
    } finally {
      await unpin();
      _healingNoVideo = false;
    }
  }

  /// 钉尺寸用的尺寸。
  ///
  /// 优先取 demuxer 报的轨道尺寸：`track-list/<n>/demux-w` 不依赖视频输出就有效
  /// （竖屏视频也报得对），而 `video-params` 此刻正是空的 —— 那正是病根。
  /// 全都读不到就退回 16:9：这一步只求非零，够把死锁松开就行。
  (int, int) get _nudgeSize {
    for (var i = 0; i < 4; i++) {
      final w = int.tryParse(_safeProp('track-list/$i/demux-w')) ?? 0;
      final h = int.tryParse(_safeProp('track-list/$i/demux-h')) ?? 0;
      if (w > 0 && h > 0) return (w, h);
    }
    return (1920, 1080);
  }

  // 5484 上线前这里还有两级，线上日志把它们的账算清楚了，别再捡回来：
  //
  //   1. `vid=no` → `auto`（重挂视频轨）：**不修病，还有声音代价**。它强制
  //      视频轨重挂 → `timeline: refresh seek` → 缓冲从 100% 掉到 0% →
  //      `Audio device underrun detected`（耳朵能听到的一声爆音），而且会把
  //      位置往回拖到上一个关键帧（实测 14.1s → 10.0s）。画面照样是黑的。
  //   2. `video-reload`：**直接报错，还把解码器搞坏**。命令本身返回
  //      `mpv error: error running command`；之后是 92 条
  //      `hevc: Could not find ref with POC …` + `Failed to decode frame
  //      (invalid session, -12903)`，硬解从 videotoolbox 掉到
  //      videotoolbox-copy。这个 EDL 流 mpv 自己都说了 `Stream is not
  //      seekable`，中途重载视频流就是会丢参考帧。
  //
  // 而第 3 级（钉尺寸）在那一刻干净地修好了：`VO: [libmpv]` / `reconfig` /
  // `libmpv_render: Window size` 三行是在它触发时才第一次出现的。

  /// 卡顿看门狗：前两条判据共用一个 [onStall] 回调，第三条走 [onBufferStarve]。
  ///
  /// 1. 位置连续 [_kStallSeconds] 秒没有推进，再以 [isBuffering] 作确认。
  ///    不能只看 [isBuffering] —— 普通重新缓冲也会让它为 true，会造成切换风暴。
  /// 2. [_sampleRebuffer]：窗口内缓冲归零的上升沿达到 [_kRebufferTrigger] 次。
  ///    判据 1 看不到反复小卡顿（位置一恢复就清零），由判据 2 补上。
  /// 3. [_sampleStarve]：前向缓冲长期趴在低位。判据 1、2 都要求 buffered 归零，
  ///    而 mpv 有 cache-secs 打底、换源型卡顿时位置又由音频时钟推着走，
  ///    两者都见不到"余量在变少"——这条只看 [buffered]，是唯一的早期信号。
  ///
  /// 也不能用 `progress`：seek 期间它返回 seekPosition，必须用原始的 [position]。
  void _startStallTicker() {
    _stallTicker?.cancel();
    _resetStallWatchdog();
    _stallTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      // 心跳放在闸门之前：闸门本身也可能是"什么都不发生"的原因之一，
      // 必须先看到它当时的取值。
      final now = DateTime.now();
      if (now.difference(_lastHeartbeat).inSeconds >= _kHeartbeatSeconds) {
        _lastHeartbeat = now;
        debugPrint(
          'CDN 看门狗: 余量 ${bufferedAhead}s 阈值 '
          '${_starveThresholdSec.toStringAsFixed(1)}s 位置 ${position.value}s '
          '(cache-time ${buffered.value}s) 播放中 ${playerStatus.isPlaying} '
          '重新缓冲 ${isBuffering.value} seek中 ${isSeeking.value} '
          '换源中 $_processing '
          // 播放器侧的现场。以前这一行只有 CDN 的数字，于是"只有声音没画面"
          // 事后必须靠用户手动开「播放信息」抄 VideoParams 才判断得出来。
          '| video-codec ${_safeProp('video-codec')} '
          'audio-codec ${_safeProp('audio-codec')} '
          'hwdec ${_safeProp('hwdec-current')} '
          '${_videoPlayerController?.state.width}x'
          '${_videoPlayerController?.state.height}',
        );
      }
      // 「无视频轨」自己一档 2s 的节奏。挂在 10s 心跳上要等两拍才敢动手，
      // 而黑屏是死锁 —— 那 20s 纯粹是对着黑屏干等。
      if (now.difference(_lastNoVideoProbe) >= _kNoVideoProbe) {
        _lastNoVideoProbe = now;
        _checkNoVideoTrack();
      }
      if (isLive ||
          dataSource is FileSource ||
          !playerStatus.isPlaying ||
          isSeeking.value ||
          _processing) {
        // seek 和换源本身就会让缓冲归零，静默一段，别把自己的动作记成卡顿。
        if (isSeeking.value || _processing) {
          _armRebufferSuppress();
        }
        _stallLastSecond = position.value;
        _stallFrozen = 0;
        // 这里刻意不整套换成 [_disarmTriggers]：它连 [_wasEmpty] 一起清，
        // 而暂停正好停在一次卡顿中间时，恢复后的第一次归零不该被当成新的一次。
        // [_wasEmpty] 只在真正的装载边界和静默期起点重置。
        _wasStalled = false;
        _starveSeconds = 0;
        // 换源后是全新一轮，允许再报一次。
        _starveFired = false;
        return;
      }
      _sampleRebuffer(now);
      _sampleStarve(now);
      if (position.value != _stallLastSecond) {
        _stallLastSecond = position.value;
        _stallFrozen = 0;
        return;
      }
      if (++_stallFrozen >= _kStallSeconds &&
          isBuffering.value &&
          bufferedAhead == 0) {
        _stallFrozen = 0;
        onStall?.call(videoPlayerController?.state.position ?? Duration.zero);
      }
    });
  }

  /// 清空三条判据的状态并进入静默期。任何一次装载（开播、换源、换 P、切换
  /// CDN）都会让 buffered 归零，必须显式调用——只靠 ticker 里看到
  /// `_processing` 是不可靠的：一次切换可能不到 1 秒就结束，ticker 根本没机会
  /// 采样，静默期没被续上，紧接着的饥饿就会被误判成新的。
  void _resetStallWatchdog() {
    _stallLastSecond = position.value;
    _stallFrozen = 0;
    _rebufferEvents.clear();
    _armRebufferSuppress();
  }

  /// 重新武装三条判据的去重状态，效果等同于刚装载。
  ///
  /// 静默期的含义是"这段时间里的归零一律不算数"：只要进入静默时不把"已归零/
  /// 已上报"的记录一并清掉，静默结束后的第一次归零就会被读成"还没报过"。
  /// 两个采样函数因此只在静默期内返回，武装统一收敛到这里。
  void _disarmTriggers() {
    _wasStalled = false;
    _wasEmpty = false;
    _starveSeconds = 0;
    _starveFired = false;
  }

  /// 进入/推进静默期。任何一次装载（开播、换源、换 P、切换 CDN）以及 seek
  /// 都会让缓冲归零，必须先把这段时间静音掉，否则等长冻结判据会把自己的动作
  /// 读成卡顿。
  void _armRebufferSuppress() {
    _rebufferSuppressUntil = DateTime.now().add(_kRebufferSuppress);
    _disarmTriggers();
  }

  /// 饥饿阈值：mpv 回填水位（`demuxer-hysteresis-secs`）的
  /// [_kStarveFloorFraction]。低于 [_kStarveMinSeconds] 视为没有观测余量，
  /// 返回 0 表示不启用。
  ///
  /// 取值要从 mpv 真正拿到的 [buffer] 里读，而不是用当前倍速重算：`buffer` 是
  /// 首次装载时定下的 late final，[setPlaybackSpeed] 不会重建它，两者会不一致
  /// （例如按 1x 装载后改成 2x，水位仍是按 1x 算的，而缓冲消耗速度已翻倍）。
  double get _starveThresholdSec {
    final floor = double.tryParse(buffer['demuxer-hysteresis-secs'] ?? '') ?? 0;
    final threshold = floor * _kStarveFloorFraction;
    return threshold < _kStarveMinSeconds ? 0 : threshold;
  }

  /// 是否已进入片尾 —— 剩余时长不足 [_starveThresholdSec]。
  ///
  /// 判据 2（[bufferedAhead] 归零的上升沿）和判据 3（缓冲饥饿）在片尾都
  /// **必然**成立，跟网速多快无关：[bufferedAhead] 是
  /// `demuxer-cache-time - position`，而 cache-time 不可能超过文件总长，所以
  /// `bufferedAhead <= 剩余时长` 恒成立 —— 播放位置一进最后 `threshold` 秒，
  /// 余量就必定掉到阈值以下并最终归零。片尾也无源可换（没有剩余数据要下）。
  ///
  /// 实测两次误报都严丝合缝卡在这个边界上：145.403s 的视频从 133s 起计数
  /// （剩余 12.4s）误报 `缓冲饥饿`、@145s 误报 `余量归零`；95.712s 的视频
  /// 分别在 83s（剩余 12.7s）和 @95s 各一次。
  ///
  /// 用 `<` 而不是 `<=`：position / duration 都是整秒，剩余 13s 时余量真的
  /// 低于阈值仍是有效观测，只放过可证明为假的那一档。duration 为 0（直播 /
  /// 时长未知）时返回 false —— 那类流没有片尾。
  bool get _atFileTail {
    final threshold = _starveThresholdSec;
    if (threshold <= 0 || duration.value <= 0) return false;
    return duration.value - position.value < threshold;
  }

  /// 失真阈值：mpv 缓存上限 `cache-secs` 的 [_kDivergedFactor] 倍。读不到就
  /// 不启用（返回 0）—— 直播走的是 [liveBuffer]，压根没有这个键，本地点播
  /// 文件更是 `cache: no`，两者的 `demuxer-cache-time` 语义本来也不同，不该
  /// 套这条判据。跟 [_starveThresholdSec] 用"返回 0 表示不启用"是同一套约定。
  double get _divergedAheadSec {
    final cache = double.tryParse(buffer['cache-secs'] ?? '') ?? 0;
    return cache > 0 ? cache * _kDivergedFactor : 0;
  }

  /// 判据 3：只盯 [bufferedAhead]，不看位置也不要求 [isBuffering]——换源型卡顿
  /// 时位置一直在推进，core-idle / paused-for-cache 也未必为真。两头都要防：
  /// 余量长期趴在低位是"供不上"，余量涨到 [telemetryDiverged] 是"遥测被音频
  /// 拖走了"，后者正是"只有声音、画面冻住"。
  ///
  /// 每段饥饿只上报一次，直到缓冲真的补回 mpv 自己的水位才算结束。
  ///
  /// **片尾必须放行**：`bufferedAhead` 的上界就是剩余时长，所以视频最后
  /// `threshold` 秒里这条判据*必然*成立，跟网速多快无关（推导见 [_atFileTail]）。
  void _sampleStarve(DateTime now) {
    final threshold = _starveThresholdSec;
    // 静默期内不采样：加载/换源/seek 之后 buffered 本来就是 0。去重状态在
    // 进入静默的那一处就重新武装好了（见 [_armRebufferSuppress]）。
    if (threshold <= 0 || now.isBefore(_rebufferSuppressUntil)) return;
    // 片尾放行：推导见 [_atFileTail]。归零是为了不让这点残数被 seek 回中段
    // 之后接着用。
    if (_atFileTail) {
      _starveSeconds = 0;
      return;
    }
    if (bufferedAhead < threshold) {
      if (++_starveSeconds < _kStarveSeconds || _starveFired) return;
      _starveFired = true;
      debugPrint(
        'CDN 缓冲饥饿: 前方余量 ${bufferedAhead}s < '
        '${threshold.toStringAsFixed(1)}s (连续 $_kStarveSeconds s) '
        '@${position.value}s',
      );
      onBufferStarve?.call(videoPlayerController?.state.position ?? Duration.zero);
      return;
    }
    _starveSeconds = 0;
    // 余量涨到失真：音频在走、画面冻着。`demuxer-cache-time` 被音频轨抬离了
    // 播放位置，余量因此超过缓存上限好几倍 —— 位置还在推进、[isBuffering]
    // 也是假，判据 1、2 都看不见，只有这里能拦住。同样每段只报一次。
    if (telemetryDiverged) {
      if (_starveFired) return;
      _starveFired = true;
      debugPrint(
        'CDN 遥测失真: 余量 ${bufferedAhead}s 超过缓存上限 '
        '${_divergedAheadSec.toStringAsFixed(1)}s 的 ${_kDivergedFactor}x '
        '(音频在走，画面已冻) @${position.value}s',
      );
      onBufferStarve?.call(videoPlayerController?.state.position ?? Duration.zero);
      return;
    }
    // 只有补回 mpv 自己的水位才算这段饥饿真的结束了。
    if (bufferedAhead >= threshold / _kStarveFloorFraction) {
      if (_starveFired) {
        debugPrint('CDN 缓冲饥饿: 已恢复 (${bufferedAhead}s)');
      }
      _starveFired = false;
    }
  }

  /// 统计"缓冲归零"的上升沿 —— 即加载中转圈出现的次数。
  ///
  /// 必须数上升沿而不是数采样：`buffered` 每次 stream.buffer 推送都会重写，
  /// 一秒内可能变几十次，数零值会把一次卡顿记成几十次。
  void _sampleRebuffer(DateTime now) {
    if (now.isBefore(_rebufferSuppressUntil)) return;
    // 片尾放行：推导见 [_atFileTail]。这里余量归零是必然而非故障，不放过的话
    // 每个视频的最后一秒都会误报一次"小卡顿"。_wasEmpty 不动 —— 片尾之外
    // 余量一涨回就会把它清掉，向后 seek 之后自然重新武装。
    if (_atFileTail) return;

    // 最敏感的一条：余量归零的上升沿立刻上报，不等 isBuffering、不等攒够次数。
    // 每一次归零只报一次，补回来才重新武装。
    if (bufferedAhead == 0) {
      if (!_wasEmpty) {
        _wasEmpty = true;
        debugPrint('CDN 余量归零 @${position.value}s，上报小卡顿');
        onRebuffer?.call(videoPlayerController?.state.position ?? Duration.zero);
      }
    } else {
      _wasEmpty = false;
    }

    final stalled = isBuffering.value && bufferedAhead == 0;
    if (stalled && !_wasStalled) {
      _rebufferEvents.add(now);
      _rebufferEvents.removeWhere((t) => now.difference(t) > _kRebufferWindow);
      debugPrint(
        'CDN 卡顿计数: ${_rebufferEvents.length}/$_kRebufferTrigger '
        '(窗口 ${_kRebufferWindow.inSeconds}s)',
      );
      if (_rebufferEvents.length >= _kRebufferTrigger) {
        _rebufferEvents.clear();
        onStall?.call(videoPlayerController?.state.position ?? Duration.zero);
      }
    }
    _wasStalled = stalled;
  }

  /// 移除事件监听
  void _removeListeners() {
    _stallTicker?.cancel();
    _stallTicker = null;
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
  }

  void _cancelSubForSeek() {
    if (_subForSeek != null) {
      _subForSeek!.cancel();
      _subForSeek = null;
    }
  }

  Future<void> seek(Duration position, {bool isSeek = false}) async {
    if (isSeek) {
      /// 拖动进度条调节时，不等待第一帧，防止抖动
      await _videoPlayerController?.stream.buffer.first;
    }
    danmakuController?.clear();
    try {
      await _videoPlayerController?.seek(position);
      _updateIOSPip(position);
    } catch (e) {
      if (kDebugMode) debugPrint('seek failed: $e');
    }
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position, {bool isSeek = true}) async {
    if (_playerCount == 0) {
      return;
    }
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    _heartDuration = position.inSeconds;

    if (duration.value != 0) {
      seek(position, isSeek: isSeek);
    } else {
      // if (kDebugMode) debugPrint('seek duration else');
      _subForSeek?.cancel();
      _subForSeek = duration.listen((_) {
        seek(position, isSeek: isSeek);
        _cancelSubForSeek();
      });
    }
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    lastPlaybackSpeed = playbackSpeed;

    if (speed == _videoPlayerController?.state.rate) return;

    await _videoPlayerController?.setRate(speed);
    if (!isLive) _playbackSpeed.value = speed;
    _updatePlaybackState();
    if (danmakuController != null) {
      try {
        danmakuController?.updateOption(
          danmakuController!.option.copyWith(
            duration: DanmakuOptions.danmakuDuration / speed,
            staticDuration: DanmakuOptions.danmakuStaticDuration / speed,
          ),
        );
      } catch (_) {}
    }
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (_playerCount == 0) return;
    // 播放时自动隐藏控制条
    controls = !hideControls;
    // repeat为true，将从头播放
    if (repeat) {
      await seekTo(Duration.zero, isSeek: false);
    }

    await _videoPlayerController?.play();

    audioSessionHandler?.setActive(true);

    playerStatus = .playing;
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    await _videoPlayerController?.pause();
    playerStatus = .paused;

    // 主动暂停时让出音频焦点
    if (!isInterrupt) {
      audioSessionHandler?.setActive(false);
    }
  }

  bool tripling = false;

  /// 隐藏控制条
  void hideTaskControls() {
    _timer?.cancel();
    _timer = Timer(showControlDuration, () {
      if (!isSeeking.value && !tripling) {
        controls = false;
      }
      _timer = null;
    });
  }

  void onSeekStart(int seekFrom) {
    seekPosition.value = seekFrom;
    isSeeking.value = true;
  }

  void onSeekEnd() {
    if (showSeekPreview) {
      showPreview.value = false;
    }
    hasToasted = false;
    isSeeking.value = false;
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  final double maxVolume = PlatformUtils.isDesktop ? Pref.maxVolume : 1.0;
  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
    if (this.volume.value != volume) {
      this.volume.value = volume;
      try {
        if (PlatformUtils.isDesktop) {
          await _videoPlayerController!.setVolume(volume * 100);
        } else {
          FlutterVolumeController.updateShowSystemUI(false);
          await FlutterVolumeController.setVolume(volume);
        }
      } catch (err) {
        if (kDebugMode) debugPrint(err.toString());
      }
    }
    if (showIndicator) {
      volumeIndicator.value = true;
    }
    volumeInterceptEventStream = true;
    volumeTimer?.cancel();
    volumeTimer = Timer(const Duration(milliseconds: 200), () {
      volumeIndicator.value = false;
      volumeInterceptEventStream = false;
      if (PlatformUtils.isDesktop) {
        setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
      }
    });
  }

  /// Toggle Change the videofit accordingly
  void toggleVideoFit(VideoFitType value) {
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
  }

  /// 读取fit
  var _prefFit = VideoFitType.values[Pref.cacheVideoFit];
  void _initVideoFit() {
    if (_prefFit == .fill && _isVertical) {
      videoFit.value = .contain;
    } else {
      videoFit.value = _prefFit;
    }
  }

  /// 设置后台播放
  void setBackgroundPlay(bool val) {
    videoPlayerServiceHandler?.enableBackgroundPlay = val;
    if (!tempPlayerConf) {
      setting.put(SettingBoxKey.enableBackgroundPlay, val);
    }
  }

  set controls(bool visible) {
    showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      hideTaskControls();
    }
  }

  Timer? longPressTimer;
  void cancelLongPressTimer() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }

  /// 设置长按倍速状态 live模式下禁用
  Future<void> setLongPressStatus(bool val) async {
    if (isLive) {
      return;
    }
    if (controlsLock.value) {
      return;
    }
    if (longPressStatus.value == val) {
      return;
    }
    if (val) {
      if (playerStatus.isPlaying) {
        longPressStatus.value = val;
        HapticFeedback.lightImpact();
        await setPlaybackSpeed(
          enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed,
        );
      }
    } else {
      // if (kDebugMode) debugPrint('$playbackSpeed');
      longPressStatus.value = val;
      await setPlaybackSpeed(lastPlaybackSpeed);
    }
  }

  bool get isCompleted =>
      videoPlayerController!.state.completed ||
      durationInMilliseconds - positionInMilliseconds <= 50;

  // 双击播放、暂停
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await videoPlayerController!.seek(Duration.zero);
      videoPlayerController!.play();
    } else {
      videoPlayerController!.playOrPause();
    }
  }

  final RxBool mountSeekBackwardButton = false.obs;
  final RxBool mountSeekForwardButton = false.obs;

  void onDoubleTapSeekBackward() {
    mountSeekBackwardButton.value = true;
  }

  void onDoubleTapSeekForward() {
    mountSeekForwardButton.value = true;
  }

  void onForward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position - duration);
  }

  void onForwardBackward(Duration duration) {
    seekTo(
      duration.clamp(Duration.zero, videoPlayerController!.state.duration),
      isSeek: false,
    ).whenComplete(play);
  }

  void doubleTapFuc(DoubleTapType type) {
    if (!enableQuickDouble) {
      onDoubleTapCenter();
      return;
    }
    switch (type) {
      case DoubleTapType.left:
        // 双击左边区域 👈
        onDoubleTapSeekBackward();
        break;
      case DoubleTapType.center:
        onDoubleTapCenter();
        break;
      case DoubleTapType.right:
        // 双击右边区域 👈
        onDoubleTapSeekForward();
        break;
    }
  }

  /// 关闭控制栏
  void onLockControl(bool val) {
    feedBack();
    controlsLock.value = val;
    if (!val && showControls.value) {
      showControls.refresh();
    }
    controls = !val;
  }

  void _setFullScreen(bool val) {
    isFullScreen.value = val;
    updateSubtitleStyle();
  }

  double screenRatio = 0.0;
  bool isManualFS = true;
  late final FullScreenMode mode = Pref.fullScreenMode;
  late final horizontalScreen = Pref.horizontalScreen;
  late final removeSafeArea = Pref.removeSafeArea;

  Future<void>? changeOrientation({
    required bool isVertical,
    DeviceOrientation? orientation,
  }) {
    if (orientation == null && (mode == .none || mode == .gravity)) {
      return null;
    }
    if (orientation == null &&
        (mode == .vertical ||
            (mode == .auto && isVertical) ||
            (mode == .ratio && (isVertical || screenRatio < kScreenRatio)))) {
      return portraitUpMode();
    } else {
      // https://github.com/flutter/flutter/issues/73651
      // https://github.com/flutter/flutter/issues/183708
      if (Platform.isAndroid) {
        if ((orientation ?? _orientation) == .landscapeRight) {
          return landscapeRightMode();
        } else {
          return landscapeLeftMode();
        }
      } else {
        if (orientation == .landscapeLeft) {
          return landscapeLeftMode();
        } else {
          return landscapeRightMode();
        }
      }
    }
  }

  // 全屏
  bool _fsProcessing = false;
  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    DeviceOrientation? orientation,
    bool isManualFS = true,
  }) async {
    if (isDesktopPip) return;
    if (isFullScreen.value == status) return;

    if (_fsProcessing) return;
    _fsProcessing = true;
    this.isManualFS = isManualFS;
    try {
      if (status) {
        if (PlatformUtils.isMobile) {
          hideSystemBar();
          await changeOrientation(
            isVertical: isVertical,
            orientation: orientation,
          );
        } else {
          await enterDesktopFullScreen(inAppFullScreen: inAppFullScreen);
        }
      } else {
        if (PlatformUtils.isMobile) {
          if (!removeSafeArea) {
            showSystemBar();
          }
          if (orientation == null && mode == .none) {
            return;
          }
          await resetScreenRotation();
        } else {
          await exitDesktopFullScreen();
        }
      }
    } finally {
      _setFullScreen(status);
      _fsProcessing = false;
    }
  }

  void addPositionListener(ValueChanged<Duration> listener) {
    if (_playerCount == 0) return;
    _positionListeners.add(listener);
  }

  void removePositionListener(ValueChanged<Duration> listener) =>
      _positionListeners.remove(listener);

  void addStatusLister(ValueChanged<PlayerStatus> listener) {
    if (_playerCount == 0) return;
    _statusListeners.add(listener);
  }

  void removeStatusLister(ValueChanged<PlayerStatus> listener) =>
      _statusListeners.remove(listener);

  // 记录播放记录
  Future<void>? makeHeartBeat(
    int progress, {
    HeartBeatType type = .playing,
    bool isManual = false,
    dynamic aid,
    dynamic bvid,
    dynamic cid,
    dynamic epid,
    dynamic seasonId,
    dynamic pgcType,
    VideoType? videoType,
  }) {
    if (isLive ||
        !enableHeart ||
        progress == 0 ||
        (playerStatus.isPaused && !isManual)) {
      return null;
    }

    Future<void> send() {
      return VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
    }

    switch (type) {
      case .playing:
        if (progress - _heartDuration >= 5) {
          _heartDuration = progress;
          return send();
        }
      case .status:
        if (progress - _heartDuration >= 2) {
          _heartDuration = progress;
          return send();
        }
      case .completed:
        if (playerStatus.isCompleted &&
            (durationInMilliseconds - positionInMilliseconds) <= 1000) {
          progress = -1;
        }
        return send();
    }
    return null;
  }

  void setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    if (!tempPlayerConf) video.put(VideoBoxKey.playRepeat, type.index);
  }

  void putSubtitleSettings() {
    setting.putAllNE({
      SettingBoxKey.subtitleFontScale: subtitleFontScale,
      SettingBoxKey.subtitleFontScaleFS: subtitleFontScaleFS,
      SettingBoxKey.subtitlePaddingH: subtitlePaddingH,
      SettingBoxKey.subtitlePaddingB: subtitlePaddingB,
      SettingBoxKey.subtitleBgOpacity: subtitleBgOpacity,
      SettingBoxKey.subtitleStrokeWidth: subtitleStrokeWidth,
      SettingBoxKey.subtitleFontWeight: subtitleFontWeight,
    });
  }

  bool _isCloseAll = false;
  bool get isCloseAll => _isCloseAll;

  Future<void>? resetScreenRotation() {
    if (horizontalScreen) {
      return fullMode();
    } else {
      return portraitUpMode();
    }
  }

  void onCloseAll() {
    _isCloseAll = true;
    if (PlatformUtils.isDesktop) exitDesktopFullScreen();
    dispose();
    Get.until((route) => route.isFirst);
  }

  void dispose() {
    // 每次减1，最后销毁
    resetScreenRotation();
    cancelLongPressTimer();
    _cancelSubForSeek();
    if (!_isCloseAll && _playerCount > 1) {
      _playerCount -= 1;
      _heartDuration = 0;
      return;
    }

    _playerCount = 0;
    if (removeSafeArea) {
      showSystemBar();
    }
    danmakuController = null;
    _stopOrientationListener();
    _disableAutoEnterPip();
    setPlayCallBack(null);
    dmState.clear();
    if (showSeekPreview) {
      _clearPreview();
    }
    if (Platform.isAndroid) {
      AndroidHelper$ToDart.onUserLeaveHint = null;
    } else if (Platform.isIOS) {
      IOSPipHelper.dispose();
    }
    _timer?.cancel();
    // _position.close();
    // _playerEventSubs?.cancel();
    // _sliderPosition.close();
    // _sliderTempPosition.close();
    // _isSliderMoving.close();
    // _duration.close();
    // _buffered.close();
    // _showControls.close();
    // _controlsLock.close();

    // playerStatus.close();
    // dataStatus.close();

    if (PlatformUtils.isDesktop && isAlwaysOnTop.value) {
      windowManager.setAlwaysOnTop(false);
    }

    _removeListeners();
    _positionListeners.clear();
    _statusListeners.clear();
    _stopWakeLockTimer();
    WakelockPlus.disable();
    if (kDebugMode) {
      debugPrint('dispose player');
    }
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _videoController = null;
    _instance = null;
    videoPlayerServiceHandler?.clear();
  }

  static void updatePlayCount() {
    if (_instance?._playerCount == 1) {
      _instance?.dispose();
    } else {
      _instance?._playerCount -= 1;
    }
  }

  void setContinuePlayInBackground() {
    continuePlayInBackground.toggle();
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        continuePlayInBackground.value,
      );
    }
  }

  late final Map<String, ui.Image?> previewCache = {};
  LoadingState<VideoShotData>? videoShot;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final previewIndex = RxnInt();

  void updatePreviewIndex(int seconds) {
    if (videoShot == null) {
      videoShot = LoadingState.loading();
      getVideoShot();
      return;
    }
    if (videoShot case Success(:final response)) {
      showPreview.value = true;
      previewIndex.value = max(
        0,
        (response.index.where((item) => item <= seconds).length - 2),
      );
    }
  }

  void _clearPreview() {
    showPreview.value = false;
    previewIndex.value = null;
    videoShot = null;
    for (final i in previewCache.values) {
      i?.dispose();
    }
    previewCache.clear();
  }

  Future<void> getVideoShot() async {
    videoShot = await VideoHttp.videoshot(bvid: bvid, cid: cid!);
  }

  int _screenshotState = 0;
  Future<void> takeScreenshot() async {
    if (_screenshotState > 0) return;
    _screenshotState = 1;
    SmartDialog.showToast('截图中');
    final image = await videoPlayerController?.screenshot();
    if (image != null) {
      SmartDialog.showToast('点击弹窗或按 Enter 保存截图');
      await showDialog(
        context: Get.context!,
        requestFocus: true,
        builder: (context) {
          Future<void> save() async {
            if (_screenshotState > 1) return;
            _screenshotState = 2;
            final bytes = await image.toByteData(format: .png);
            if (bytes != null) {
              final time = DurationUtils.formatDuration(
                positionInMilliseconds / 1000,
              ).replaceAll(':', '-');
              ImageUtils.saveByteImg(
                bytes: bytes.buffer.asUint8List(),
                fileName: 'screenshot_${cid}_$time',
              );
            } else {
              SmartDialog.showToast('保存失败');
            }
            Get.back();
          }

          return Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent) {
                final key = event.logicalKey;
                if (key == .keyS || key == .enter || key == .numpadEnter) {
                  save();
                  return .handled;
                }
              }
              return .ignored;
            },
            child: GestureDetector(
              onTap: save,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: min(MediaQuery.widthOf(context) / 3, 350),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          width: 5,
                          color: ColorScheme.of(context).surface,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: RawImage(image: image),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
      image.dispose();
    } else {
      SmartDialog.showToast('截图失败');
    }
    _screenshotState = 0;
  }

  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) {
      if (playerStatus.isPlaying) {
        pause();
      }

      setPlayCallBack(null);

      if (Platform.isAndroid && _playerCount <= 1) {
        _disableAutoEnterPip();
        if (!setSystemBrightness) {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      }

      return;
    }

    if (controlsLock.value) {
      onLockControl(false);
      return;
    }
    if (isDesktopPip) {
      exitDesktopPip();
      return;
    }
    if (isFullScreen.value) {
      triggerFullScreen(status: false);
      return;
    }
    Get.back();
  }
}
