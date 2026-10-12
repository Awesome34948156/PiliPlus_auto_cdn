import 'dart:async';

import 'package:PiliPlus/services/console_log.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:path/path.dart' as p;

/// 把 `pili-console.log` 定时送进用户选的 iCloud Drive 文件夹。
/// 原生实现在 `ios/Runner/ICloudLogPlugin.swift`，这里只做编排。
///
/// 为什么需要：取日志原本只有 `xcrun devicectl device copy from` 一条路，
/// **要 USB 或者手机跟 Mac 在同一个 Wi-Fi 上** —— 人一出门这条就断了。
/// 现在 app 自己往 iCloud 写，Mac 上直接
/// `ls ~/Library/Mobile\ Documents/com~apple~CloudDocs/<文件夹>/`。
///
/// 「绑定了一个文件夹」就是开启，没有单独的开关位 —— 少一个状态就少一处不一致。
abstract final class ICloudLogSync {
  static const _channel = MethodChannel('com.example.piliplus/icloud_log');

  /// 同步间隔。调大能少搅动 iCloud 的版本历史（每次写都是一个版本），
  /// 调小能让 Mac 上更快看到。退到后台那一次不受它限制（见 `console_log.dart`
  /// 的 `_ConsoleLogLifecycleObserver`），所以 60 秒只是"前台放着的兜底"。
  static const Duration interval = Duration(seconds: 60);

  /// 快照落点。放**应用支持目录**，不放文档目录 —— 后者被
  /// `UIFileSharingEnabled` 暴露给「文件」App，在那儿多一个中间文件很难看。
  static const String _stagingName = 'pili-console.upload';

  /// 绑定失败后多久再试。冷启动那一刻 iCloud Drive 常常还没挂好，这时
  /// 解析书签是**瞬时**失败，几秒后自己就好了。
  static const Duration _rebindDelay = Duration(minutes: 5);

  /// 这个平台有没有这套原生实现（跟着 `pip_helper.dart` 的调子）。
  static bool isAvailable = false;

  /// 绑定中的文件夹路径；`null` 就是「未设置」。
  static String? folderPath;

  /// 上一次**成功**同步的时刻。给设置页显示 —— **以它为准，别以 Mac 上文件
  /// 出现的时刻为准**：上传是系统的 `bird` 在跑，低电量模式、关了蜂窝的
  /// iCloud Drive 都会拖后，Mac 上晚几分钟看到不代表没写进去。
  static DateTime? lastSyncedAt;

  /// 最近一次失败的原因，仅用于界面提示；成功即清空。
  static String? lastError;

  static bool get isConfigured => folderPath != null;

  static Timer? _timer;
  static Timer? _rebindTimer;

  /// 同一时刻只跑一次上传，多进来的请求合并成「完了再跑一次」。
  static bool _syncing = false;
  static bool _pending = false;

  /// 绑定成功后的第一次立刻做，不等满 [interval]。
  static bool _syncedOnce = false;

  /// 连续永久失败次数 —— 见 [_kPermanentFailuresBeforeUnbind]。
  static int _permanentFailures = 0;
  static const int _kPermanentFailuresBeforeUnbind = 3;

  /// 失败只在**状态跳变**时记一行。一分钟一行「同步失败」会自己喂自己，
  /// 还会把 8 MiB 的轮换搅乱 —— 日志是拿来看故障的，不是拿来刷屏的。
  static bool _failing = false;

  /// "这次没送，但不算失败"（没绑定 / 已有一次在飞）。**必须抛出去**，理由见
  /// [_upload]：钩子正常返回等于告诉 `console_log.dart` "已送达，可以记指纹了"。
  static const _deferred = _DeferredSync();

  /// 必须 `await`，且必须在 `GStorage.init()` **之后** —— 书签存在 Hive 里。
  static Future<void> init() async {
    try {
      isAvailable = await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('ICloudLogSync init: $e');
      return;
    }
    if (!isAvailable) return;
    final bookmark = _readBookmark();
    if (bookmark == null) return;
    await _bind(bookmark);
  }

  /// 弹文件夹选择器，选中的那个记下来。返回是否绑定成功（用户取消也是 false）。
  ///
  /// 失败时 [lastError] 里有原因 —— 调用方要把它显示出来。这段路**不**碰
  /// [_failing] 那套状态：它是用户手点的一次动作，不是定时同步失败，
  /// 说"会继续重试"是假的（不会重试，得用户自己再点一次）。
  static Future<bool> pickFolder() async {
    // 先清空：调用方拿"返回 false 且 lastError 非空"来区分**取消**和**失败**，
    // 留着上一次的旧错误会把一次正常取消说成失败。
    lastError = null;
    try {
      final res = await _channel.invokeMethod<Map>('pickFolder');
      if (res == null) return false; // 用户取消
      final bookmark = res['bookmark'];
      if (bookmark is! Uint8List) {
        lastError = '原生没给出书签';
        return false;
      }
      // 原生侧在选完那一刻已经建好书签、`startAccessing` 并持有了；这里仍然
      // 走一次 `resolve`（它内部先释放再解析），换来的是**只有一条绑定路径**。
      return await _bind(bookmark, persist: true);
    } catch (e) {
      lastError = '选择文件夹失败: $e';
      debugPrint('iCloud 日志同步: $lastError');
      return false;
    }
  }

  /// 解绑：原生侧放掉安全作用域，本地忘掉书签，日志不再往外送。
  static Future<void> unbind() async {
    _timer?.cancel();
    _timer = null;
    _rebindTimer?.cancel();
    _rebindTimer = null;
    folderPath = null;
    lastSyncedAt = null;
    lastError = null;
    _permanentFailures = 0;
    _failing = false;
    _syncedOnce = false;
    // 先卸载钩子：卸了之后 console_log 连快照都不做，一个字节都不白拷。
    setConsoleLogSyncHook(null);
    await GStorage.localCache.delete(LocalCacheKey.iCloudLogBookmark);
    try {
      await _channel.invokeMethod('clearAccess');
    } catch (_) {
      // 原生那边已经没了访问权也算达成目的
    }
  }

  /// 立刻同步一次（设置页那个按钮、以及退到后台那一次都走它）。
  static void syncNow() {
    if (!isConfigured) return;
    requestConsoleLogSync();
  }

  /// 解析书签 → 拿到访问权 → 装上钩子、起定时器。
  static Future<bool> _bind(Uint8List bookmark, {bool persist = false}) async {
    try {
      final res = await _channel.invokeMethod<Map>('resolve', {
        'bookmark': bookmark,
      });
      final path = res?['path'] as String?;
      if (path == null) {
        // 原生回了个 null：书签解析不出来。
        _notePermanent('RESOLVE', 'bookmark 无法解析');
        return false;
      }
      folderPath = path;
      if (persist) {
        await GStorage.localCache.put(LocalCacheKey.iCloudLogBookmark, bookmark);
      }
      _rebindTimer?.cancel();
      _rebindTimer = null;
      _failing = false;
      _permanentFailures = 0;
      setConsoleLogSyncHook(
        _upload,
        stagingPath: p.join(appSupportDirPath, _stagingName),
      );
      _startTimer();
      // 绑定/启动时立刻来一次：把当次启动攒下的日志马上顶上去，不用等 60 秒。
      if (!_syncedOnce) {
        _syncedOnce = true;
        requestConsoleLogSync();
      }
      return true;
    } on PlatformException catch (e) {
      // RESOLVE / NO_ACCESS：书签本身废了（文件夹被改名、被移走、被删）。
      _notePermanent(e.code, e.message ?? '');
      _scheduleRebind();
      return false;
    } catch (e) {
      _noteTransient('绑定失败: $e');
      _scheduleRebind();
      return false;
    }
  }

  /// 绑定失败后隔一阵再试。
  ///
  /// 少了它，冷启动那一次解析失败就**整个会话都绑不上了** —— 没有定时器、
  /// 没有钩子，唯一的出路是用户自己去设置页重选一遍文件夹。而冷启动
  /// iCloud Drive 还没挂好恰恰是最常见的一种失败。
  static void _scheduleRebind() {
    if (_rebindTimer != null) return;
    if (_readBookmark() == null) return; // 压根没绑过，没什么可重试的
    _rebindTimer = Timer(_rebindDelay, () {
      _rebindTimer = null;
      final bookmark = _readBookmark();
      if (bookmark == null) return;
      _bind(bookmark);
    });
  }

  /// 真正送出去的那一步 —— 就是交给 `console_log.dart` 的那个钩子。
  ///
  /// 抛异常表示"没送出去"，那边据此不提交内容指纹、下次重试同一份内容。
  /// **所以"跳过"也必须抛**，见 [_deferred]。
  static Future<void> _upload(String stagingPath) async {
    // 每一次提前返回都要变成异常：正常返回会被 console_log 当成"送出去了"，
    // 于是它把这份内容标成已同步 —— 而这份内容一个字节都没出去，
    // 下一次带着同样内容来的时候就会被指纹挡掉，**它在 iCloud 上永远不出现**。
    if (!isConfigured) throw _deferred;
    if (_syncing) {
      // 已经有一次在飞。合并掉，等它落地再跑一次（见 finally）。
      _pending = true;
      throw _deferred;
    }
    _syncing = true;
    try {
      await _channel.invokeMethod('uploadLog', {'stagingPath': stagingPath});
      lastSyncedAt = DateTime.now();
      lastError = null;
      if (_failing) {
        _failing = false;
        debugPrint('iCloud 日志同步: 恢复正常');
      }
      _permanentFailures = 0;
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'RESOLVE':
        case 'NO_ACCESS':
        case 'NO_FOLDER':
          _notePermanent(e.code, e.message ?? '');
        default:
          _noteTransient('同步失败(${e.code}): ${e.message}');
      }
      rethrow; // 让 console_log.dart 别提交指纹
    } catch (e) {
      _noteTransient('同步失败: $e');
      rethrow;
    } finally {
      _syncing = false;
      if (_pending) {
        _pending = false;
        requestConsoleLogSync(); // 合并掉的那一次
      }
    }
  }

  /// 瞬时失败：只记状态跳变，**不动配置**。
  static void _noteTransient(String message) {
    lastError = message;
    if (_failing) return;
    _failing = true;
    debugPrint('iCloud 日志同步: $message（会继续重试）');
  }

  /// 永久失败：等够阈值才清掉配置、退回「未设置」。
  static void _notePermanent(String code, String message) {
    lastError = '$code $message';
    _permanentFailures++;
    if (!_failing) {
      _failing = true;
      debugPrint('iCloud 日志同步: 访问失败($code) $message');
    }
    if (_permanentFailures >= _kPermanentFailuresBeforeUnbind) {
      // toast **只会弹这一次** —— 清完配置就退回「未设置」，之后走不到这。
      unawaited(
        unbind().then((_) {
          try {
            SmartDialog.showToast('iCloud 日志同步已失效，请重新选择文件夹');
          } catch (_) {
            // 弹个提示而已，不该有能力把解绑这条路弄坏（测试里也没有 UI）
          }
        }),
      );
    }
  }

  static void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => syncNow());
  }

  static Uint8List? _readBookmark() {
    final raw = GStorage.localCache.get(LocalCacheKey.iCloudLogBookmark);
    // Hive 原样存回 `Uint8List`；别的类型（手改过、旧版本）一律当没设置。
    return raw is Uint8List ? raw : null;
  }

  /// 文件夹名，给设置页显示。`/private/var/...` 那一长串铺出来没法看，
  /// 而且中间那段是容器 UUID，重签一次就变。
  static String? get folderName {
    final path = folderPath;
    return path == null ? null : p.basename(path);
  }
}

/// 见 `ICloudLogSync._deferred`。只在内部当哨兵用 —— 调用点一律空捕获，
/// 从不让它冒到外面（`console_log.dart` 也是全吞）。
class _DeferredSync implements Exception {
  const _DeferredSync();

  @override
  String toString() => '这次没送（未绑定或已合并）';
}
