import 'dart:async' show StreamSubscription, Timer, unawaited;
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
import 'package:PiliPlus/plugin/pl_player/background_video_suspend.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/double_tap_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/duration.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/player_tuning.dart';
import 'package:PiliPlus/plugin/pl_player/reload_strategy.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/console_log.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/asset_utils.dart';
import 'package:PiliPlus/utils/decode_error.dart';
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
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
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
  /// 判据见 [PlayerTuning.divergedFactor]。这是"只有声音、画面冻住"唯一可靠的信号 ——
  /// 那时位置由音频时钟推着走、[buffered] 被音频轨抬到上千秒、[isBuffering]
  /// 是假，判据 1、2 都看不见，判据 3 的"趴在低位"也只防了反的一侧。
  bool get telemetryDiverged {
    final limit = _divergedAheadSec;
    return limit > 0 && bufferedAhead > limit;
  }

  final RxInt duration = RxInt(0);

  /// 渲染上下文（[Player] + [VideoController] + 原生 textureId）重建一次就 +1。
  ///
  /// 视频区那两个渲染节点靠它换 key 把自己的 State 也重建一遍：`SimpleVideo`
  /// 与 `SubtitleView` 都**没有** `didUpdateWidget`，`_visible` 和 `stream.size` /
  /// `stream.subtitle` 的订阅在 `initState` 里就绑死在**当时那个** player 上。
  /// 光换 controller 对象而不重建 State，`_visible` 会停在旧值 false —— 画面
  /// 永远不出来，等于没修。见 [_runRenderContextRebuild]。
  final RxInt renderContextGen = RxInt(0);

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

  /// 缓冲饥饿回调：播放中前向缓冲 [buffered] 连续 [PlayerTuning.starveSeconds] 秒低于
  /// 饥饿阈值时上报一次。与 [onStall] 互补——"画面冻住但音频在走"这种换源型
  /// 故障不会让 buffered 归零（mpv 有 cache-secs 打底），位置又一直在推进，
  /// 两种卡顿判据都看不到，只有缓冲余量在悄悄变少。
  /// 与 [onStall] 一样，播放器只上报事实，如何恢复由页面决定。
  ///
  /// 只负责低的那一侧（余量在变少）。反过来的那一侧——余量**离谱地大**、
  /// 音视频两轨时间轴分家——走 [onTelemetryDiverged]：虽然是同一个故障的指纹，
  /// 但页面侧的处置完全不同，见那个字段。
  ValueChanged<Duration>? onBufferStarve;

  /// 遥测失真回调：前方余量**离谱地大**（见 [PlayerTuning.divergedFactor]），音视频两轨的
  /// 时间轴已经分家——"只有声音、画面冻住"最可靠的那条信号。只防低的一侧会让
  /// 画面冻着而判据 1、2 同时失明，实测就是这样。
  ///
  /// 与 [onBufferStarve] 同源（都是 [bufferedAhead] 这个读数），但病不一样，
  /// 恢复手段也不一样：那边是"供不上"，换条更快的镜像就行；这边位置还被音频
  /// 时钟推着走，只有重开连接让两轨重新对齐才治得了。所以拆成两条回调——页面侧
  /// 给"画面当场就是冻的"开的那几道豁免（放弃冷却、进展门槛），这条要拿到，
  /// [onBufferStarve] 不该拿：2026-10-12 真机上，一次跟它无关的尝试留下 60s
  /// 放弃冷却，把三次失真上报吞掉两次，画面多冻了 61 秒。
  ///
  /// 去重与补报跟 [onBufferStarve] **共用**一套状态（见 [PlayerTuning.starveRepeat]）：两支
  /// 说的是同一段"没在正常播放"，分开计时只会让复位点翻倍。
  ValueChanged<Duration>? onTelemetryDiverged;

  /// 最敏感的一条：前向余量**一归零**就上报一次（每次归零只报一次，补回来
  /// 才重新武装）。前三条判据都要等 —— [onStall] 等 8 秒冻结、[_sampleRebuffer]
  /// 攒够 [PlayerTuning.rebufferTrigger] 次、[onBufferStarve] 连续 [PlayerTuning.starveSeconds] 秒低于
  /// 阈值 —— 而"卡一下又接着播"这种小卡顿一条都凑不满，等凑满时用户已经看了
  /// 半分钟转圈。这里只报事实，节流与"要不要真去测速"由页面决定（测速会跟
  /// 播放器抢带宽，不能由播放器自己决定）。
  ///
  /// 刻意不要求 [isBuffering]：换源型卡顿时 core-idle / paused-for-cache 未必
  /// 为真，`stream.buffer` 才是唯一一定会动的信号。
  ValueChanged<Duration>? onRebuffer;

  /// 解码错误风暴回调：当前这条源给的是**坏字节**，不是喂不饱。
  ///
  /// 前四条判据看的全是"供得上供不上"（位置、缓冲、余量），而镜像把坏字节送
  /// 进来时这四样**全是健康的** —— 吞吐 3MB/s、余量 27s、位置在推进、hwdec
  /// 正常，画面却冻在最后一帧。2026-10-11 手机上那一局就是这样，而 mpv 同时
  /// 刷了 **524 行**解码报错（全挤在 44 毫秒里，档案 log 4）。判据见 [PlayerTuning.decodeErrorBurst]。
  ///
  /// 与其他回调一样只上报事实：怎么恢复（换源、要不要绕过那套"必须明显更快
  /// 才值得重载"的门槛）由页面决定。
  ///
  /// **返回值是回执**：`false` = 页面现在收不下这一发（有一个换源/换画质轮次
  /// 在途）。解码错误是**唯一一次性消费**的上报 —— 播放器在回调前就清空计数
  /// 窗口并武装 30s 静默（见 [_sampleDecodeError]），所以页面回 `false` 时必须
  /// 保住它、稍后重发，否则这一发就永远丢了（2026-10-12 真机冻屏的成因）。
  /// 真机取证与背景见 `lib/pages/video/cdn_switch_mixin.dart` 里
  /// `_CdnTrigger.decode` 附近的注释。
  ///
  /// 注意这是唯一带回执的回调，兄弟回调（`onStall`/`onBufferStarve`/
  /// `onTelemetryDiverged`/`onRebuffer`）仍是 [ValueChanged]。
  bool Function(Duration)? onDecodeError;

  // ---------------------------------------------------------------------------
  // CDN 回调的归属。上面 5 个字段是跨页共享的，页面各自抢占；只比对其中一个
  // 回调没法原子地判断"这 5 个现在是不是都归我"。登记一组 handler + 一个身份
  // 牌，让挂载、撤下、自查都看成整体。
  // ---------------------------------------------------------------------------

  Object? _cdnSwitchOwner;
  ValueChanged<Duration>? _cdnSwitchOnStall;
  ValueChanged<Duration>? _cdnSwitchOnBufferStarve;
  ValueChanged<Duration>? _cdnSwitchOnTelemetryDiverged;
  ValueChanged<Duration>? _cdnSwitchOnRebuffer;
  bool Function(Duration)? _cdnSwitchOnDecodeError;

  /// 一次性登记这 5 个回调属于 [owner]，并立刻挂到公开字段上。
  ///
  /// 先把 handler 引用存进私有登记表、再赋公开字段、最后写 owner —— 全同步，
  /// 不存在"只挂了一半"的可观察状态。
  void claimCdnSwitchCallbacks(
    Object owner, {
    required ValueChanged<Duration> onStall,
    required ValueChanged<Duration> onBufferStarve,
    required ValueChanged<Duration> onTelemetryDiverged,
    required ValueChanged<Duration> onRebuffer,
    required bool Function(Duration) onDecodeError,
  }) {
    _cdnSwitchOnStall = onStall;
    _cdnSwitchOnBufferStarve = onBufferStarve;
    _cdnSwitchOnTelemetryDiverged = onTelemetryDiverged;
    _cdnSwitchOnRebuffer = onRebuffer;
    _cdnSwitchOnDecodeError = onDecodeError;
    this.onStall = onStall;
    this.onBufferStarve = onBufferStarve;
    this.onTelemetryDiverged = onTelemetryDiverged;
    this.onRebuffer = onRebuffer;
    this.onDecodeError = onDecodeError;
    _cdnSwitchOwner = owner;
  }

  /// [owner] 是不是这组回调的现役主人。
  ///
  /// 除了身份牌，还要求 [onStall] 仍是登记时那一个：单测会绕过
  /// [releaseCdnSwitchCallbacks] 直接把回调置空，那时身份牌还在，但页面显然
  /// 已经不在台上了。
  bool cdnSwitchCallbacksOwnedBy(Object owner) =>
      identical(_cdnSwitchOwner, owner) && onStall == _cdnSwitchOnStall;

  /// [owner] 退场：只撤自己挂的那几个回调。
  ///
  /// 每个字段都先与登记时的 handler 比对 —— 被顶掉的旧页不能把新页的回调清掉，
  /// 也不怕测试直接覆盖其中某一个。
  void releaseCdnSwitchCallbacks(Object owner) {
    if (!identical(_cdnSwitchOwner, owner)) return;
    if (onStall == _cdnSwitchOnStall) onStall = null;
    if (onBufferStarve == _cdnSwitchOnBufferStarve) onBufferStarve = null;
    if (onTelemetryDiverged == _cdnSwitchOnTelemetryDiverged) {
      onTelemetryDiverged = null;
    }
    if (onRebuffer == _cdnSwitchOnRebuffer) onRebuffer = null;
    if (onDecodeError == _cdnSwitchOnDecodeError) onDecodeError = null;
    _cdnSwitchOnStall = null;
    _cdnSwitchOnBufferStarve = null;
    _cdnSwitchOnTelemetryDiverged = null;
    _cdnSwitchOnRebuffer = null;
    _cdnSwitchOnDecodeError = null;
    _cdnSwitchOwner = null;
  }

  Timer? _stallTicker;
  int _stallLastSecond = 0;
  int _stallFrozen = 0;
  final List<DateTime> _rebufferEvents = [];
  DateTime _rebufferSuppressUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _wasStalled = false;

  /// 余量是否已经归零过（[onRebuffer] 的上升沿去重）。
  bool _wasEmpty = false;
  int _starveSeconds = 0;

  /// 当前这段饥饿的最后一次上报时刻；null = 没有正在上报的饥饿段。
  ///
  /// 兼作去重状态：非空即"这段已经报过"，只有余量真的涨回水位才清空（见
  /// [_sampleStarve]）。存时刻而不是 bool 是为了补报 —— 见 [PlayerTuning.starveRepeat]。
  DateTime? _starveLastReportAt;
  DateTime _lastHeartbeat = DateTime.fromMillisecondsSinceEpoch(0);

  /// 落在 [PlayerTuning.decodeErrorWindow] 里的解码报错时刻，窗口自己滑动淘汰。
  ///
  /// 刻意**不随每次装载清零**：换源重载期间旧流还在往外吐报错，那些报错说明的
  /// 正是刚才那段字节是坏的，必须继续记账（见 [_sampleDecodeError]）。只在
  /// 播放器创建（[_startListeners]）和换集/换画质（[resetDecodeErrorAccounting]）时清。
  final List<DateTime> _decodeErrors = [];

  /// 落在 [PlayerTuning.decodeErrorDenseWindow] 里的坏字节**原始行**时刻（不去重）。
  ///
  /// 和 [_decodeErrors] 同一族、同一个病，只是数法不同：那个去重、这个不去重。
  /// 窗口只有 100ms，所以它常年只装十几条 —— 为它单开一个 list 换来的好处是
  /// 两个档互不干扰：调稀疏档的窗口/门槛不会动到密集档，反之亦然。
  /// 清零时机与 [_decodeErrors] 完全相同。
  final List<DateTime> _decodeErrorDense = [];

  /// 解码错误风暴的静默期截止时刻。见 [PlayerTuning.decodeErrorCooldown]。
  DateTime _decodeErrorUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// 最近一条解码器坏字节报错的时刻，**不受 [PlayerTuning.decodeErrorCooldown] 限制**。
  ///
  /// [CdnSwitchMixin] 换源后用它判断"这条镜像已经干净了"：坏镜像的特征恰恰是
  /// 缓冲填得满、位置还在被音频时钟推着走，所以位置和余量都判不出恢复，只有
  /// "不再吐坏字节"才是真话。
  DateTime? lastDecoderCorruptionAt;

  /// 落在 [PlayerTuning.sessionFailWindow] 里的「本机解码会话废了」的报错时刻，窗口自己滑动
  /// 淘汰。与 [_decodeErrors] 分开记账：两族的窗口、门槛、以及**该做的事**都不同。
  ///
  /// 回前台续播的那一段（见 [_inForegroundResumeWindow]）也记在这里：它和硬解会话
  /// 失效是同一个病（本机解码链需要重建），只是报错的字样不同。
  final List<DateTime> _sessionFailures = [];

  /// 重建解码器的冷却截止时刻。见 [PlayerTuning.sessionFailCooldown]。
  DateTime _sessionHealUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// 后台攒下了「硬解会话失效」但没动手重建，等回前台再修。
  ///
  /// 重建会把音频输出一起拆掉、断音 1~3 秒。iOS 在断音那一瞬间就把「正在播放」
  /// 交给了上一个播放器，之后声音回来了、播放器卡片也回不来（2026-10-21 真机：
  /// 回主页 → 重建 → 2 秒断音 → 灵动岛变苹果音乐，重新认领也抢不回）。
  /// 后台本来就没有画面，重建没有意义，推迟到回前台。
  bool _deferredDecoderRebuild = false;

  /// 后台省电：这次后台会话从什么时候开始（`null` = 不在后台会话里）。
  ///
  /// 记会话起点而不是"每次生命周期回调重新计时"：iOS 进后台会连发
  /// `hidden` → `paused`，两次都重新计时会把等待时间拖成两倍。
  DateTime? _backgroundEnteredAt;

  /// 到点关视频轨的定时器（[PlayerTuning.backgroundVideoSuspendDelay]）。
  Timer? _bgVideoSuspendTimer;

  /// 视频轨是不是被后台省电关掉的。
  ///
  /// **不能用 `state.width/height` 判断**：`vid=no` 之后 libmpv 发的是
  /// `MPV_FORMAT_NONE`，media_kit 只处理 NODE，宽高会一直停在旧值 ——
  /// 既不会误触发无视频轨看门狗，也意味着恢复失败时看门狗是瞎的，
  /// 兜底只能靠自己（见 [_verifyVideoTrackRestored]）。
  bool _videoSuspendedForBackground = false;

  /// 到点时播放器是暂停的：等真正播放起来再关。
  bool _bgVideoSuspendDue = false;

  @visibleForTesting
  bool? debugForceAppInBackground;
  bool _bgVideoSuspendDiagLogged = false;

  bool get _appInBackground => debugForceAppInBackground ?? appInBackground;

  /// 后台省电是否生效：iOS + 后台播放开着 + 设置里没关。
  ///
  /// 读设置要防一手异常：这个 getter 在生命周期回调的最前面被求值，抛出去会让
  /// 整个回调（包括别的分支的动作）一起断在半路，而且日志里只留一行无从解释的
  /// 堆栈 —— 宁可当成「关着」并留一句话。
  bool get _backgroundVideoSuspendEnabled {
    try {
      return Platform.isIOS &&
          continuePlayInBackground.value &&
          Pref.backgroundVideoSuspend;
    } catch (e) {
      debugPrint('后台省电: 读取开关失败（$e）');
      return false;
    }
  }

  /// 应用是不是真的退到后台了。
  ///
  /// 只有 `paused / hidden / detached` 算后台：`inactive` 是下拉控制中心、来电
  /// 横幅这类"马上会回来"的状态，`null` 是生命周期事件还没到达 —— 两种都按前台
  /// 处理。把 `null` 当后台会让推迟下来、却再也等不到 `resumed` 的补做。
  ///
  /// 与 [CdnSwitchMixin] 的 `_cdnInBackground` 同一口径（那边额外排除画中画，
  /// 因为画中画里还有画面要看；解码器重建则与画面无关）。
  bool get appInBackground => switch (WidgetsBinding.instance.lifecycleState) {
    AppLifecycleState.paused ||
    AppLifecycleState.hidden ||
    AppLifecycleState.detached => true,
    _ => false,
  };

  /// 回前台后把推迟的重建补上。由播放器页的生命周期回调调用。
  void resumeDeferredDecoderRebuild() {
    if (!_deferredDecoderRebuild) return;
    _deferredDecoderRebuild = false;
    // 装载在途（换源 / 换集 / 回前台补做的换源）时别插进去：那一轮重载本来就会
    // 建一条新的视频链，再 `vid=no → vid=auto` 一遍是白拆一次（[playerInit] 刚
    // 换上的 Media 会在 300ms 里失去视频轨）。让位给重载，它自己会有一条新链。
    if (_processing) {
      debugPrint('CDN 看门狗: 装载在途，跳过回前台重挂视频轨（新链会自己建起来）');
      return;
    }
    debugPrint('CDN 看门狗: 回前台，原地重挂视频轨（后台那段硬解会话已作废）');
    _reloadVideoTrack();
  }

  /// 后台省电的生命周期入口。由播放器视图在 PiP early return **之前**调用。
  ///
  /// 画中画由播放器自己排除（[IOSPipHelper.needsUpdate]）：PiP 激活时
  /// `AppLifecycleState` 同样是 `paused`，光看生命周期分不出「真后台」和
  /// 「画中画」——而后者画面还在看，关掉视频轨等于把小窗冻住。
  void handleAppLifecycleForVideoTrack(AppLifecycleState state) {
    if (!Platform.isIOS) return;
    // 诊断：真机上「回调到没到、三个开关各是什么值」只能靠这一行回答。
    // 2026-10-21 那局：后台音频在放、心跳在写、`resumed` 那条也打出来了，
    // 唯独切后台这一侧没有任何「后台省电」日志 —— 没有这行就分不清是
    // 回调没到、还是哪道门（含读取设置时抛异常）在 `_onBackgroundForVideoTrack`
    // 之前就把路断了。
    debugPrint(
      '后台省电: 生命周期 $state'
      '（开关 ${_backgroundVideoSuspendEnabled ? '开' : '关'}）',
    );
    switch (state) {
      case AppLifecycleState.resumed:
        _onForegroundForVideoTrack();
      case AppLifecycleState.paused ||
          AppLifecycleState.hidden ||
          AppLifecycleState.detached:
        _onBackgroundForVideoTrack();
      case AppLifecycleState.inactive:
        // iOS 回前台会先来一拍 inactive：先把还没到点的定时器取消，
        // 免得它和随后的 resumed 抢跑。
        if (_bgVideoSuspendTimer case final timer?) {
          timer.cancel();
          _bgVideoSuspendTimer = null;
          debugPrint('后台省电: 回前台过渡，取消定时器');
        }
        _bgVideoSuspendDue = false;
    }
  }

  void _onBackgroundForVideoTrack() {
    if (!_backgroundVideoSuspendEnabled) {
      debugPrint('后台省电: 跳过（功能或后台播放已关闭）');
      return;
    }
    if (IOSPipHelper.needsUpdate) {
      debugPrint('后台省电: 跳过（画中画需要画面）');
      return;
    }
    if (_videoSuspendedForBackground) return;

    final now = DateTime.now();
    _backgroundEnteredAt ??= now;
    // hidden → paused 会连发两次，第二次不能把计时推后。
    if (_bgVideoSuspendTimer != null) return;

    final remaining =
        PlayerTuning.backgroundVideoSuspendDelay -
        now.difference(_backgroundEnteredAt!);
    final delay = remaining.isNegative ? Duration.zero : remaining;
    _bgVideoSuspendTimer = Timer(delay, _onBackgroundVideoSuspendTimer);
    debugPrint('后台省电: 进入后台，${delay.inSeconds}s 后关闭视频轨（音频继续）');
  }

  void _onForegroundForVideoTrack() {
    final hadPending = _bgVideoSuspendTimer != null || _bgVideoSuspendDue;
    _bgVideoSuspendTimer?.cancel();
    _bgVideoSuspendTimer = null;
    _bgVideoSuspendDue = false;
    _backgroundEnteredAt = null;
    if (hadPending) {
      debugPrint('后台省电: 未到点就回前台，取消');
    }

    if (!_videoSuspendedForBackground) return;
    _videoSuspendedForBackground = false;
    // 恢复视频轨本身就是重建视频解码链，后台攒下的那次重挂是同一件事 ——
    // 留着会再 `vid=no → vid=auto` 一遍，等于白付两次 refresh seek。
    _deferredDecoderRebuild = false;
    // 先开续解窗口再发 auto：从关键帧重开视频链会冒 `Missing Sequence Header`
    // 之类的报错，不能算到镜像头上。
    _foregroundResumedAt = DateTime.now();
    debugPrint('后台省电: 回前台，恢复视频轨（file-local-options/vid=auto）');
    _setBackgroundVideoTrack(true);
    unawaited(_verifyVideoTrackRestored());
  }

  void _onBackgroundVideoSuspendTimer() {
    _bgVideoSuspendTimer = null;

    if (!_backgroundVideoSuspendEnabled) {
      debugPrint('后台省电: 到点但功能已关闭，跳过');
      return;
    }
    if (!_appInBackground) {
      debugPrint('后台省电: 到点但已回前台，跳过');
      return;
    }
    if (IOSPipHelper.needsUpdate) {
      debugPrint('后台省电: 到点但画中画在播，跳过');
      return;
    }

    final player = _videoPlayerController;
    final blocker = checkBackgroundVideoSuspend(
      hasPlayer: player != null,
      isLive: isLive,
      onlyPlayAudio: onlyPlayAudio.value,
      playing: playerStatus.isPlaying,
      processing: _processing,
      rebuildingRenderContext: _rebuildingRenderContext,
      seeking: isSeeking.value,
      completed: player?.state.completed ?? false,
      seekable: _safeProp('seekable') == 'yes',
      duration: player?.state.duration ?? Duration.zero,
      videoTrackCount: player?.state.tracks.video.length ?? 0,
      selectedVideoTrackId: player?.state.track.video.id ?? 'no',
    );

    if (blocker != null) {
      if (blocker.waitForPlayback) {
        _bgVideoSuspendDue = true;
        debugPrint('后台省电: 到点但暂停中，恢复播放后再关');
        return;
      }
      if (blocker.retryable) {
        debugPrint(
          '后台省电: 到点但${blocker.label}，'
          '${PlayerTuning.backgroundVideoSuspendRetry.inSeconds}s 后重试',
        );
        _bgVideoSuspendTimer = Timer(
          PlayerTuning.backgroundVideoSuspendRetry,
          _onBackgroundVideoSuspendTimer,
        );
        return;
      }
      debugPrint('后台省电: 跳过（${blocker.label}）');
      return;
    }

    _bgVideoSuspendDue = false;
    _videoSuspendedForBackground = true;
    debugPrint('后台省电: 关闭视频轨（file-local-options/vid=no），音频继续');
    _setBackgroundVideoTrack(false);
  }

  /// 暂停态进后台时记下的那一次关轨，等真正播放后的第一拍补做。
  void _maybeSuspendDueVideoInBackground() {
    if (!_bgVideoSuspendDue) return;
    if (!_backgroundVideoSuspendEnabled || !_appInBackground) {
      _bgVideoSuspendDue = false;
      return;
    }
    if (!playerStatus.isPlaying || _videoSuspendedForBackground) return;
    _bgVideoSuspendDue = false;
    // 所有闸门在定时器回调里会再判一次。
    _onBackgroundVideoSuspendTimer();
  }

  /// 后台省电只动视频轨，而且走 `file-local-options/vid`。
  ///
  /// 全局 `vid` 是运行时选项、跨文件保留：漏一次恢复，后面每一集都会只剩声音。
  /// file-local 在当前文件停止时自动复位，锁屏切下一集也不会把 `no` 带过去。
  void _setBackgroundVideoTrack(bool enabled) {
    final ctr = _videoPlayerController;
    if (ctr == null) return;
    try {
      // 与「听视频」同一种写法（`header_control.dart`）：`setProperty` 是同步
      // 原生调用，mpv 层失败静默，由自己的 track-list 校验兜底。
      ctr.setProperty('file-local-options/vid', enabled ? 'auto' : 'no');
    } catch (e) {
      debugPrint('后台省电: 设置视频轨失败（$e）');
    }
  }

  /// 恢复视频轨的兜底：宽高不可信，只认 `track-list` 里选中的那条。
  Future<void> _verifyVideoTrackRestored() async {
    final ctr = _videoPlayerController;
    if (ctr == null) return;
    // 装载在途时 `track-list` 还是空/旧的，而且此刻写 file-local 可能落到新文件
    // 上（重挂的第一下正是 `no`）—— 等装载收尾再判，等不到就交给看门狗。
    for (var i = 0; i < 6 && _processing; i++) {
      await Future<void>.delayed(PlayerTuning.backgroundVideoResumeVerifyDelay);
      if (!identical(ctr, _videoPlayerController)) return;
    }
    if (_processing) return;
    await Future<void>.delayed(PlayerTuning.backgroundVideoResumeVerifyDelay);
    if (!identical(ctr, _videoPlayerController)) return;
    if (ctr.state.track.video.id != 'no') return;

    debugPrint('后台省电: 恢复失败（track.video.id 仍为 no），重挂视频轨');
    await _remountSuspendedVideoTrack();

    await Future<void>.delayed(PlayerTuning.backgroundVideoResumeVerifyDelay);
    if (!identical(ctr, _videoPlayerController)) return;
    if (ctr.state.track.video.id != 'no') return;
    if (_appInBackground) return;

    debugPrint('后台省电: 重挂后仍无视频轨，请求就地重建');
    _rebuildRenderContextOnNoVideo();
  }

  /// 重挂被后台省电关掉的视频轨：`no` → 300ms → `auto`。
  ///
  /// 与 [_reloadVideoTrack] 同一套节奏，但**必须走 file-local**：我们已经在这个
  /// 文件上写过 `file-local-options/vid`，它会盖住全局 `vid` —— 这时候发
  /// `command(['set','vid', ...])`（[_reloadVideoTrack] 的做法）等于什么都没做。
  Future<void> _remountSuspendedVideoTrack() async {
    final ctr = _videoPlayerController;
    if (ctr == null) return;
    _foregroundResumedAt = DateTime.now();
    try {
      _setBackgroundVideoTrack(false);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _setBackgroundVideoTrack(true);
    } catch (_) {
      // 重挂失败就带着旧解码链继续放，下一档兜底是就地重建。
    }
  }

  /// 后台换集 / 错误重载：新文件让 `file-local-options/vid` 复位，视频轨又回来了。
  ///
  /// 装载完成后按**原后台会话的剩余时间**重排，而不是重新计时。
  void _rearmBackgroundVideoSuspendAfterLoad() {
    _videoSuspendedForBackground = false;
    if (!_backgroundVideoSuspendEnabled) return;
    if (!_appInBackground || IOSPipHelper.needsUpdate) return;

    final now = DateTime.now();
    _backgroundEnteredAt ??= now;
    final remaining =
        PlayerTuning.backgroundVideoSuspendDelay -
        now.difference(_backgroundEnteredAt!);
    // 已经超过等待时长的：新文件给 1 秒让首帧和播放状态稳定就关。
    final delay = remaining.isNegative ? const Duration(seconds: 1) : remaining;

    _bgVideoSuspendTimer?.cancel();
    _bgVideoSuspendTimer = Timer(delay, _onBackgroundVideoSuspendTimer);
    debugPrint(
      '后台省电: 后台装载新文件，视频轨已随新文件复位，'
      '${delay.inSeconds}s 后重新关闭',
    );
  }

  /// 只把**视频轨**重挂一遍：`vid=no` → `vid=auto`。
  ///
  /// 为什么不是 [reinitDecoderAfterBackground]（切 hwdec + seek）：那条路要求
  /// 新的硬解解码器第一口就吃到关键帧，可 `set hwdec` 在 mpv 里是**立即**重开
  /// 解码器、不等随后排队的 seek。正在播放时它先拿到 GOP 中间的帧，
  /// `av1: Missing Sequence Header` 刷三条就一路降级到软解且不再回升（2026-10-21
  /// 真机 20:47 现场：画面回来了，但这一集剩下的时间都是 CPU 软解，发热明显）。
  /// 停顿中的调用方（`!continuePlayInBackground` 那条）没有这个竞争，所以那条
  /// 路径保持不动。
  ///
  /// `vid` 重挂则是 mpv 自己按"新视频链从关键帧开始"来做的：本机对照实验
  /// （mpv 0.41 + AV1 硬解，40s/8s GOP）里视频 134ms 回来、`hwdec-current`
  /// 仍是 videotoolbox、音频时间轴一秒没停。它不碰音频轨，所以也永远不会触发
  /// 「断音 → 系统把正在播放交给别的 App」那条链。
  Future<void> _reloadVideoTrack() async {
    final ctr = _videoPlayerController;
    if (ctr == null) return;
    // 视频链从关键帧重开的那一刻会冒续解报错（`Missing Sequence Header` 等），
    // 和 [reinitDecoderAfterBackground] 一样要先把窗口打开，别让它们算到镜像头上。
    _foregroundResumedAt = DateTime.now();
    try {
      await ctr.command(['set', 'vid', 'no']);
      // 留一拍让 mpv 把旧视频链接干净；本机实测 300ms 足够。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await ctr.command(['set', 'vid', 'auto']);
    } catch (_) {
      // 重挂失败就带着旧解码链继续放：看门狗还在，真治不好会升级成重载
      // （[_noteForegroundResumeFailure]）。
    }
  }

  /// 回前台开始续播的时刻；窗口长度见 [PlayerTuning.foregroundResumeWindow]。
  ///
  /// 由 [reinitDecoderAfterBackground] 在**发命令之前**置上。窗口内解码器吐出的
  /// 坏字节签名不算镜像的账：那是切 hwdec / 从 GOP 中间续解的正常产物
  /// （`Missing Sequence Header` + `Missing reference frame`，紧随其后的是成片的
  /// OBU 报错），字节本身是好的。2026-10-20 20:47 真机：回前台 0.35s 后 68ms 内
  /// 153 行 libdav1d 报错，被当成"镜像喂坏字节"强制换源，还把一条健康的 ali 拉黑了。
  DateTime? _foregroundResumedAt;

  /// 视频链最近一次重建的时刻（[reinitDecoderAfterBackground] / [_reloadVideoTrack]）。
  ///
  /// 换源侧用它避开「解码器刚起来、还是冷的」那一小段：2026-10-21 真机
  /// 22:10:46.2 回前台重挂视频轨，47.5 预检就换源，新解码器冷启动出首帧花了
  /// 1.15s（稳态 mid-GOP 约 0.55s），换源静音从常态 ~1.8s 拖到 2.5s。
  /// 见 [CdnTuning.postResumeSettle]。换集/换画质时 [_clearDecodeAccounting]
  /// 会清成 null —— 那时候是另一条视频，谈不上"刚重建"。
  DateTime? get videoChainRebuiltAt => _foregroundResumedAt;

  /// 这个 Media 最近一次「根本没打开」的证词（`Failed to open ...` /
  /// `No video or audio streams selected`）及其原文。
  ///
  /// 与 [lastDecoderCorruptionAt] 是两件事：那个是"字节坏"，这个连流都没建起来 ——
  /// 位置和余量永远不会动。[CdnSwitchMixin] 换源后靠它立刻收尾本轮：既不必等满
  /// 恢复窗，也不再往一个没打开的播放器上补 seek（真机 20:47 换到 ali 之后
  /// 连打 5 发补 seek，mpv 全回 `error running command`）。
  ///
  /// 每次装载（[setDataSource]）开头清空：上一条流的证词不能算到下一条头上。
  DateTime? lastOpenFailureAt;
  String? lastOpenFailure;

  /// 换集 / 换画质：换成了**另一个对象**，旧的解码账作废重计。
  ///
  /// 刻意不在 `setDataSource` / `player.open` 里调 —— 换源重载时旧流的报错要
  /// 继续算（见 [_decodeErrors] 的注释）。只由页面在换集 / 换画质时调。
  void resetDecodeErrorAccounting() {
    _clearDecodeAccounting();
  }

  /// 两个「账本作废」的时机（换集/换画质、播放器创建）共用这一份清法。
  /// 分开写时漏掉一行，两族账就会一半归零一半继续攒，而这**不会报错**、
  /// 只会让阈值悄悄地偏 —— 所以只留一份。
  void _clearDecodeAccounting() {
    _decodeErrors.clear();
    _decodeErrorDense.clear();
    _decodeErrorUntil = DateTime.fromMillisecondsSinceEpoch(0);
    lastDecoderCorruptionAt = null;
    _sessionFailures.clear();
    _sessionHealUntil = DateTime.fromMillisecondsSinceEpoch(0);
    // 换成另一个视频/画质之后，"回前台续播"这个上下文也作废：新对象的头几秒
    // 报错该按它自己的镜像算，不能继承上一段续播的豁免。
    _foregroundResumedAt = null;
    // 后台攒下的那次重建属于**上一个**视频：换集/换画质会新建整条播放链，
    // 回前台再拿新对象去 `vid=no → vid=auto` 一遍，是白丢 300ms 视频轨。
    _deferredDecoderRebuild = false;
    // 后台省电关掉的视频轨随新文件复位（`file-local-options` 是 per-file 的），
    // 装载完成后由 [_rearmBackgroundVideoSuspendAfterLoad] 按剩余时间重排。
    // **刻意不清 `_backgroundEnteredAt`**：后台会话还在，换集不重新计时。
    _videoSuspendedForBackground = false;
    _bgVideoSuspendDue = false;
    _bgVideoSuspendTimer?.cancel();
    _bgVideoSuspendTimer = null;
  }

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
      // 新装载：上一条流的「打不开」证词作废。换源时页面拿装载开始时刻比
      // [lastOpenFailureAt]，清得越早，旧流的晚到报错越不可能算到新镜像头上。
      lastOpenFailureAt = null;
      lastOpenFailure = null;
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
      // 后台装载（换集/换源/错误重载）会让 file-local 的 `vid=no` 随旧文件复位，
      // 视频轨又回来了 —— 按原后台会话的剩余时间重新关。
      _rearmBackgroundVideoSuspendAfterLoad();
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
    // 旧渲染上下文可能还在拆（见 [_playerTeardown]）：不等它，我们这里的
    // `VideoController.create` 就会和那边的 `VideoOutputManager.Dispose` +
    // `unregisterTexture` 撞在一起抢同一个 handle / textureId。我们自己的那次
    // 重载不会被挡在这里 —— [_runRenderContextRebuild] 是先 await 完拆除才请页面
    // 重载的，走到这里时 [_playerTeardown] 已经清空。
    if (_playerTeardown case final teardown?) {
      await teardown;
    }
    final opt = {
      'video-sync': Pref.videoSync,
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      // iOS：换流时复用现有音频输出。默认 weak 只在格式完全一致时复用，yes 则
      // 无条件复用（必要时由 mpv 重采样）—— 这是 [replaceSingle] 原地换流能
      // 保住 AVAudioSession（进而保住系统「正在播放」）的前提，见
      // [canReloadInPlace]。别的平台不设，行为逐字不变。
      if (Platform.isIOS) 'gapless-audio': 'yes',
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
        androidAttachSurfaceAfterVideoParameters: false,
        hwdec: hwdec,
      ),
    );
    // 渲染上下文出生：连同 [_runRenderContextRebuild] 里销毁那次的递增，
    // 「gen 变了 ⇔ 上下文对象换了」这条不变量闭合。递增必须在这里而不是调用者那里 ——
    // 页面自己发起的装载（换集 / 换画质 / 失败后再试）也会走到这里，只认一个口子
    // 才不会漏（漏了 UI 就抱着上一个已经被 dispose 的 controller 不动了）。
    renderContextGen.value++;

    if (Platform.isAndroid) {
      // Avoid sizing the surface using mpv's idle window between media loads.
      player.setProperty('force-window', 'no');
    }
    // iOS 侧**故意不设** `force-window`（2026-10-15 议过，暂缓）：
    //
    // 它看着是那场竞态的正解 —— 语义正是"没有视频也把视频输出建起来"，若能让 mpv 在
    // 装载时就建好 VO，竞态就没有发生的窗口。但它有一个**比病更坏**的失败形态：
    // 上面 Android 那句注释就是机制的证词（mpv 的 idle window 会去撑 surface），
    // 一旦 mpv 拿空窗口把尺寸定出来，[_hasVideoTrack]（读 `video-out-params` 的
    // w/dw）就会翻真 —— 画面照样是黑的，判据却瞎了，[_checkNoVideoTrack] 永远不定罪、
    // 就地重建这条**唯一的救援路**也不会触发 ⇒ 永久黑屏，只能杀进程。
    // 现在这个病是 11s 能自愈的，换成一个救不回来的，不划算。
    //
    // 附带一条：这一版同时上了 fork 的黑屏探针（要回答"死锁时 `_updateCallback()`
    // 到底有没有被叫过"）。若 `force-window` 真把竞态压住了，这一局就不复现死锁，
    // 探针存在的唯一理由也随之落空 —— 两个改动同车，答案会被搅在一起。
    //
    // 顺序：先拿探针的证据，再单独出包试它。

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
    // 换了媒体，「音频在、画面不在」的窗口与重建额度都重新来过。
    _resetNoVideoWindow();
    // 重建渲染上下文自己也要走这条路（见 [_runRenderContextRebuild]），别把自己
    // 的额度一起清掉 —— 清了就是"攒满窗 → 重建 → 攒满窗 → …"的无限重建。只有
    // 用户发起的装载（换集 / 换画质 / CDN 换源）才重新给额度。
    //
    // 判据是 _ownReload 而不是 _rebuildingRenderContext：用户**恰好在重建窗口里**
    // 换集时后者也是 true，会把用户这次装载的额度白白吃掉（新媒体一上来就背着
    // 上一个媒体烧完的账）。
    if (!_ownReload) {
      _noVideoRebuilds = 0;
    }

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
    await _loadMedia(
      player,
      Media(
        video,
        start: seekTo,
        extras: extras.isEmpty ? null : extras,
      ),
      play: false,
    );
  }

  /// 换流：能原地替换就原地替换，不行再走 `Player.open()`。
  ///
  /// `open()` 会先 stop + 清播放列表，mpv 随之拆掉音频输出，它的收尾会给
  /// `AVAudioSession` 发 `setActive:NO` —— iOS 就是在这 1~3 秒断音里把系统
  /// 「正在播放」交出去、再也不还的（见 [canReloadInPlace]）。所以 iOS 上用
  /// `replaceSingle` 走 mpv 的「播放下一条」路径，配合 `gapless-audio=yes`
  /// 让音频输出原地复用，声音不断，卡片自然还在。
  ///
  /// 失败一律回落 `open()`：这里只是省下断音，不是必须成功的路径。
  Future<void> _loadMedia(
    Player player,
    Media media, {
    required bool play,
  }) async {
    final inPlace = await tryInPlaceReload(
      allowed: canReloadInPlace(
        isIOS: Platform.isIOS,
        isLive: isLive,
        isNetworkSource: dataSource is NetworkSource,
        playlistLength: player.current.length,
        completed: player.state.completed,
      ),
      replace: () => _replaceSingle(player, media, play: play),
      onReplaceError: (error, _) =>
          debugPrint('CDN 换流: 原地替换失败，回落 open(): $error'),
    );
    if (inPlace) return;
    await player.open(media, play: play);
  }

  /// `Player.open()` 的原地版本：不 stop、不清播放列表，音频输出原地复用。
  ///
  /// 起播语义与 `open(play:)` 对齐：[play] 为 false 时先停在暂停态（也让
  /// media_kit 不把这次装载当成播放状态变化，[playerStatus] 不会闪一下），
  /// 为 true 时替换完再起播。`open(play:false)` 的暂停是它自己做的，这里补上。
  Future<void> _replaceSingle(
    Player player,
    Media media, {
    required bool play,
  }) async {
    if (!play) {
      await player.pause();
    }
    await player.replaceSingle(media);
    debugPrint('CDN 换流: replaceSingle 原地替换（iOS，保音频输出）');
    if (play) {
      await player.play();
    }
  }

  /// 重开当前 Media 做故障恢复。
  ///
  /// [play] 决定重开后是否起播：传 null（默认）时沿用**当前**播放态
  /// （[playerStatus].isPlaying），显式传入则覆盖。四个调用点全是故障恢复
  /// （直播/非直播 stream.error、硬解会话失效、CDN 冻结重载），本就该"恢复成
  /// 用户原来的样子"——旧的 `play: true` 无条件起播，于是用户手动暂停、缓冲
  /// 也健康时，任意一条恢复都会让画面自己播起来（S1/N4）。
  Future<void>? refreshPlayer({bool? play}) {
    if (dataSource is FileSource) {
      return null;
    }
    // 重新打开同一个 Media，缓冲从头再来，看门狗同步重置。
    _resetStallWatchdog();
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      return _loadMedia(
        ctr,
        resumeMedia(
          current: ctr.current.last,
          position: ctr.state.position,
          isLive: isLive,
        ),
        play: play ?? playerStatus.isPlaying,
      ).whenComplete(_rearmBackgroundVideoSuspendAfterLoad);
    }
    return null;
  }

  /// 回前台续播前，把硬解会话重建一遍：iOS 退后台会把 VideoToolbox 会话作废，
  /// 直接续播会先来一波 `vd: Error while decoding frame (hardware decoding)!`
  /// 掉帧（画面抽动）。趁还在暂停态拨一下 hwdec，会话变新，续播才干净。
  Future<void> reinitDecoderAfterBackground() async {
    // 先开窗再发命令：命令之后几百毫秒内就会冒出 `Missing Sequence Header` /
    // `Missing reference frame` + 成片 OBU 报错（真机实测 0.35s），窗口必须在那之前
    // 生效。软件解码（hw == 'no'）同样要开：从 GOP 中间续解与硬解会话无关。
    _foregroundResumedAt = DateTime.now();
    final ctr = _videoPlayerController;
    final hw = hwdec;
    if (ctr == null || hw == null || hw == 'no') return;
    try {
      // 三个 command 必须**同步连发**（中间不 await）：async 函数体在第一个 await 前
      // 同步跑，mpv 队列顺序才是 no → 原值 → seek。若在中间 await，play 的 pause=false
      // 会插进来。
      //
      // 补 seek 是这次的关键：切 hwdec 会清空参考帧池，续播位置若在 GOP 中间就解不出
      // （Missing reference frame / Sequence Header 风暴，被看门狗误判成坏字节换源）。
      // seek 到当前位置强制 mpv 落到关键帧、重建参考帧，续播才干净。
      final pos = ctr.state.position.inMilliseconds / 1000.0;
      final futures = [
        ctr.command(['set', 'hwdec', 'no']),
        ctr.command(['set', 'hwdec', hw]),
        ctr.command(['seek', pos.toStringAsFixed(3), 'absolute']),
      ];
      await Future.wait(futures);
    } catch (_) {
      // 切 hwdec / seek 失败宁可带旧会话续播，也别把返回动作搞丢。
    }
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

  /// 认领「渲染上下文被拆掉后，能用**当前 URL** 把它重新建起来」的页面。
  ///
  /// 键是**页面身份 token**（`Object()`，纯身份，不重写 `==`），值是它要求的重载动作。
  /// 合成一个 Map 而不是两个集合并排，是为了让"登记身份"和"挂回调"**在结构上**就是同
  /// 一次操作 —— 拆成两个集合就得靠纪律维持同步，漏一处 [_renderRebuildBlocker] 的
  /// 等式立刻失真。
  ///
  /// 空表本身就是一道安全阀：没有页面认领时 [_renderRebuildBlocker] 会拦住重建，
  /// 否则拆掉的播放器没人再建起来，画面反而回不来了。
  final Map<Object, Future<void> Function()> _renderReloadClaimants = {};

  /// 其中**已休眠**的那部分：被别的页盖住时 `didPushNext` 卸了认领，但页面还在。
  ///
  /// 它存在的唯一理由：[_renderRebuildBlocker] 要能回答"`_playerCount` 多出来的那几个
  /// 到底是谁"。休眠的视频页返回时 `didPopNext` 会重挂认领 + `playerInit` 把自己救回来，
  /// 所以它们不该拦重建；而直播间只 `getInstance()`、从不登记，就落在等式差额里被拦。
  ///
  /// 身份只有三种转移，**没有第四条出路**：[addRenderReloadListener]（认领）、
  /// [removeRenderReloadListener]（休眠）、[forgetRenderReloadOwner]（页面消亡）。
  final Set<Object> _dormantRenderClaimants = {};

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

  /// 「流打不开」之后隔 3 秒再重载的那一拍。
  ///
  /// 以前 `stream.error` 的直播分支与点播分支各写了一个**匿名** `Timer`，没有任何
  /// 引用能碰到它们：`dispose()`、[_removeListeners] 都取消不了，播放器拆掉之后
  /// 的回调仍会醒来调 [refreshPlayer]。两处共用这一个槽 —— 同一媒体内 [isLive]
  /// 不会变，两条分支不会同时进入。
  ///
  /// 顺带把同一批报错收敛成一次重载：连着来两条报错时，旧写法会排两个 3 秒定时器
  /// 各调一次 [refreshPlayer]；现在是「最后一个报错之后 3 秒」重载一次。对一个已经
  /// 打不开的流，连发两次重载没有意义。
  Timer? _errorReloadTimer;

  void _scheduleErrorReload(void Function() action) {
    _errorReloadTimer?.cancel();
    _errorReloadTimer = Timer(const Duration(milliseconds: 3000), action);
  }

  void _cancelErrorReload() {
    _errorReloadTimer?.cancel();
    _errorReloadTimer = null;
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
    // 这里是**播放器创建**时的重置，整个会话只跑一次（[player] 非空时
    // [_createVideoController] 不再走 [_initPlayer]）。所以它管不到换集/换画质 ——
    // 那些由页面调 [resetDecodeErrorAccounting]。
    _clearDecodeAccounting();
    final stream = player.stream;
    _subscriptions = [
      /// playing
      stream.playing.listen((bool playing) {
        if (playing) {
          playerStatus = .playing;
          // 播放期间盯住音频会话（mpv 起音频输出时会把它改成混音，
          // iOS 就不认我们为「正在播放」）。挂在真实播放状态上，
          // 双击播放、续播、打断恢复这些不经过 play() 的路径也能覆盖到。
          audioSessionHandler?.startNowPlayingGuard();
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
          // 暂停后 mpv 不会再动会话，守卫可以歇着。
          audioSessionHandler?.stopNowPlayingGuard();
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
      // 日志订阅**无条件开着**：坏字节的唯一证词就在 mpv 的日志里（见
      // [onDecodeError]），而四条播放判据一条都看不见它。挂在"日志能落盘"这个
      // 条件上的话，落盘失败（consoleLogActive=false）时整条判据会静默失明，
      // release 里没有任何提示。收多少由 mpv 自己的档位决定（见上面的 `logLevel`）：
      // 默认档只有 error 及以上会到这儿，量很小，订阅本身几乎不要钱。
      stream.log.listen(((PlayerLog log) {
        // 采样**对所有档位**都做，不只 error/fatal：mpv 的 `logLevel` 已经限了量，
        // 而开了 verbose 之后同一段坏字节会同时从 warn/info 冒出来，只认 error
        // 等于把 open 的那一档又关掉一半。签名是解码器专有的，多收不会误报。
        // 采样搭在这里而不是 `stream.error` 上：同一个事件在两条通道上都会到，
        // 两边都采等于阈值被砍半。
        _sampleDecodeError(log.text);
        _sampleDecoderSessionFailure(log.text);
        // 「打开了但一条流都没选中」是"这个 Media 根本没播起来"的另一种说法。
        // mpv 把它报成 `[fatal] cplayer` 日志而不是 `stream.error` 事件，所以
        // 只能从这里认。换源后靠它立刻收尾本轮（见 [lastOpenFailureAt]）。
        if (log.level == 'fatal' &&
            log.text.contains('No video or audio streams selected')) {
          _noteOpenFailure(log.text);
        }
        if (kDebugMode || consoleLogActive) {
          if (log.level == 'error' || log.level == 'fatal') {
            Utils.reportError(
              '${log.level}: ${log.prefix}: ${log.text}\n${player.state.playlist}',
              null,
            );
          }
          // 错误也落盘：以前 error 只走 reportError，日志文件里反而看不到。
          debugPrint('mpv [${log.level}] ${log.prefix}: ${log.text}');
        }
      })),
      stream.error.listen((String event) {
        // 这一条在 release 里原本只走 reportError，日志文件里同样看不到 ——
        // 而它正是"流打不开"的直接证词，先落盘，再走原来的恢复逻辑。
        debugPrint('mpv error: $event');
        // 记在 return 之前：文件源的 `Failed to open file` 也要留证。
        if (event.startsWith("Failed to open ")) {
          _noteOpenFailure(event);
        }
        if (dataSource is FileSource &&
            event.startsWith("Failed to open file")) {
          return;
        }
        if (isLive) {
          if (event.startsWith('tcp: ffurl_read returned ') ||
              event.startsWith("Failed to open https://") ||
              event.startsWith("Can not open external file https://")) {
            _scheduleErrorReload(() {
              // 直播分支原先无条件重载：连接报错是"事件"不是"采样量"，一次
              // 瞬时抖动也会把正在正常播放（或用户已手动暂停）的直播拆掉重开。
              // 补上与非直播分支同源的护栏 —— 只在"前方余量真的见底"时才重载。
              //
              // 只取 [bufferedAhead] 这一条，**不复用** `|| telemetryDiverged`——
              // 这不是取舍，是等价：直播的 mpv 配置走 [liveBuffer]（只有
              // demuxer-max-bytes、没有 `cache-secs`），而 [telemetryDiverged] 读的
              // 就是 `cache-secs`：拿不到 → 阈值 `_divergedAheadSec` 恒为 0 → 该
              // getter 对直播**恒为 false**（`limit > 0` 短路，见其定义）。写全
              // `|| telemetryDiverged` 不改变结果，但会让读者以为这条路上也在防
              // "遥测失真"，故省略、只留真正起作用的那半。
              //
              // [bufferedAhead] 对直播同样成立：它是 demuxer 缓存末端减播放位置，
              // 连接断了缓存不再增长、位置继续推进，必然归零；该项遥测若取不到则
              // 恒为 0 → 护栏退化成放行（旧行为），fail-open，不会把真故障夹死。
              // `!isSeeking` 对直播恒为真（直播不可 seek），保留只为与非直播分支
              // 保持同形。
              if (bufferedAhead <= 0 && !isSeeking.value) {
                refreshPlayer();
              }
            });
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
              _scheduleErrorReload(() {
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

  /// 「闸门全开 + 画面为空」这段状态的起点；null = 没有正在累积的窗口。
  ///
  /// 它是旧的 `_noVideoProbes` 计数器的替身：每一个旧代码把计数清零的返回点，现在
  /// 都改成把它置空（见 [_resetNoVideoWindow] 与各处复位点）。**一处都不能漏** ——
  /// 漏了窗口就会跨装载存活，新装载第一拍就定罪。
  DateTime? _noVideoWindowStart;

  /// 上一拍时的播放位置，给"强指纹"加一条"位置真的在推进"的保险
  /// （见 [_noVideoStrongFingerprint]）。
  ///
  /// 位置冻住**不关窗**（旧弱指纹路本来也不看位置），只是让强指纹不成立 ⇒ 这次定罪
  /// 自动落到 [PlayerTuning.noVideoWindowWeak] 那档、上报行也不带 ` [强指纹]` 后缀。别改成
  /// "冻住就关窗"：位置冻住 + 不在缓冲正是卡顿看门狗抓不到的盲区（它的判据要
  /// `isBuffering && bufferedAhead == 0`），那样会静默地收窄这张网。
  int _noVideoLastPosition = 0;

  /// 关掉正在累积的窗口。任何一道门成立、或画面起来了，都必须调它。
  void _resetNoVideoWindow() {
    _noVideoWindowStart = null;
    _noVideoLastPosition = 0;
  }

  /// 本媒体已经就地重建过几次渲染上下文。每换一次媒体在 [_createVideoController]
  /// 里重置（但**绕开**自己那次重建，理由见那里）。见 [PlayerTuning.noVideoRebuildMax]。
  int _noVideoRebuilds = 0;

  /// 渲染上下文正在拆旧重建（里面有 await，采样回调可能重入）。
  ///
  /// 它同时是 [renderContextGen] 的空窗信号：这段时间 [_videoController] 会是
  /// null，视频区那几个节点要忍住别把播放器判成"该塌"。
  bool _rebuildingRenderContext = false;

  /// 正在跑的正是**我们自己的**那次重载（见 [_runRenderContextRebuild]）。
  ///
  /// 它与"用户在这一刻发起了装载"在 [_createVideoController] 里长得一模一样
  /// （那时 [_rebuildingRenderContext] 也还是 true），只能靠这个标志区分：
  /// 额度只在用户发起的装载上重新给，我们自己的重载不能给自己续命 —— 否则就是
  /// "探满 → 重建 → 探满 → …" 的无限重建。
  bool _ownReload = false;

  /// 旧 [Player] 正在拆（[Player.dispose] 里有 `VideoOutputManager.Dispose` +
  /// `unregisterTexture`，最长 2s）。
  ///
  /// 拆旧期间两个字段已经被置空，任何并发装载者都会去建**新**的渲染上下文
  /// （这是我们故意留的：不能让他们复用正在拆的对象）；让他们在 [_initPlayer]
  /// 开头等这一个 Future，原生那边的 Create 与 Dispose 才不会同时抢一个 handle。
  Future<void>? _playerTeardown;

  /// 见 [_rebuildingRenderContext]。
  bool get rebuildingRenderContext => _rebuildingRenderContext;

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

  /// 「强指纹」：有把握说"解码器真的起来了"。
  ///
  /// 两个都是非空串即成立：`video-codec` 报的是选中的视频编码，`hwdec-current`
  /// 由空变非空**只有"解码器真的开了"这一种可能**（2026-10-15 真机同局核过：
  /// 02:40:16 `hwdec 0x0` → 02:40:27 `hwdec videotoolbox`，后者正是死锁现场）。
  /// 有它垫底，才敢用短窗那一档（[PlayerTuning.noVideoWindow]）。
  ///
  /// **每拍重算、不跨拍记忆**：第 1 拍抽风读到空、第 2 拍还能补回来；用粘性累积
  /// 标志会把一次偶然的非空当成永久结论。
  bool get _noVideoStrongFingerprint =>
      debugNoVideoStrongOverride?.call() ??
      (_safeProp('video-codec').isNotEmpty &&
          _safeProp('hwdec-current').isNotEmpty);

  /// 「只有声音没画面」的现场判据：闸门全开 + 画面为空，连续攒满一个窗口即定罪。
  ///
  /// 音频参数正常、视频轨却始终为空 —— 这正是 2026-10-11 那次 iOS 黑屏的形态
  /// （当时拍到的「播放信息」里 Resolution 0x0、VideoParams 全空），而 CDN 与
  /// 编码可用性都已排除。build 5483 的 mpv 日志把病因定到了**视频输出**一侧：
  /// 解码、滤镜、音轨全部正常，唯独那一次没有建出视频输出 —— 日志里没有
  /// `VO: [libmpv]` / `vo/libmpv: reconfig` / `libmpv_render: Window size` 这三行。
  /// （别拿 `mpv_render_context_render() not being called or stuck.` 当判据：
  /// 正常播放的每一段里都有它，只是排队晚了一点点。）
  ///
  /// 判据是**时间窗**（见 [PlayerTuning.noVideoWindow]），不再数探数：视频参数本来就比音频
  /// 晚到，所以 seek / 换源 / 重新缓冲这三个"参数本来就该是空的"窗口必须显式放过，
  /// 否则会把自己的动作当成死锁。定罪之后**直接**走 [_rebuildRenderContextOnNoVideo]
  /// —— 中间那一档「钉住输出尺寸」2026-10-15 已删（见 [_rebuildRenderContextOnNoVideo]
  /// 上方的墓碑注释）。
  void _checkNoVideoTrack(DateTime now) {
    if (_videoSuspendedForBackground ||
        onlyPlayAudio.value ||
        isLive ||
        position.value <= 0 ||
        isSeeking.value ||
        _processing ||
        // 重建期间 ticker 会被 _startListeners 重新挂上，而那时画面本来就还没
        // 起来 —— 不放过的话会把自己刚做完的动作当成新的死锁再探一轮。
        _rebuildingRenderContext ||
        isBuffering.value) {
      _resetNoVideoWindow();
      return;
    }
    if (_hasVideoTrack) {
      _resetNoVideoWindow();
      return;
    }
    final start = _noVideoWindowStart;
    if (start == null) {
      // 开窗那一拍不定罪：这一拍之前画面空了多久是无从知道的（最多一拍），
      // 拿它当账去凑窗口就是白送。
      _noVideoWindowStart = now;
      _noVideoLastPosition = position.value;
      return;
    }
    // 强指纹每拍重算（不跨拍记忆），再叠一条"位置真的比上一拍大"做双保险
    // —— 音频在推进本来已由上面 `position.value <= 0` 那道门保证，这里只是
    // 把"推进"这件事钉在第一手证据上。指纹不成立（含位置冻住）就走长窗那一档。
    final strong =
        _noVideoStrongFingerprint && position.value > _noVideoLastPosition;
    _noVideoLastPosition = position.value;
    if (now.difference(start) <
        (strong
            ? PlayerTuning.noVideoWindow
            : PlayerTuning.noVideoWindowWeak)) {
      return;
    }
    // 重新开窗：下一次定罪要再攒满一个窗口。额度用尽之后就靠这个节奏在日志里
    // 留痕（每窗一行）。**这里不需要"距上次重建至少隔多久"的冷却** —— 窗口长度
    // 本身就是那个冷却，理由见 [PlayerTuning.noVideoWindow]。
    _noVideoWindowStart = now;
    debugPrint(
      '无视频轨: 音频正常但画面始终为空 (audio ${_safeProp('audio-codec')} '
      'video ${_safeProp('video-codec')} hwdec ${_safeProp('hwdec-current')} '
      '位置 ${position.value}s)'
      '${_noVideoRebuilds > 0 ? ' [本媒体已重建 $_noVideoRebuilds 次]' : ''}'
      '${strong ? ' [强指纹]' : ''}',
    );
    _rebuildRenderContextOnNoVideo();
  }

  /// 现在能不能就地重建渲染上下文；不能就返回原因（给日志和测试用）。
  ///
  /// 「有没有页面认领重载」与「多出来的共用者是谁」这两条是**安全阀**，不是优化：
  /// 没有页面认领时拆掉就没人再把它建起来；而单例被别的页面共用时拆掉它会把那一页的
  /// 播放一起掀掉。两种都宁可退化成老出路（用户手动退出视频页再进来），也不能在这里动手。
  ///
  /// 共用者这一条是**细口径**的：`_playerCount` 数的是"实例化过单例的页面"，不区分谁
  /// 在用 —— 视频页被另一个视频页压住时，旧页只是**休眠**（`didPushNext` 卸了认领，
  /// 返回时 `didPopNext` 重挂 + `playerInit`），可它的计数一直挂着（减计数在页面
  /// `dispose()` 里，被压住时不发生）。照老判据 `_playerCount != 1` 会在整个覆盖期间
  /// 恒拦。所以这里改问两个更准的问题：
  ///
  /// - `_playerCount == 登记总数`：每个被计数的页面都在名册里。直播间只 `getInstance()`
  ///   从不登记，等式就不成立 → 拦。
  /// - 在册认领者恰好一个：同时有两个页面自认活跃时无法判定掀谁 → 拦。
  ///
  /// 反向也安全：任何残留/过期条目都让"登记总数"变大，等式更容易不成立 → 退化成拦。
  String? _renderRebuildBlocker() {
    if (_rebuildingRenderContext) {
      return '已在重建';
    }
    // 后台省电关掉的视频轨不是故障。
    if (_videoSuspendedForBackground) {
      return '视频轨是后台省电关掉的';
    }
    // 真在后台时也不动手：重建会拆音频输出、断音 1~3 秒，iOS 在这一下就把
    // 「正在播放」交出去（见 [_deferredDecoderRebuild]）。画中画例外 ——
    // 那里还有画面要看，真黑屏仍然需要这条唯一的救援路。
    if (_appInBackground && !(Platform.isIOS && IOSPipHelper.needsUpdate)) {
      return '在后台（重建会断音、丢正在播放）';
    }
    if (_noVideoRebuilds >= PlayerTuning.noVideoRebuildMax) {
      return '本媒体已重建 $_noVideoRebuilds 次';
    }
    // 「没有认领者」排在"共用者"之前：否则 `_playerCount == 1` 而没有认领者时，下面那条
    // 会先把这一页判成"没登记身份"，把更有信息量的理由盖掉。
    if (_renderReloadClaimants.isEmpty) {
      return '没有页面认领重载';
    }
    final registered =
        _renderReloadClaimants.length + _dormantRenderClaimants.length;
    if (_playerCount != registered) {
      final extra = _playerCount - registered;
      return extra > 0
          ? '有 $extra 个共用者没登记身份（直播间/装载中）'
          : '共用者登记表比实况多 ${-extra} 个（有残留）';
    }
    if (_renderReloadClaimants.length != 1) {
      return '有 ${_renderReloadClaimants.length} 个页面同时认领重载';
    }
    if (_videoPlayerController == null) {
      return '播放器不存在';
    }
    if (_processing) {
      return '换源/换集在途';
    }
    return null;
  }

  void _rebuildRenderContextOnNoVideo() {
    if (_renderRebuildBlocker() case final reason?) {
      debugPrint('就地重建: 跳过（$reason）');
      return;
    }
    unawaited(_runRenderContextRebuild());
  }

  // ---- 测试缝（照 debugSampleStarve 的写法：判据本身只看公开/可直接摆的字段）----

  @visibleForTesting
  String? debugRenderRebuildBlocker() => _renderRebuildBlocker();

  @visibleForTesting
  int get debugNoVideoRebuilds => _noVideoRebuilds;

  @visibleForTesting
  set debugNoVideoRebuilds(int value) => _noVideoRebuilds = value;

  /// 测试里 `getInstance()` 每次进 setUp 都会 +1，跨用例只增不减，摆不成"恰好
  /// 一个页面持有单例"这个前提。
  @visibleForTesting
  set debugPlayerCount(int value) => _playerCount = value;

  @visibleForTesting
  set debugRebuildingRenderContext(bool value) =>
      _rebuildingRenderContext = value;

  /// 「闸门一成立就关窗」这条断言要有个能直接看的对象，不然只能靠"报没报"间接推。
  ///
  /// 它也是跨用例的脏状态：单例字段只增不减，而复位点要么在 [_createVideoController]
  /// 里（测试够不到）、要么靠用例自己走一遍判据去关。用例 setUp / tearDown 里都要
  /// 主动关一次窗（借 `position.value <= 0` 那道门）。
  @visibleForTesting
  DateTime? get debugNoVideoWindowStart => _noVideoWindowStart;

  /// 强指纹注入缝。
  ///
  /// 测试进程里没有原生 Player ⇒ [_safeProp] 恒返回空串 ⇒ [_noVideoStrongFingerprint]
  /// 永远为假，短窗（[PlayerTuning.noVideoWindow]）根本走不到，也就无从验证。这个缝让用例
  /// 直接摆强 / 弱指纹。
  ///
  /// 默认 `null` ⇒ 走**真实判据**（测试里即弱指纹 ⇒ 长窗 [PlayerTuning.noVideoWindowWeak]）。
  @visibleForTesting
  bool Function()? debugNoVideoStrongOverride;

  /// 同上：认领名册只在页面 `dispose()` 里清，测试里没有页面，
  /// 用例里那条 `remove` 又写在断言之后 —— 断言一抛就漏，后面的用例看到非空集合，
  /// 会被连带弄红（看起来像它自己的问题）。
  @visibleForTesting
  void debugClearRenderReloadListeners() {
    _renderReloadClaimants.clear();
    _dormantRenderClaimants.clear();
  }

  /// 在册认领者的身份（键），用例用来摆"谁认领着、谁休眠着"这两个前提。
  @visibleForTesting
  Set<Object> get debugRenderReloadClaimants =>
      _renderReloadClaimants.keys.toSet();

  @visibleForTesting
  Set<Object> get debugDormantRenderClaimants => _dormantRenderClaimants;

  /// [now] 由调用方给：ticker 那边就是它自己那一拍的 `now`，测试里给假时钟 ——
  /// 本 group 一律手工重放时序，不真等秒（真 ticker 在测试进程里也没被挂上）。
  /// 照 [debugSampleStarve] 的参数式写法，不引入可变的时钟覆写字段，于是没有
  /// 需要 tearDown 收拾的跨用例状态。
  @visibleForTesting
  void debugCheckNoVideoTrack(DateTime now) => _checkNoVideoTrack(now);

  /// 就地重建渲染上下文 —— "退出视频页再进来"的页内等价物。
  ///
  /// 只做一件事：把旧 [Player] 拆干净（它会连带 `VideoOutputManager.Dispose` +
  /// `unregisterTexture`），然后请页面用**当前 URL** 重跑一次它自己的装载路径。
  /// 库里不自己重拼一遍 `player.open` —— 那要手抄"退出再进"做过的每一件事
  /// （`onInit` 恢复字幕、seek 回 `playedTime`、按播放态决定起不起播、倍速、
  /// volume、shader…），漏一件就是一个新 bug。页面那边本来就有这条路
  /// （`didPopNext` 里那句 `playerInit(autoplay: playerStatus.isPlaying)`）。
  Future<void> _runRenderContextRebuild() async {
    _rebuildingRenderContext = true;
    _noVideoRebuilds++;
    debugPrint(
      '就地重建: 开始（第 $_noVideoRebuilds/${PlayerTuning.noVideoRebuildMax} 次）',
    );
    try {
      // 次序不可换：_removeListeners 先跑（取消 ticker + 把 _subscriptions 置
      // null，否则 _startListeners 的 assert 会炸、旧订阅也会泄漏），两个字段
      // 都置空后 _initPlayer 的两条 assert 才成立。
      _removeListeners();
      final old = _videoPlayerController!;
      _videoPlayerController = null;
      _videoController = null;
      // 上下文**没了**也是变了一代：UI 只认 Rx，不递增它就不会重跑，视频区会一直
      // 抱着已经 dispose 的那个 controller。销毁与重建各递增一次（见 [_initPlayer]），
      // "gen 变了 ⇔ 上下文对象换了"这条不变量才闭合。
      renderContextGen.value++;
      // 旧 player 必须等它拆完才能建新的：它的 release 里在跑
      // VideoOutputManager.Dispose + unregisterTexture，不等就建新输出会让两个
      // VideoOutput 抢同一个 handle。**并且**要把这个 Future 挂出去：这段时间里
      // 任何并发装载者都会看到 player == null 而去建新的（这是我们故意留的 ——
      // 不让他们复用正在拆的对象），让他们在 [_initPlayer] 开头等这一件事。
      final teardown = old.dispose();
      _playerTeardown = teardown;
      await teardown;
      if (identical(_playerTeardown, teardown)) {
        _playerTeardown = null;
      }
      _noVideoWindowStart = null;
      if (_playerCount == 0) {
        return;
      }
      // 请页面重载。用户在这段 await 里自己换了集也无妨：页面那次 playerInit
      // 会先建成新 player，我们这轮再 playerInit 只是把它重新 open 一遍
      // （_createVideoController 见 player != null 就复用），不会出现两个 Player。
      // _ownReload 让 _createVideoController 分清"这是我们自己的重载"与"用户发起的
      // 装载"—— 两者在它眼里都带着 _rebuildingRenderContext == true。
      _ownReload = true;
      for (final reload in _renderReloadClaimants.values.toList()) {
        await reload();
      }
    } finally {
      _ownReload = false;
      _rebuildingRenderContext = false;
      _noVideoWindowStart = null;
      _resetStallWatchdog();
    }
  }

  /// 画面是否已经起来。判据与 [_checkNoVideoTrack] 相同：宽或视频参数任一非零。
  bool get _hasVideoTrack {
    final state = _videoPlayerController?.state;
    return (state?.width ?? 0) > 0 || (state?.videoParams.w ?? 0) > 0;
  }

  // 5484 上线前这里还有两级（`vid=no` → `auto`、`video-reload`），线上日志把
  // 它们的账算清楚了，别再捡回来：
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
  // **第 3 级「钉住输出尺寸」也在 2026-10-15 删掉了。** 归档 10 局里 20 次钉尺寸
  // 只有 1 次真把画面救回来（≈5%），而且第 2 次钉在 Dart 层就被判"尺寸没变"
  // （`NativeVideoController.setSize` 见值相同直接 `return null`），什么都没发到
  // 原生、白等 1.2s。它的病因诊断倒是对的 —— 原生 `VideoOutput.setSize` 只把宽高
  // 存下来、不渲染，渲染只发生在 `_updateCallback` 里，而那次 mpv 压根没回调
  // （同局健康装载必有 `VO: [libmpv]` + 约 200ms 后 `libmpv_render: Window size:`
  // 这一对，坏的那次 15.7s 里一条都没有）—— 但"补一发强制渲染"这件事 2026-10-15
  // 的 fork 补丁（`e88d8416`）实测也没打中：真机上画面最后是**就地重建**救回来的，
  // 钉尺寸那 2 秒纯属浪费。所以现在定罪之后**直接** [_rebuildRenderContextOnNoVideo]，
  // 中间不再有任何一档。
  //
  // 原生侧到底能不能救，要靠 fork 的探针回答：它会报出"死锁时那个更新回调有没有
  // 被叫过"。回调没被叫 ⇒ 原生可以自己主动画一帧撬开；被叫了却还配不上 ⇒ 得从
  // 别处下手。**在拿到那个答案之前，别再把任何一档加回 Dart 侧。**

  /// 解码错误的采样：攒够 [PlayerTuning.decodeErrorBurst]（**或** [PlayerTuning.decodeErrorDenseBurst]）
  /// 条就上报一次 [onDecodeError]。
  ///
  /// 和另外三条采样不同，它不由 [_startStallTicker] 的心跳驱动，而是被
  /// `stream.log` 推进 —— 报错是**事件**不是采样量，ticker 那一秒一拍的
  /// 节奏会把它抹平（实测那一局 6 秒里就有几十条）。
  ///
  /// **两个档，任一满足即上报**：量的是同一个病、走的也是同一个动作。
  ///
  /// - 稀疏档：[PlayerTuning.decodeErrorBurst] 条 / [PlayerTuning.decodeErrorWindow]，含同包去重 ——
  ///   抓"成百条不停地刷"那种持续风暴。
  /// - 密集档：[PlayerTuning.decodeErrorDenseBurst] 行 / [PlayerTuning.decodeErrorDenseWindow]，
  ///   **不去重** —— 抓"几十毫秒里挤了几百条"那种短促爆发，也就是去重会把它们
  ///   整段数没的那一档（来由见 [PlayerTuning.decodeErrorDenseBurst]）。
  void _sampleDecodeError(String text, {DateTime? at}) {
    final now = at ?? DateTime.now();
    // 回前台续播窗口：这一段报错是"本机解码链还没接上"，不是"镜像给了坏字节"。
    // 两族的动作相反（换源 vs 重建解码器），窗口内一律让位给后者。
    //
    // **不能**更新 [lastDecoderCorruptionAt]：换源恢复判据拿它当"新镜像还在吐
    // 坏字节"的证据，记上的话会把本机续解算到镜像头上，[CdnSwitchMixin] 要么
    // 判定未恢复继续换，要么把一条健康镜像拉黑。
    //
    // 窗口内认两族：坏字节签名（风暴主体）和续解签名（头几行 `Missing Sequence
    // Header` / `Missing reference frame`，它们本身不是坏字节）。
    if (_inForegroundResumeWindow(now)) {
      if (isDecoderCorruptionLog(text) || isDecoderContinuationLog(text)) {
        _noteForegroundResumeFailure(now);
      }
      return;
    }
    if (!isDecoderCorruptionLog(text)) return;
    // 不受静默期限制的"最后一次坏字节"时刻：给换源后的干净窗口判据用。
    lastDecoderCorruptionAt = now;
    // 记账（含窗口淘汰与同包去重）在 [recordDecodeErrorHit] 里，是纯函数。
    final sparseReached = recordDecodeErrorHit(
      _decodeErrors,
      now,
      window: PlayerTuning.decodeErrorWindow,
      burst: PlayerTuning.decodeErrorBurst,
      lineDedupe: PlayerTuning.decodeLineDedupe,
    );
    // 密集档把去重窗设成 0：`now.difference(last) < Duration.zero` 恒为假，
    // 于是**每一条原始行都算数** —— 正是这一档要的语义，不必另写一个函数。
    final denseReached = recordDecodeErrorHit(
      _decodeErrorDense,
      now,
      window: PlayerTuning.decodeErrorDenseWindow,
      burst: PlayerTuning.decodeErrorDenseBurst,
      lineDedupe: Duration.zero,
    );
    if (!sparseReached && !denseReached) return;
    // **先记账、再判静默期**：静默期压的是上报，不是计数。换源重载期间旧流的
    // 报错照记 —— 它们说明的正是刚才那段字节是坏的。这样静默期一过，只要风暴
    // 还在继续，下一条报错就能立刻再上报一次，而不是从头再攒 12 条（换过去的
    // 镜像一样坏时，那 12 条就是白白多冻几秒）。所以静默期内**不清空**窗口。
    if (now.isBefore(_decodeErrorUntil)) return;
    _decodeErrors.clear();
    _decodeErrorDense.clear();
    _decodeErrorUntil = now.add(PlayerTuning.decodeErrorCooldown);
    // 报的是哪一档要写清楚：这两档在日志里长得像，而"44 毫秒 260 条"和
    // "6 秒 12 条"对不上账时，就靠这一行分辨盲区有没有回来。
    //
    // 两档都成立时报稀疏档那行 —— 那是原本就在的字符串，这样新字符串**只会**
    // 出现在旧代码打印不出任何东西的地方，读日志的老习惯（和清单里的速查表）
    // 一条都不用改。
    debugPrint(
      'CDN 看门狗: 解码错误风暴（'
      '${sparseReached ? '${PlayerTuning.decodeErrorWindow.inSeconds}s 内 '
                '${PlayerTuning.decodeErrorBurst} 条' : '${PlayerTuning.decodeErrorDenseWindow.inMilliseconds}ms'
                ' 内 ${PlayerTuning.decodeErrorDenseBurst} 行'}'
      '），当前镜像给的字节解不出画面 —— 上报换源',
    );
    // 回执：页面在途轮次收不下这一发（返回 false）时把静默期缩到 [PlayerTuning.decodeErrorRetryBackoff]
    // —— 两个窗口已经在上面清过，再攒够门槛就重报，风暴不会因为"页面正忙"永久丢失。
    // 用同一个 now（别重新取时钟：语义上应与这一次采样同一时刻）。没有页面挂上来
    // （null）时行为与旧版完全一致。
    final listener = onDecodeError;
    if (listener != null &&
        !listener(videoPlayerController?.state.position ?? Duration.zero)) {
      _decodeErrorUntil = now.add(PlayerTuning.decodeErrorRetryBackoff);
    }
  }

  /// 这一次采样是不是落在回前台续播窗口里（见 [_foregroundResumedAt]）。
  ///
  /// [now] 早于窗口起点（测试用的假时钟）时不算：那种情况没法判断"过了多久"。
  bool _inForegroundResumeWindow(DateTime now) {
    final start = _foregroundResumedAt;
    return start != null &&
        !now.isBefore(start) &&
        now.difference(start) < PlayerTuning.foregroundResumeWindow;
  }

  /// 记下一条"这个 Media 根本没打开"的证词。
  ///
  /// 只存时刻与原文，动作在页面那边：换源途中才需要立刻收尾，正常播放时
  /// `stream.error` 原有的重载路径照旧（两条互不干扰）。
  void _noteOpenFailure(String text, [DateTime? at]) {
    lastOpenFailureAt = at ?? DateTime.now();
    lastOpenFailure = text;
  }

  /// 回前台续播窗口里的解码报错：记进**会话族**，攒够就重建本机解码器。
  ///
  /// 与 [_sampleDecoderSessionFailure] 共用账本和冷却，但**不走它那几道闸门**
  /// （`isBuffering` / `bufferedAhead <= 0` / `isSeeking`）：回前台第一拍这几样
  /// 恰恰全是"不健康"的样子（实测 `重新缓冲 true`、余量归零），而那正是要抓的
  /// 现场。闸门在这里放行是安全的 —— 窗口只有 [PlayerTuning.foregroundResumeWindow]
  /// 那么长，且来源被限定为"刚重建过解码链"。
  void _noteForegroundResumeFailure(DateTime now) {
    if (!recordDecodeErrorHit(
      _sessionFailures,
      now,
      window: PlayerTuning.sessionFailWindow,
      burst: PlayerTuning.sessionFailBurst,
      lineDedupe: PlayerTuning.decodeLineDedupe,
    )) {
      return;
    }
    if (now.isBefore(_sessionHealUntil)) return;
    _sessionHealUntil = now.add(PlayerTuning.sessionFailCooldown);
    debugPrint(
      'CDN 看门狗: 回前台续播仍在刷解码报错（${PlayerTuning.sessionFailWindow.inSeconds}s 内 '
      '${PlayerTuning.sessionFailBurst} 条），本机解码链没接上 —— 重建解码器',
    );
    refreshPlayer();
  }

  /// 硬解会话失效的采样：攒够 [PlayerTuning.sessionFailBurst] 条就**重建本机解码器**。
  ///
  /// 与 [_sampleDecodeError] 是两个相反的结论，见 [isDecoderSessionFailureLog]：
  /// 那条路是"镜像给的字节解不出来" → 换源；这条路是"本机硬解会话被系统作废了"
  /// → 重开同一个 Media。2026-10-11 实测那一局（退后台 6 分钟再回前台，0.881 秒
  /// 78 行、随后画面再没回来）正是后者：换源毫无用处 —— 字节是好的，位置和缓冲
  /// 余量全程健康。所以这里**不**上报 [onDecodeError]。
  ///
  /// 同样搭在 `stream.log` 上、同样因为"报错是事件不是采样量"，理由见
  /// [_sampleDecodeError] 的注释。
  void _sampleDecoderSessionFailure(String text) {
    if (!isDecoderSessionFailureLog(text)) return;
    final now = DateTime.now();
    // 让位于坏字节：两族的动作相反，同时开火会互相拆台（见那个常量的注释）。
    final lastBadBytes = lastDecoderCorruptionAt;
    if (lastBadBytes != null &&
        now.difference(lastBadBytes) < PlayerTuning.sessionFailDeferBadBytes) {
      return;
    }
    // 闸门：拆链 / 重载的缝隙里，会话报错是**正常**产物，不该拿去重建。本故障
    // 那一刻这几样全是健康的（实测：余量 28s、重新缓冲 false、输出参数
    // 1920x1080），所以它照样进得来。
    //
    // 换源在途由 [_processing] 挡（页面 `playerInit` 会置它）；[refreshPlayer]
    // 不走那条路、自己不会置 [_processing]，所以另用 [isBuffering] 与余量把
    // "任何一次重载的拆装抖动"一起挡在外面。
    if (isSeeking.value ||
        _processing ||
        onlyPlayAudio.value ||
        isBuffering.value ||
        bufferedAhead <= 0 ||
        // 输出参数是好的 ⇒ 坏在解码链上，不是 [_checkNoVideoTrack] 那条死锁 ——
        // 那条自己有自愈，两边不能同时动手。
        !_hasVideoTrack) {
      return;
    }
    if (!recordDecodeErrorHit(
      _sessionFailures,
      now,
      window: PlayerTuning.sessionFailWindow,
      burst: PlayerTuning.sessionFailBurst,
      lineDedupe: PlayerTuning.decodeLineDedupe,
    )) {
      return;
    }
    // 先记账、再判冷却：同 [_sampleDecodeError]，冷却压的是"动手"不是计数。
    // 这里不用清 [_sessionFailures] —— 冷却（30s）比窗口（3s）长得多，到那时
    // 旧记录早就自己出窗了，清是句死代码。
    //
    // 后台不重建：重建会拆掉音频输出、断音 1~3 秒，iOS 会趁这一下把「正在播放」
    // 交给别的 App，声音回来卡片也回不来（2026-10-21 真机，见
    // [_deferredDecoderRebuild]）。后台没有画面，回前台再修。
    if (appInBackground) {
      if (!_deferredDecoderRebuild) {
        _deferredDecoderRebuild = true;
        debugPrint('CDN 看门狗: 硬解会话失效，但在后台 —— 推迟到回前台再重建');
      }
      return;
    }
    if (now.isBefore(_sessionHealUntil)) return;
    _sessionHealUntil = now.add(PlayerTuning.sessionFailCooldown);
    debugPrint(
      'CDN 看门狗: 硬解会话失效（${PlayerTuning.sessionFailWindow.inSeconds}s 内 '
      '${PlayerTuning.sessionFailBurst} 条），本机解码器被系统作废 —— 重建解码器',
    );
    // 重开同一个 Media：位置保留（见 [refreshPlayer] 里的 `start: state.position`），
    // 解码器和视频输出都是全新的。代价是缓冲从头攒、1~3 秒卡顿 —— 比永久黑屏值。
    refreshPlayer();
  }

  /// 卡顿看门狗：前两条判据共用一个 [onStall] 回调，第三条的两副面孔分别走
  /// [onBufferStarve]（余量趴在低位）和 [onTelemetryDiverged]（余量失真）。
  ///
  /// 1. 位置连续 [PlayerTuning.stallSeconds] 秒没有推进，再以 [isBuffering] 作确认。
  ///    不能只看 [isBuffering] —— 普通重新缓冲也会让它为 true，会造成切换风暴。
  /// 2. [_sampleRebuffer]：窗口内缓冲归零的上升沿达到 [PlayerTuning.rebufferTrigger] 次。
  ///    判据 1 看不到反复小卡顿（位置一恢复就清零），由判据 2 补上。
  /// 3. [_sampleStarve]：前向缓冲长期趴在低位。判据 1、2 都要求 buffered 归零，
  ///    而 mpv 有 cache-secs 打底、换源型卡顿时位置又由音频时钟推着走，
  ///    两者都见不到"余量在变少"——这条只看 [buffered]，是唯一的早期信号。
  ///
  /// 也不能用 `progress`：seek 期间它返回 seekPosition，必须用原始的 [position]。
  void _startStallTicker() {
    _stallTicker?.cancel();
    _resetStallWatchdog();
    // 诊断：一次进程只打一条，用来回答「装上的包到底带不带这段代码、开关读到
    // 什么值」。生命周期那条日志只有在真收到事件时才会出现，没有它分不清
    // 「包是旧的」和「回调没来」。
    if (!_bgVideoSuspendDiagLogged) {
      _bgVideoSuspendDiagLogged = true;
      debugPrint(
        '后台省电: 播放器就绪（诊断：开关 ${_backgroundVideoSuspendEnabled ? '开' : '关'}）',
      );
    }
    _stallTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      // 心跳放在闸门之前：闸门本身也可能是"什么都不发生"的原因之一，
      // 必须先看到它当时的取值。
      final now = DateTime.now();
      if (now.difference(_lastHeartbeat).inSeconds >=
          PlayerTuning.heartbeatSeconds) {
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
      // 「无视频轨」是**时间窗**判据（见 [PlayerTuning.noVideoWindow]），所以 1s 一拍都得看 ——
      // 少看一拍就是窗口判据白多出来的相位误差。旧的 2s 采样节流因此取消。
      _checkNoVideoTrack(now);
      _maybeSuspendDueVideoInBackground();
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
        _starveLastReportAt = null;
        return;
      }
      _sampleRebuffer(now);
      _sampleStarve(now);
      if (position.value != _stallLastSecond) {
        _stallLastSecond = position.value;
        _stallFrozen = 0;
        return;
      }
      if (++_stallFrozen >= PlayerTuning.stallSeconds &&
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
    _starveLastReportAt = null;
  }

  /// 进入/推进静默期。任何一次装载（开播、换源、换 P、切换 CDN）以及 seek
  /// 都会让缓冲归零，必须先把这段时间静音掉，否则等长冻结判据会把自己的动作
  /// 读成卡顿。
  void _armRebufferSuppress() {
    _rebufferSuppressUntil = DateTime.now().add(PlayerTuning.rebufferSuppress);
    _disarmTriggers();
  }

  /// 饥饿阈值：mpv 回填水位（`demuxer-hysteresis-secs`）的
  /// [PlayerTuning.starveFloorFraction]。低于 [PlayerTuning.starveMinSeconds] 视为没有观测余量，
  /// 返回 0 表示不启用。
  ///
  /// 取值要从 mpv 真正拿到的 [buffer] 里读，而不是用当前倍速重算：`buffer` 是
  /// 首次装载时定下的 late final，[setPlaybackSpeed] 不会重建它，两者会不一致
  /// （例如按 1x 装载后改成 2x，水位仍是按 1x 算的，而缓冲消耗速度已翻倍）。
  double get _starveThresholdSec {
    final floor = double.tryParse(buffer['demuxer-hysteresis-secs'] ?? '') ?? 0;
    final threshold = floor * PlayerTuning.starveFloorFraction;
    return threshold < PlayerTuning.starveMinSeconds ? 0 : threshold;
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

  /// 失真阈值：mpv 缓存上限 `cache-secs` 的 [PlayerTuning.divergedFactor] 倍。读不到就
  /// 不启用（返回 0）—— 直播走的是 [liveBuffer]，压根没有这个键，本地点播
  /// 文件更是 `cache: no`，两者的 `demuxer-cache-time` 语义本来也不同，不该
  /// 套这条判据。跟 [_starveThresholdSec] 用"返回 0 表示不启用"是同一套约定。
  double get _divergedAheadSec {
    final cache = double.tryParse(buffer['cache-secs'] ?? '') ?? 0;
    return cache > 0 ? cache * PlayerTuning.divergedFactor : 0;
  }

  /// 判据 3：只盯 [bufferedAhead]，不看位置也不要求 [isBuffering]——换源型卡顿
  /// 时位置一直在推进，core-idle / paused-for-cache 也未必为真。两头都要防：
  /// 余量长期趴在低位是"供不上"，余量涨到 [telemetryDiverged] 是"遥测被音频
  /// 拖走了"，后者正是"只有声音、画面冻住"。
  ///
  /// 每段饥饿只上报一次，直到缓冲真的补回 mpv 自己的水位才算结束；**但那一段
  /// 还没结束时每 [PlayerTuning.starveRepeat] 补报一次**（理由是坏镜像让"结束"永不发生，
  /// 见 [PlayerTuning.starveRepeat]）。
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
      if (++_starveSeconds < PlayerTuning.starveSeconds) return;
      if (!_starveReportDue(now)) return;
      final repeat = _starveLastReportAt != null;
      _starveLastReportAt = now;
      debugPrint(
        repeat
            ? 'CDN 缓冲饥饿: 仍在饥饿，再次上报（余量 ${bufferedAhead}s < '
                  '${threshold.toStringAsFixed(1)}s）@${position.value}s'
            : 'CDN 缓冲饥饿: 前方余量 ${bufferedAhead}s < '
                  '${threshold.toStringAsFixed(1)}s (连续 ${PlayerTuning.starveSeconds} s) '
                  '@${position.value}s',
      );
      onBufferStarve?.call(
        videoPlayerController?.state.position ?? Duration.zero,
      );
      return;
    }
    _starveSeconds = 0;
    // 余量涨到失真：音频在走、画面冻着。`demuxer-cache-time` 被音频轨抬离了
    // 播放位置，余量因此超过缓存上限好几倍 —— 位置还在推进、[isBuffering]
    // 也是假，判据 1、2 都看不见，只有这里能拦住。同样每段只报一次（可按
    // [PlayerTuning.starveRepeat] 补报，跟上面那条共用一个去重状态）。
    //
    // 出口是 [onTelemetryDiverged]，**不是**上面那条低水位支走的 [onBufferStarve]：
    // 两副面孔的恢复手段不同，理由见那个字段。
    if (telemetryDiverged) {
      if (!_starveReportDue(now)) return;
      final repeat = _starveLastReportAt != null;
      _starveLastReportAt = now;
      debugPrint(
        repeat
            ? 'CDN 遥测失真: 仍在失真（余量 ${bufferedAhead}s）'
                  '@${position.value}s'
            : 'CDN 遥测失真: 余量 ${bufferedAhead}s 超过缓存上限 '
                  '${_divergedAheadSec.toStringAsFixed(1)}s 的 '
                  '${PlayerTuning.divergedFactor}x (音频在走，画面已冻) @${position.value}s',
      );
      onTelemetryDiverged?.call(
        videoPlayerController?.state.position ?? Duration.zero,
      );
      return;
    }
    // 只有补回 mpv 自己的水位才算这段饥饿真的结束了。
    if (bufferedAhead >= threshold / PlayerTuning.starveFloorFraction) {
      if (_starveLastReportAt != null) {
        debugPrint('CDN 缓冲饥饿: 已恢复 (${bufferedAhead}s)');
      }
      _starveLastReportAt = null;
    }
  }

  /// 该不该就"还在挨饿"这件事再出声一次：没报过，或者距上次已过 [PlayerTuning.starveRepeat]。
  bool _starveReportDue(DateTime now) {
    final last = _starveLastReportAt;
    return last == null || now.difference(last) >= PlayerTuning.starveRepeat;
  }

  /// 测试缝：判据 3 的一拍。
  ///
  /// [_sampleStarve] 本身不需要播放器（只看 `now` 和 [buffered] / [position] /
  /// [duration] 这几个公开字段），但驱动它的 1s ticker 在测试里跑不起来
  /// （[_startStallTicker] 要真播放器，见 `_startListeners`）。所以把这一拍直接
  /// 暴露出来，让"持续饥饿必须补报"这条有测试盯着 —— 它是这一片的盲区里少数
  /// 能被钉住的东西。生产代码不走这里。
  @visibleForTesting
  void debugSampleStarve(DateTime now) => _sampleStarve(now);

  @visibleForTesting
  void debugSampleDecodeError(String text, DateTime at) =>
      _sampleDecodeError(text, at: at);

  /// 把"回前台续播窗口"的起点摆到指定时刻。
  ///
  /// 生产路径里它由 [reinitDecoderAfterBackground] 置上，而那条路径要在测试里
  /// 真的走一遍 hwdec 命令；窗口判据本身只跟时刻有关，所以直接把起点摆出来。
  @visibleForTesting
  void debugNoteForegroundResume(DateTime at) => _foregroundResumedAt = at;

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
        onRebuffer?.call(
          videoPlayerController?.state.position ?? Duration.zero,
        );
      }
    } else {
      _wasEmpty = false;
    }

    final stalled = isBuffering.value && bufferedAhead == 0;
    if (stalled && !_wasStalled) {
      _rebufferEvents.add(now);
      _rebufferEvents.removeWhere(
        (t) => now.difference(t) > PlayerTuning.rebufferWindow,
      );
      debugPrint(
        'CDN 卡顿计数: ${_rebufferEvents.length}/${PlayerTuning.rebufferTrigger} '
        '(窗口 ${PlayerTuning.rebufferWindow.inSeconds}s)',
      );
      if (_rebufferEvents.length >= PlayerTuning.rebufferTrigger) {
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
    // 重建窗口内旧的 player 已经拆了、新的还没接上，这时候的 seek 只会打空或者
    // 打到正在拆的对象上。页面的重载路径自己会把位置带回来（seekTo: playedTime）。
    if (_rebuildingRenderContext) {
      return;
    }
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

    // 先拿到音频会话再出声：锁屏/灵动岛要等会话激活后才认领「正在播放」。
    // 激活失败（被其他音频占用等）不应阻塞播放。
    try {
      await audioSessionHandler?.setActive(true);
    } catch (_) {}

    await _videoPlayerController?.play();

    playerStatus = .playing;
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    await _videoPlayerController?.pause();
    playerStatus = .paused;

    // 主动暂停时让出音频焦点。
    // iOS 例外：deactivate 会把系统「正在播放」卡片和遥控一起收走，
    // 锁屏上第一次点暂停就再也回不来了；会话留给最终 dispose 收尾。
    if (!isInterrupt && !Platform.isIOS) {
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

  /// 认领"渲染上下文没了就重载一次"。见 [_renderReloadClaimants]。
  ///
  /// [owner] 是这个页面的身份 token，**必填**：身份与回调必须同时登记 —— 缺一个就会让
  /// [_renderRebuildBlocker] 的等式失真（要么把页面判成"没登记"，要么让名册里躺着一个
  /// 永远不会被触发的认领）。
  void addRenderReloadListener(Object owner, Future<void> Function() listener) {
    if (_playerCount == 0) return;
    _renderReloadClaimants[owner] = listener;
    _dormantRenderClaimants.remove(owner);
  }

  /// 卸认领 = 页面**进入休眠**（被别的页盖住），不等于页面结束 —— 后者走
  /// [forgetRenderReloadOwner]。只有真的挂着认领时才记一笔休眠：重复调用不会造出
  /// "没认领过却休眠着"的幽灵名额。
  void removeRenderReloadListener(Object owner) {
    if (_renderReloadClaimants.remove(owner) != null) {
      _dormantRenderClaimants.add(owner);
    }
  }

  /// 页面这一世结束（`State.dispose`）：把身份从两处**都**抹掉。
  ///
  /// 漏掉这一句，死页面的 token 会永久占着 [_dormantRenderClaimants] 的名额 —— 一边计数
  /// 已减、一边名册还留着，[_renderRebuildBlocker] 的等式就可能被"抵消"成**假放行**
  /// （残留一条 + 正好一个直播间）。正常路径下它是页面 `dispose()` 的第二句，但这是本次
  /// 改动里唯一一处靠纪律守住的点，用例专门钉了它。
  void forgetRenderReloadOwner(Object owner) {
    _renderReloadClaimants.remove(owner);
    _dormantRenderClaimants.remove(owner);
  }

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
    _bgVideoSuspendTimer?.cancel();
    _bgVideoSuspendTimer = null;
    _videoSuspendedForBackground = false;
    _bgVideoSuspendDue = false;
    _backgroundEnteredAt = null;
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
    _cancelErrorReload();
    volumeTimer?.cancel();
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
    _renderReloadClaimants.clear();
    // 计数归零后 `_instance` 也会置 null（本函数后面几行），两套名册其实跟着一起被丢弃；
    // 这里清是为了让"归零 ⇔ 记录全空"这条读起来成立。
    _dormantRenderClaimants.clear();
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
    audioSessionHandler?.stopNowPlayingGuard();

    // iOS：会话一直留到播放器真正销毁，锁屏卡片才能在暂停后继续存在。
    // 音频页（听视频）用的是另一个 player，onPlay 非空时不能掐它的会话。
    if (Platform.isIOS && videoPlayerServiceHandler?.onPlay == null) {
      audioSessionHandler?.setActive(false).catchError((_) => false);
    }
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
    // iOS 上系统播放卡片跟着这个开关走。
    if (Platform.isIOS) {
      videoPlayerServiceHandler?.setEnableBackgroundPlay(
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
