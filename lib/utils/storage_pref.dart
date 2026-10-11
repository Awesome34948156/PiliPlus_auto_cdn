import 'dart:io';

import 'package:PiliPlus/common/widgets/gesture/horizontal_drag_gesture_recognizer.dart'
    show deviceTouchSlop;
import 'package:PiliPlus/common/widgets/pair.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/bar_hide_type.dart';
import 'package:PiliPlus/models/common/dynamic/dynamic_badge_mode.dart';
import 'package:PiliPlus/models/common/dynamic/dynamics_type.dart';
import 'package:PiliPlus/models/common/dynamic/up_panel_position.dart';
import 'package:PiliPlus/models/common/follow_order_type.dart';
import 'package:PiliPlus/models/common/member/tab_type.dart';
import 'package:PiliPlus/models/common/msg/msg_unread_type.dart';
import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/models/common/reply/reply_sort_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/skip_type.dart';
import 'package:PiliPlus/models/common/super_chat_type.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/theme/theme_type.dart';
import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/live_quality.dart';
import 'package:PiliPlus/models/common/video/subtitle_pref_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/pages/setting/pages/fullscreen_sc_size.dart'
    show kFullScreenSCWidth;
import 'package:PiliPlus/plugin/pl_player/models/audio_output_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/bottom_progress_behavior.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/hwdec_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flex_seed_scheme/flex_seed_scheme.dart' show FlexSchemeVariant;
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

abstract final class Pref {
  static final Box _setting = GStorage.setting;
  static final Box _video = GStorage.video;
  static final Box _localCache = GStorage.localCache;

  static UserInfoData? get userInfoCache =>
      GStorage.userInfo.get('userInfoCache');

  static List<double> get dynamicDetailRatio => List<double>.from(
    _setting.get(
      SettingBoxKey.dynamicDetailRatio,
      defaultValue: const [60.0, 40.0],
    ),
  );

  static Set<int> get blackMids =>
      _localCache.get(LocalCacheKey.blackMids, defaultValue: <int>{});

  static set blackMids(Set<int> blackMidsSet) =>
      _localCache.put(LocalCacheKey.blackMids, blackMidsSet);

  /// 自动切换 CDN 时测速窗口的轮换起点。存在 localCache 而不是 setting：这是
  /// 内部状态，不是用户设置。
  static int get cdnMirrorRotation =>
      _localCache.get(LocalCacheKey.cdnMirrorRotation, defaultValue: 0);

  static set cdnMirrorRotation(int value) =>
      _localCache.put(LocalCacheKey.cdnMirrorRotation, value);

  /// 各镜像历史测到的最高速度，用来把"记得最快的那个"每轮固定送进候选窗口。
  /// 同样存 localCache：内部状态，不是用户设置。
  ///
  /// 扁平 `List<int>`，长度 `CDNService.values.length * 3`，按 `service.index` 寻址：
  ///
  ///     [index * 3]      速度，单位 B/s，0 表示没测过
  ///     [index * 3 + 1]  记录时刻，epoch 秒
  ///     [index * 3 + 2]  1 = 这个镜像曾经当过候选并测出过样本（冠军资格）
  ///
  /// 速度为 0 天然可以当"未记录"：真实样本的 bytes 一定大于 0。第三个格子是
  /// "这个镜像当过候选并测出过样本"的标志，只置 1、从不回 0。基线样本和候选样本
  /// 不是同一个测量（基线用原始签名 URL，候选用改写 host 之后的 URL），有的镜像
  /// 当基线很能跑、当候选却每次 403，所以只有当过候选的镜像才允许被送进候选窗口。
  ///
  /// 从 V3 起只有候选写记录，所以**凡是被写过的格子这个标志都是 1**，它暂时不再
  /// 区分任何东西。留着是为了把这个不变量写成显式的，而不是靠"没有别的调用点"来
  /// 维持：将来若再引入基线之类的样本来源，它会挡住"当前镜像自我加冕"那个坑
  /// （见上面 V2 → V3 那段），而不是安静地漏掉。
  ///
  /// key 改到 V3 两次，都不是因为布局变了，而是因为**存进去的值不可信，清掉比留
  /// 着划算**：
  ///
  /// - `cdnSpeedRecord` → `V2`：2 槽布局的旧记录按 3 槽读出来是垃圾（下标整体
  ///   错位），改名比写迁移代码划算。
  /// - `V2` → `V3`：V2 允许**基线样本也写记录**，而基线 URL 就是正在播的那条，
  ///   边缘节点上那个区段是热的，读数会突发（实测 2MiB/0.12s，19.2MB/s），候选
  ///   测的却是冷字节。混在同一个格子取最大值的结果是"当前镜像自我加冕"——
  ///   记录里最快的永远是它自己。现在只有候选写，旧的虚高值必须在改之前清掉：
  ///   它只有在 30 分钟没更新时才会被覆盖，而评选只看 6 小时过期，留着会一直
  ///   占着冠军位子（切走之后还会把刚抛弃的镜像重新顶上去）。
  ///
  /// 整个记录在换集/换画质时**不清空** —— 镜像快慢是网络属性，跟放的是哪个
  /// 视频无关。但**快档（小卡顿）样本不写**，只由整轮写：快档撞字节上限的短样本
  /// 会突发偏高，而这里取的是最大值。见 `_recordCdnSample` 的调用点。
  static List<int> get cdnSpeedRecord => List<int>.from(
    _localCache.get(
      LocalCacheKey.cdnSpeedRecord,
      defaultValue: const <int>[],
    ),
  );

  static set cdnSpeedRecord(List<int> value) =>
      _localCache.put(LocalCacheKey.cdnSpeedRecord, value);

  static RuleFilter get danmakuFilterRule => _localCache.get(
    LocalCacheKey.danmakuFilterRules,
    defaultValue: RuleFilter.empty(),
  );

  static void setBlackMid(int mid) => _localCache.put(
    LocalCacheKey.blackMids,
    GlobalData().blackMids..add(mid),
  );

  static void removeBlackMid(int mid) => _localCache.put(
    LocalCacheKey.blackMids,
    GlobalData().blackMids..remove(mid),
  );

  static MemberTabType get memberTab =>
      MemberTabType.values[_setting.get(
        SettingBoxKey.memberTab,
        defaultValue: 0,
      )];

  static int get _themeTypeInt => _setting.get(
    SettingBoxKey.themeMode,
    defaultValue: ThemeType.system.index,
  );

  static ThemeType get themeType => ThemeType.values[_themeTypeInt];

  static ThemeMode get themeMode => switch (_themeTypeInt) {
    0 => ThemeMode.light,
    1 => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static List<double> get springDescription => List<double>.from(
    _setting.get(SettingBoxKey.springDescription) ??
        // duration: 0.3, bounce: 0.0
        const [1.0, 438.64908449286037, 41.88790204786391],
  );
  //   [0.5, 100.0, 2.2 * math.sqrt(50)], // [mass, stiffness, damping]

  static List<double> get speedList => List<double>.from(
    _video.get(
      VideoBoxKey.speedsList,
      defaultValue: const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0],
    ),
  );

  static List<Pair<SegmentType, SkipType>> get blockSettings {
    final list = _setting.get(SettingBoxKey.blockSettings) as List?;
    if (list == null || list.length != SegmentType.values.length) {
      return SegmentType.values
          .map((i) => Pair(first: i, second: SkipType.skipOnce))
          .toList();
    }
    return SegmentType.values
        .map(
          (item) => Pair(
            first: item,
            second: SkipType.values[list[item.index]],
          ),
        )
        .toList();
  }

  static List<Color> get blockColor {
    final list = _setting.get(SettingBoxKey.blockColor) as List?;
    if (list == null || list.length != SegmentType.values.length) {
      return SegmentType.values.map((i) => i.color).toList();
    }
    return SegmentType.values.map(
      (item) {
        final String e = list[item.index];
        final color = e.isNotEmpty ? int.tryParse('FF$e', radix: 16) : null;
        return color != null ? Color(color) : item.color;
      },
    ).toList();
  }

  static bool get feedBackEnable =>
      _setting.get(SettingBoxKey.feedBackEnable, defaultValue: false);

  static int get picQuality =>
      _setting.get(SettingBoxKey.defaultPicQa, defaultValue: 10);

  static DynamicBadgeMode get dynamicBadgeType =>
      DynamicBadgeMode.values[_setting.get(
        SettingBoxKey.dynamicBadgeMode,
        defaultValue: DynamicBadgeMode.number.index,
      )];

  static DynamicBadgeMode get msgBadgeMode =>
      DynamicBadgeMode.values[_setting.get(
        SettingBoxKey.msgBadgeMode,
        defaultValue: DynamicBadgeMode.number.index,
      )];

  static Set<MsgUnReadType> get msgUnReadTypeV2 =>
      (_setting.get(SettingBoxKey.msgUnReadTypeV2) as List?)
          ?.map((index) => MsgUnReadType.values[index])
          .toSet() ??
      MsgUnReadType.values.toSet();

  static NavigationBarType get defaultHomePage =>
      NavigationBarType.values[defaultHomePageIndex];

  static int get defaultHomePageIndex => _setting.get(
    SettingBoxKey.defaultHomePage,
    defaultValue: NavigationBarType.home.index,
  );

  static int get previewQ =>
      _setting.get(SettingBoxKey.previewQuality, defaultValue: 100);

  static double get smallCardWidth =>
      _setting.get(SettingBoxKey.smallCardWidth, defaultValue: 240.0);

  static double get recommendCardWidth =>
      _setting.get(SettingBoxKey.recommendCardWidth, defaultValue: 240.0);

  static UpPanelPosition get upPanelPosition =>
      UpPanelPosition.values[_setting.get(
        SettingBoxKey.upPanelPosition,
        defaultValue: UpPanelPosition.leftFixed.index,
      )];

  static FullScreenMode get fullScreenMode {
    int? index = _setting.get(SettingBoxKey.fullScreenMode);
    if (index == null) {
      final FullScreenMode mode = horizontalScreen && DeviceUtils.isTablet
          ? .none
          : .auto;
      _setting.put(SettingBoxKey.fullScreenMode, mode.index);
      return mode;
    }
    return FullScreenMode.values[index];
  }

  static BtmProgressBehavior get btmProgressBehavior =>
      BtmProgressBehavior.values[_setting.get(
        SettingBoxKey.btmProgressBehavior,
        defaultValue: BtmProgressBehavior.alwaysShow.index,
      )];

  static SubtitlePrefType get subtitlePreferenceV2 =>
      SubtitlePrefType.values[_setting.get(
        SettingBoxKey.subtitlePreferenceV2,
        defaultValue: SubtitlePrefType.off.index,
      )];

  static bool get useRelativeSlide =>
      _setting.get(SettingBoxKey.useRelativeSlide, defaultValue: false);

  static int get sliderDuration =>
      _setting.get(SettingBoxKey.sliderDuration, defaultValue: 90);

  static int get defaultVideoQa => _setting.get(
    SettingBoxKey.defaultVideoQa,
    defaultValue: VideoQuality.super8k.code,
  );

  static int get defaultVideoQaCellular => _setting.get(
    SettingBoxKey.defaultVideoQaCellular,
    defaultValue: VideoQuality.high1080.code,
  );

  static int get defaultAudioQa => _setting.get(
    SettingBoxKey.defaultAudioQa,
    defaultValue: AudioQuality.hiRes.code,
  );

  static int get defaultAudioQaCellular => _setting.get(
    SettingBoxKey.defaultAudioQaCellular,
    defaultValue: AudioQuality.k192.code,
  );

  static List<VideoDecodeFormatType> get preferCodecs {
    final codecs = _setting.get(SettingBoxKey.preferCodecs);
    if (codecs is List) {
      return codecs.map((i) => VideoDecodeFormatType.values.byName(i)).toList();
    }
    return const <VideoDecodeFormatType>[.AVC, .AV1];
  }

  static List<VideoDecodeFormatType> get preferCodecsCellular {
    final codecs = _setting.get(SettingBoxKey.preferCodecsCellular);
    if (codecs is List) {
      return codecs.map((i) => VideoDecodeFormatType.values.byName(i)).toList();
    }
    return preferCodecs;
  }

  static String get hardwareDecoding => _setting.get(
    SettingBoxKey.hardwareDecoding,
    defaultValue: HwDecType.kHwdec,
  );

  static String get videoSync =>
      _setting.get(SettingBoxKey.videoSync, defaultValue: 'display-resample');

  static String get autosync => _setting.get(
    SettingBoxKey.autosync,
    defaultValue: Platform.isAndroid ? '30' : '0',
  );

  static CDNService get defaultCDNService {
    if (_setting.get(SettingBoxKey.CDNService) case final String cdnName) {
      // 镜像列表会增删，历史存档里的名字可能已经不存在了。不能直接用
      // values.byName —— 未知名字会抛异常，而这里是每次打开视频都会走的路径。
      for (final service in CDNService.values) {
        if (service.name == cdnName) return service;
      }
    }
    return CDNService.backupUrl;
  }

  static String get banWordForRecommend =>
      _setting.get(SettingBoxKey.banWordForRecommend, defaultValue: '');

  static String get banWordForReply =>
      _setting.get(SettingBoxKey.banWordForReply, defaultValue: '');

  static String get banWordForZone =>
      _setting.get(SettingBoxKey.banWordForZone, defaultValue: '');

  static bool get appRcmd =>
      _setting.get(SettingBoxKey.appRcmd, defaultValue: true);

  static String get systemProxyHost =>
      _setting.get(SettingBoxKey.systemProxyHost, defaultValue: '');

  static String get systemProxyPort =>
      _setting.get(SettingBoxKey.systemProxyPort, defaultValue: '');

  static DynamicsTabType get defaultDynamicType =>
      DynamicsTabType.values[defaultDynamicTypeIndex];

  static int get defaultDynamicTypeIndex => _setting.get(
    SettingBoxKey.defaultDynamicType,
    defaultValue: DynamicsTabType.all.index,
  );

  static bool get showDynInteraction =>
      _setting.get(SettingBoxKey.showDynInteraction, defaultValue: true);

  static double get blockLimit =>
      _setting.get(SettingBoxKey.blockLimit, defaultValue: 0.0);

  static double get refreshDisplacement => _setting.get(
    SettingBoxKey.refreshDisplacement,
    defaultValue: PlatformUtils.isMobile ? 20.0 : 40.0,
  );

  static String get blockUserID {
    String? blockUserID = _setting.get(SettingBoxKey.blockUserID);
    if (blockUserID == null || blockUserID.isEmpty) {
      blockUserID = Digest(
        List.generate(16, (_) => Utils.random.nextInt(256)),
      ).toString();
      _setting.put(SettingBoxKey.blockUserID, blockUserID);
    }
    return blockUserID;
  }

  static bool get blockToast =>
      _setting.get(SettingBoxKey.blockToast, defaultValue: true);

  static String get blockServer => _setting.get(
    SettingBoxKey.blockServer,
    defaultValue: HttpString.sponsorBlockBaseUrl,
  );

  static bool get blockTrack =>
      _setting.get(SettingBoxKey.blockTrack, defaultValue: !kDebugMode);

  static bool get checkDynamic =>
      _setting.get(SettingBoxKey.checkDynamic, defaultValue: true);

  static int get dynamicPeriod =>
      _setting.get(SettingBoxKey.dynamicPeriod, defaultValue: 5);

  static FlexSchemeVariant get schemeVariant =>
      FlexSchemeVariant.values[_setting.get(
        SettingBoxKey.schemeVariant,
        defaultValue: FlexSchemeVariant.material3Legacy.index,
      )];

  static double get danmakuFontScaleFS => _setting.get(
    SettingBoxKey.danmakuFontScaleFS,
    defaultValue: PlatformUtils.isMobile ? 1.2 : 1.7,
  );

  static bool get danmakuMassiveMode =>
      _setting.get(SettingBoxKey.danmakuMassiveMode, defaultValue: false);

  static bool get danmakuFixedV =>
      _setting.get(SettingBoxKey.danmakuFixedV, defaultValue: false);

  static bool get danmakuStatic2Scroll =>
      _setting.get(SettingBoxKey.danmakuStatic2Scroll, defaultValue: false);

  static double get subtitleFontScale =>
      _setting.get(SettingBoxKey.subtitleFontScale, defaultValue: 1.0);

  static double get subtitleFontScaleFS =>
      _setting.get(SettingBoxKey.subtitleFontScaleFS, defaultValue: 1.5);

  static bool get showViewPoints =>
      _setting.get(SettingBoxKey.showViewPoints, defaultValue: true);

  static bool get showRelatedVideo =>
      _setting.get(SettingBoxKey.showRelatedVideo, defaultValue: true);

  static bool get showVideoReply =>
      _setting.get(SettingBoxKey.showVideoReply, defaultValue: true);

  static bool get showBangumiReply =>
      _setting.get(SettingBoxKey.showBangumiReply, defaultValue: true);

  static bool get alwaysExpandIntroPanel =>
      _setting.get(SettingBoxKey.alwaysExpandIntroPanel, defaultValue: false);

  static bool get expandIntroPanelH =>
      _setting.get(SettingBoxKey.expandIntroPanelH, defaultValue: false);

  static bool get horizontalSeasonPanel => _setting.get(
    SettingBoxKey.horizontalSeasonPanel,
    defaultValue: horizontalScreen,
  );

  static bool get horizontalMemberPage => _setting.get(
    SettingBoxKey.horizontalMemberPage,
    defaultValue: horizontalScreen,
  );

  static int? get replyLengthLimit {
    int length = _setting.get(SettingBoxKey.replyLengthLimit, defaultValue: 6);
    if (length <= 0) {
      return null;
    }
    return length;
  }

  static int get defaultPicQa =>
      _setting.get(SettingBoxKey.defaultPicQa, defaultValue: 10);

  static double get danmakuLineHeight =>
      _setting.get(SettingBoxKey.danmakuLineHeight, defaultValue: 1.6);

  static bool get showArgueMsg =>
      _setting.get(SettingBoxKey.showArgueMsg, defaultValue: true);

  static bool get reverseFromFirst =>
      _setting.get(SettingBoxKey.reverseFromFirst, defaultValue: true);

  static int get subtitlePaddingH =>
      _setting.get(SettingBoxKey.subtitlePaddingH, defaultValue: 24);

  static int get subtitlePaddingB =>
      _setting.get(SettingBoxKey.subtitlePaddingB, defaultValue: 24);

  static double get subtitleBgOpacity =>
      _setting.get(SettingBoxKey.subtitleBgOpacity, defaultValue: 0.67);

  static double get subtitleStrokeWidth =>
      _setting.get(SettingBoxKey.subtitleStrokeWidth, defaultValue: 2.0);

  static int get subtitleFontWeight =>
      _setting.get(SettingBoxKey.subtitleFontWeight, defaultValue: 5);

  static bool get badCertificateCallback =>
      _setting.get(SettingBoxKey.badCertificateCallback, defaultValue: false);

  static bool get continuePlayingPart =>
      _setting.get(SettingBoxKey.continuePlayingPart, defaultValue: true);

  static bool get cdnSpeedTest =>
      _setting.get(SettingBoxKey.cdnSpeedTest, defaultValue: true);

  static bool get autoSwitchCdnOnStall =>
      _setting.get(SettingBoxKey.autoSwitchCdnOnStall, defaultValue: true);

  /// 自动切换 CDN 时是否弹 toast。只关提示，不动 [debugPrint] 的日志：
  /// 用户不想被打扰，不等于不想事后能查。
  static bool get showCdnSwitchToast =>
      _setting.get(SettingBoxKey.showCdnSwitchToast, defaultValue: true);

  /// 是否让 mpv 把日志开到 verbose 档。
  ///
  /// 默认关：`v` 是 mpv 全局最吵的一档，一次故障能连吐几百行，每行都要落盘。
  /// 它只在**追查播放器内部故障**时才有价值（轨道表 / 解码器初始化 / 视频
  /// 输出 / hwdec 都只在这一档里），所以做成随用随开，而不是给所有人开着。
  /// 落盘本身（[consoleLogActive]）不受它影响，PiliPlus 自己的诊断照常记录。
  static bool get mpvVerboseLog =>
      _setting.get(SettingBoxKey.mpvVerboseLog, defaultValue: false);

  static bool get autoUpdate =>
      _setting.get(SettingBoxKey.autoUpdate, defaultValue: true);

  static bool get horizontalPreview =>
      _setting.get(SettingBoxKey.horizontalPreview, defaultValue: false);

  static bool get openInBrowser =>
      _setting.get(SettingBoxKey.openInBrowser, defaultValue: false);

  static bool get savedRcmdTip =>
      _setting.get(SettingBoxKey.savedRcmdTip, defaultValue: true);

  static bool get showVipDanmaku =>
      _setting.get(SettingBoxKey.showVipDanmaku, defaultValue: true);

  static bool get mergeDanmaku =>
      _setting.get(SettingBoxKey.mergeDanmaku, defaultValue: false);

  static bool get showHotRcmd =>
      _setting.get(SettingBoxKey.showHotRcmd, defaultValue: false);

  static String get audioNormalization =>
      _setting.get(SettingBoxKey.audioNormalization, defaultValue: '0');

  static String get fallbackNormalization =>
      _setting.get(SettingBoxKey.fallbackNormalization, defaultValue: '0');

  static SuperResolutionType get superResolutionType {
    SuperResolutionType? superResolutionType;
    final index = _setting.get(SettingBoxKey.superResolutionType);
    if (index != null) {
      superResolutionType = SuperResolutionType.values.elementAtOrNull(index);
    }
    return superResolutionType ?? SuperResolutionType.disable;
  }

  static bool get preInitPlayer =>
      _setting.get(SettingBoxKey.preInitPlayer, defaultValue: false);

  static bool get mainTabBarView =>
      _setting.get(SettingBoxKey.mainTabBarView, defaultValue: false);

  static bool get searchSuggestion =>
      _setting.get(SettingBoxKey.searchSuggestion, defaultValue: true);

  static bool get showDecorate =>
      _setting.get(SettingBoxKey.showDecorate, defaultValue: true);

  static bool get showMedal =>
      _setting.get(SettingBoxKey.showMedal, defaultValue: true);

  static bool get enableLivePhoto =>
      _setting.get(SettingBoxKey.enableLivePhoto, defaultValue: true);

  static bool get showSeekPreview =>
      _setting.get(SettingBoxKey.showSeekPreview, defaultValue: true);

  static bool get showDmChart =>
      _setting.get(SettingBoxKey.showDmChart, defaultValue: false);

  static bool get enableCommAntifraud =>
      _setting.get(SettingBoxKey.enableCommAntifraud, defaultValue: false);

  static bool get biliSendCommAntifraud =>
      Platform.isAndroid &&
      _setting.get(SettingBoxKey.biliSendCommAntifraud, defaultValue: false);

  static bool get enableCreateDynAntifraud =>
      _setting.get(SettingBoxKey.enableCreateDynAntifraud, defaultValue: false);

  static bool get coinWithLike =>
      _setting.get(SettingBoxKey.coinWithLike, defaultValue: false);

  static bool get isPureBlackTheme =>
      _setting.get(SettingBoxKey.isPureBlackTheme, defaultValue: false);

  static bool get antiGoodsDyn =>
      _setting.get(SettingBoxKey.antiGoodsDyn, defaultValue: false);

  static bool get antiGoodsReply =>
      _setting.get(SettingBoxKey.antiGoodsReply, defaultValue: false);

  static bool get expandDynLivePanel =>
      _setting.get(SettingBoxKey.expandDynLivePanel, defaultValue: false);

  static bool get slideDismissReplyPage => _setting.get(
    SettingBoxKey.slideDismissReplyPage,
    defaultValue: Platform.isIOS,
  );

  static bool get showFSActionItem =>
      _setting.get(SettingBoxKey.showFSActionItem, defaultValue: true);

  static bool get enableShrinkVideoSize =>
      _setting.get(SettingBoxKey.enableShrinkVideoSize, defaultValue: true);

  static bool get showDynActionBar =>
      _setting.get(SettingBoxKey.showDynActionBar, defaultValue: true);

  static bool get darkVideoPage =>
      _setting.get(SettingBoxKey.darkVideoPage, defaultValue: false);

  static bool get enableSlideVolumeBrightness => _setting.get(
    SettingBoxKey.enableSlideVolumeBrightness,
    defaultValue: true,
  );

  static bool get enableSlideFS =>
      _setting.get(SettingBoxKey.enableSlideFS, defaultValue: true);

  static int get retryCount =>
      _setting.get(SettingBoxKey.retryCount, defaultValue: 2);

  static int get retryDelay =>
      _setting.get(SettingBoxKey.retryDelay, defaultValue: 500);

  static int get liveQuality => _setting.get(
    SettingBoxKey.liveQuality,
    defaultValue: LiveQuality.origin.code,
  );

  static int get liveQualityCellular => _setting.get(
    SettingBoxKey.liveQualityCellular,
    defaultValue: LiveQuality.superHD.code,
  );

  static FontWeight get appFontWeight {
    // TODO: remove next 2 version
    const appFontWeightV1 = 'appFontWeight';
    final int? valV1 = _setting.get(appFontWeightV1);
    if (valV1 != null) {
      _setting.delete(appFontWeightV1);
      if (valV1 == -1) {
        return .normal;
      } else {
        _setting.put(SettingBoxKey.appFontWeightV2, valV1);
        return .values[valV1];
      }
    }

    final int? val = _setting.get(SettingBoxKey.appFontWeightV2);
    if (val == null) {
      return .normal;
    }
    return .values[val];
  }

  static bool get enableDragSubtitle =>
      _setting.get(SettingBoxKey.enableDragSubtitle, defaultValue: false);

  static int get fastForBackwardDuration =>
      _setting.get(SettingBoxKey.fastForBackwardDuration, defaultValue: 10);

  static bool get recordSearchHistory =>
      _setting.get(SettingBoxKey.recordSearchHistory, defaultValue: true);

  static String get webdavUri =>
      _setting.get(SettingBoxKey.webdavUri, defaultValue: '');

  static String get webdavUsername =>
      _setting.get(SettingBoxKey.webdavUsername, defaultValue: '');

  static String get webdavPassword =>
      _setting.get(SettingBoxKey.webdavPassword, defaultValue: '');

  static String get webdavDirectory =>
      _setting.get(SettingBoxKey.webdavDirectory, defaultValue: '/');

  static bool get showPgcTimeline =>
      _setting.get(SettingBoxKey.showPgcTimeline, defaultValue: true);

  static num get maxCacheSize =>
      _setting.get(SettingBoxKey.maxCacheSize) ?? 1 << 30;

  static bool get optTabletNav =>
      _setting.get(SettingBoxKey.optTabletNav, defaultValue: true);

  static bool get horizontalScreen {
    bool? horizontalScreen = _setting.get(SettingBoxKey.horizontalScreen);
    if (horizontalScreen == null) {
      final isTablet = DeviceUtils.isTablet;
      _setting.put(SettingBoxKey.horizontalScreen, isTablet);
      return isTablet;
    }
    return horizontalScreen;
  }

  static String get banWordForDyn =>
      _setting.get(SettingBoxKey.banWordForDyn, defaultValue: '');

  static bool get enableLog =>
      _setting.get(SettingBoxKey.enableLog, defaultValue: true);

  static bool get disableAudioCDN =>
      _setting.get(SettingBoxKey.disableAudioCDN, defaultValue: false);

  static int get minDurationForRcmd =>
      _setting.get(SettingBoxKey.minDurationForRcmd, defaultValue: 0);

  static int get minPlayForRcmd =>
      _setting.get(SettingBoxKey.minPlayForRcmd, defaultValue: 0);

  static int get minLikeRatioForRecommend =>
      _setting.get(SettingBoxKey.minLikeRatioForRecommend, defaultValue: 0);

  static bool get exemptFilterForFollowed =>
      _setting.get(SettingBoxKey.exemptFilterForFollowed, defaultValue: true);

  static bool get applyFilterToRelatedVideos => _setting.get(
    SettingBoxKey.applyFilterToRelatedVideos,
    defaultValue: true,
  );

  static bool get enableBackgroundPlay =>
      _setting.get(SettingBoxKey.enableBackgroundPlay, defaultValue: true);

  static bool get disableLikeMsg =>
      _setting.get(SettingBoxKey.disableLikeMsg, defaultValue: false);

  static bool get enableWordRe =>
      _setting.get(SettingBoxKey.enableWordRe, defaultValue: false);

  static bool get autoExitFullscreen =>
      _setting.get(SettingBoxKey.enableAutoExit, defaultValue: true);

  static bool get autoPlayEnable =>
      _setting.get(SettingBoxKey.autoPlayEnable, defaultValue: false);

  static bool get pipNoDanmaku =>
      _setting.get(SettingBoxKey.pipNoDanmaku, defaultValue: false);

  static bool get enableVerticalExpand =>
      _setting.get(SettingBoxKey.enableVerticalExpand, defaultValue: false);

  static double get defaultTextScale =>
      _setting.get(SettingBoxKey.defaultTextScale, defaultValue: 1.0);

  static double get uiScale =>
      _setting.get(SettingBoxKey.uiScale, defaultValue: 1.0);

  static bool get dynamicsWaterfallFlow => _setting.get(
    SettingBoxKey.dynamicsWaterfallFlow,
    defaultValue: horizontalScreen,
  );

  static bool get hideTopBar => _setting.get(
    SettingBoxKey.hideTopBar,
    defaultValue: PlatformUtils.isMobile,
  );

  static bool get hideBottomBar => _setting.get(
    SettingBoxKey.hideBottomBar,
    defaultValue: PlatformUtils.isMobile,
  );

  static BarHideType get barHideType =>
      BarHideType.values[_setting.get(
        SettingBoxKey.barHideType,
        defaultValue: BarHideType.sync.index,
      )];

  static bool get enableSearchWord =>
      _setting.get(SettingBoxKey.enableSearchWord, defaultValue: false);

  static bool get useSideBar =>
      _setting.get(SettingBoxKey.useSideBar, defaultValue: false);

  static bool get dynamicsShowAllFollowedUp => _setting.get(
    SettingBoxKey.dynamicsShowAllFollowedUp,
    defaultValue: false,
  );

  static bool get enableShowDanmaku =>
      _setting.get(SettingBoxKey.enableShowDanmaku, defaultValue: true);

  static bool get enableShowLiveDanmaku =>
      _setting.get(SettingBoxKey.enableShowLiveDanmaku, defaultValue: true);

  static bool get enableQuickFav =>
      _setting.get(SettingBoxKey.enableQuickFav, defaultValue: false);

  static bool get p1080 =>
      _setting.get(SettingBoxKey.p1080, defaultValue: true);

  static int get customColor =>
      _setting.get(SettingBoxKey.customColor, defaultValue: 0);

  static bool get dynamicColor =>
      !Platform.isIOS &&
      _setting.get(SettingBoxKey.dynamicColor, defaultValue: true);

  static bool get enableSystemProxy =>
      _setting.get(SettingBoxKey.enableSystemProxy, defaultValue: false);

  static bool get enableHttp2 =>
      _setting.get(SettingBoxKey.enableHttp2, defaultValue: false);

  static ReplySortType get replySortType =>
      ReplySortType.values[_setting.get(
        SettingBoxKey.replySortType,
        defaultValue: ReplySortType.hot.index,
      )];

  static ReplySortType get reply2SortType =>
      ReplySortType.values[_setting.get(
        SettingBoxKey.reply2SortType,
        defaultValue: ReplySortType.time.index,
      )];

  static DynamicBadgeMode get dynamicBadgeMode =>
      DynamicBadgeMode.values[_setting.get(
        SettingBoxKey.dynamicBadgeMode,
        defaultValue: DynamicBadgeMode.number.index,
      )];

  static bool get enableMYBar =>
      _setting.get(SettingBoxKey.enableMYBar, defaultValue: true);

  static Transition get pageTransition =>
      Transition.values[_setting.get(
        SettingBoxKey.pageTransition,
        defaultValue: Transition.native.index,
      )];

  static bool get enableQuickDouble =>
      _setting.get(SettingBoxKey.enableQuickDouble, defaultValue: true);

  static bool get fullScreenGestureReverse =>
      _setting.get(SettingBoxKey.fullScreenGestureReverse, defaultValue: false);

  static bool get autoPiP =>
      _setting.get(SettingBoxKey.autoPiP, defaultValue: false);

  static bool get enableSponsorBlock =>
      _setting.get(SettingBoxKey.enableSponsorBlock, defaultValue: false);

  static bool get enableHA =>
      _setting.get(SettingBoxKey.enableHA, defaultValue: true);

  static Set<int> get danmakuBlockType => Set<int>.from(
    _setting.get(SettingBoxKey.danmakuBlockType, defaultValue: const <int>{}),
  );

  static int get danmakuWeight =>
      _setting.get(SettingBoxKey.danmakuWeight, defaultValue: 0);

  static double get danmakuShowArea =>
      _setting.get(SettingBoxKey.danmakuShowArea, defaultValue: 0.5);

  static double get danmakuOpacity =>
      _setting.get(SettingBoxKey.danmakuOpacity, defaultValue: 1.0);

  static double get danmakuFontScale => _setting.get(
    SettingBoxKey.danmakuFontScale,
    defaultValue: PlatformUtils.isMobile ? 1.0 : 1.4,
  );

  static double get danmakuDuration =>
      _setting.get(SettingBoxKey.danmakuDuration, defaultValue: 7.0);

  static double get danmakuStaticDuration =>
      _setting.get(SettingBoxKey.danmakuStaticDuration, defaultValue: 4.0);

  static double get danmakuStrokeWidth => _setting.get(
    SettingBoxKey.danmakuStrokeWidth,
    defaultValue: PlatformUtils.isMobile ? 1.5 : 2.5,
  );

  static int get danmakuFontWeight => _setting.get(
    SettingBoxKey.danmakuFontWeight,
    defaultValue: PlatformUtils.isMobile ? 5 : 6,
  );

  static bool get enableLongShowControl =>
      _setting.get(SettingBoxKey.enableLongShowControl, defaultValue: false);

  static double get bufferSize =>
      _setting.get(SettingBoxKey.bufferSize, defaultValue: 4.0);

  static double get bufferSec =>
      _setting.get(SettingBoxKey.bufferSec, defaultValue: 16.0);

  static Map<String, String> initBuffer([double playbackSpeed = 1.0]) {
    final bufSec = Pref.bufferSec * playbackSpeed;
    final bufSiz = (Pref.bufferSize * 0x100000).toStringAsFixed(0);
    return {
      'cache': 'yes',
      'cache-secs': bufSec.toStringAsFixed(3),
      'demuxer-hysteresis-secs': (bufSec / 1.5).toStringAsFixed(3),
      'demuxer-max-bytes': bufSiz,
      'demuxer-max-back-bytes': bufSiz,
    };
  }

  static Map<String, String> initLiveBuffer() {
    return {
      'cache': 'yes',
      'demuxer-max-bytes': (Pref.bufferSize * 0x200000).toStringAsFixed(0),
      'demuxer-max-back-bytes': '0',
    };
  }

  static String get audioOutput => _setting.get(
    SettingBoxKey.audioOutput,
    defaultValue: AudioOutput.defaultValue,
  );

  static bool get enableAi =>
      _setting.get(SettingBoxKey.enableAi, defaultValue: false);

  static bool get enableOnlineTotal =>
      _setting.get(SettingBoxKey.enableOnlineTotal, defaultValue: false);

  static bool get autoEnterFullScreen =>
      _setting.get(SettingBoxKey.enableAutoEnter, defaultValue: false);

  static bool get enableAutoLongPressSpeed =>
      _setting.get(SettingBoxKey.enableAutoLongPressSpeed, defaultValue: false);

  static double get playSpeedDefault =>
      _video.get(VideoBoxKey.playSpeedDefault, defaultValue: 1.0);

  static double get longPressSpeedDefault =>
      _video.get(VideoBoxKey.longPressSpeedDefault, defaultValue: 3.0);

  static bool get defaultShowComment =>
      _setting.get(SettingBoxKey.defaultShowComment, defaultValue: false);

  static bool get enableTrending =>
      _setting.get(SettingBoxKey.enableHotKey, defaultValue: true);

  static bool get enableSearchRcmd =>
      _setting.get(SettingBoxKey.enableSearchRcmd, defaultValue: true);

  static bool get enableSaveLastData =>
      _setting.get(SettingBoxKey.enableSaveLastData, defaultValue: true);

  static double get defaultToastOp =>
      _setting.get(SettingBoxKey.defaultToastOp, defaultValue: 1.0);

  static PlayRepeat get playRepeat =>
      PlayRepeat.values[_video.get(
        VideoBoxKey.playRepeat,
        defaultValue: PlayRepeat.pause.index,
      )];

  static int get cacheVideoFit =>
      _video.get(VideoBoxKey.cacheVideoFit, defaultValue: 1);

  static bool get continuePlayInBackground =>
      _setting.get(SettingBoxKey.continuePlayInBackground, defaultValue: false);

  static bool get directExitOnBack =>
      _setting.get(SettingBoxKey.directExitOnBack, defaultValue: false);

  static bool get historyPause =>
      _localCache.get(LocalCacheKey.historyPause, defaultValue: false);

  static int? get quickFavId => _setting.get(SettingBoxKey.quickFavId);

  static bool get tempPlayerConf =>
      _setting.get(SettingBoxKey.tempPlayerConf, defaultValue: false);

  static Color? get reduceLuxColor {
    final int? color = _setting.get(SettingBoxKey.reduceLuxColor);
    if (color != null && color != 0xFFFFFFFF) {
      return Color(color);
    }
    return null;
  }

  static bool get showFsScreenshotBtn =>
      _setting.get(SettingBoxKey.showFsScreenshotBtn, defaultValue: true);

  static bool get showFsLockBtn =>
      _setting.get(SettingBoxKey.showFsLockBtn, defaultValue: true);

  static bool get silentDownImg =>
      _setting.get(SettingBoxKey.silentDownImg, defaultValue: false);

  static String get buvid {
    String? buvid = _localCache.get(LocalCacheKey.buvid);
    if (buvid == null) {
      buvid = LoginUtils.generateBuvid();
      _localCache.put(LocalCacheKey.buvid, buvid);
    }
    return buvid;
  }

  static bool get showMemberShop =>
      _setting.get(SettingBoxKey.showMemberShop, defaultValue: false);

  static SuperChatType get superChatType =>
      SuperChatType.values[_setting.get(
        SettingBoxKey.superChatType,
        defaultValue: SuperChatType.valid.index,
      )];

  static double get fullScreenSCWidth => _setting.get(
    SettingBoxKey.fullScreenSCWidth,
    defaultValue: kFullScreenSCWidth,
  );

  static bool get minimizeOnExit =>
      _setting.get(SettingBoxKey.minimizeOnExit, defaultValue: true);

  static Size get windowSize {
    final List<double>? size = (_setting.get(SettingBoxKey.windowSize) as List?)
        ?.fromCast<double>();
    return size == null ? const Size(1180.0, 720.0) : Size(size[0], size[1]);
  }

  static List<double>? get windowPosition =>
      (_setting.get(SettingBoxKey.windowPosition) as List?)?.fromCast<double>();

  static bool get isWindowMaximized =>
      _setting.get(SettingBoxKey.isWindowMaximized, defaultValue: false);

  static bool get keyboardControl =>
      _setting.get(SettingBoxKey.keyboardControl, defaultValue: true);

  static bool get pauseOnMinimize =>
      _setting.get(SettingBoxKey.pauseOnMinimize, defaultValue: false);

  static bool get showWindowTitleBar =>
      _setting.get(SettingBoxKey.showWindowTitleBar, defaultValue: true);

  static double get desktopVolume =>
      _setting.get(SettingBoxKey.desktopVolume, defaultValue: 1.0);

  static SkipType get pgcSkipType =>
      SkipType.values[_setting.get(SettingBoxKey.pgcSkipType) ??
          SkipType.skipOnce.index];

  static PlayRepeat get audioPlayMode =>
      PlayRepeat.values[_setting.get(SettingBoxKey.audioPlayMode) ??
          PlayRepeat.listOrder.index];

  static bool get enablePlayAll =>
      _setting.get(SettingBoxKey.enablePlayAll, defaultValue: true);

  static bool get enableTapDm =>
      _setting.get(SettingBoxKey.enableTapDm, defaultValue: true);

  static bool get showTrayIcon =>
      _setting.get(SettingBoxKey.showTrayIcon, defaultValue: true);

  static bool get setSystemBrightness =>
      _setting.get(SettingBoxKey.setSystemBrightness, defaultValue: false);

  static String? get downloadPath => _setting.get(SettingBoxKey.downloadPath);

  static String? get imageSavePath => _setting.get(SettingBoxKey.imageSavePath);

  static String? get liveCdnUrl => _setting.get(SettingBoxKey.liveCdnUrl);

  static bool get showBatteryLevel => _setting.get(
    SettingBoxKey.showBatteryLevel,
    defaultValue: PlatformUtils.isMobile,
  );

  static FollowOrderType get followOrderType =>
      FollowOrderType.values[_setting.get(
        SettingBoxKey.followOrderType,
        defaultValue: FollowOrderType.def.index,
      )];

  static bool get enableImgMenu =>
      _setting.get(SettingBoxKey.enableImgMenu, defaultValue: false);

  static bool get showDynDispute =>
      _setting.get(SettingBoxKey.showDynDispute, defaultValue: false);

  static double get touchSlopH => _setting.get(
    SettingBoxKey.touchSlopH,
    defaultValue: deviceTouchSlop + 6.0,
  );

  static bool get saveReply =>
      _setting.get(SettingBoxKey.saveReply, defaultValue: true);

  static bool get floatingNavBar =>
      _setting.get(SettingBoxKey.floatingNavBar, defaultValue: false);

  static bool get removeSafeArea =>
      _setting.get(SettingBoxKey.removeSafeArea, defaultValue: false);

  static int get angleDegrees =>
      _setting.get(SettingBoxKey.angleDegrees, defaultValue: 30);

  static double get playerVolume => // mobile
      _setting.get(SettingBoxKey.playerVolume, defaultValue: 100.0);

  static double get maxVolume => // desktop
      _setting.get(SettingBoxKey.maxVolume, defaultValue: 2.0);

  static List? get liveStream => _setting.get(SettingBoxKey.liveStream);

  static bool get enableDocProvider =>
      _setting.get(SettingBoxKey.enableDocProvider, defaultValue: false);

  static bool get enableEmoteTooltip =>
      _setting.get(SettingBoxKey.enableEmoteTooltip, defaultValue: false);
}
