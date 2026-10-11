import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 把 [debugPrint] 的每一行同时落到应用文档目录的 `pili-console.log`。
///
/// 为什么需要：播放诊断（`CDN 看门狗` / `CDN 自动切换` / `CDN 遥测失真`、
/// mpv 的 `Stream ends prematurely` 等）全部只走 [debugPrint]，也就是 stdout。
/// 桌面端从终端启动还能重定向，但 **iOS 上 release 包没有 stdout 可看** ——
/// 从桌面图标启动、`devicectl --console` 附加、统一日志（`idevicesyslog`）
/// 三条路都拿不到（实测：进程活着，日志里 0 行）。于是最快的办法就是让 app
/// 自己写文件，再把这个文件取出来。
///
/// iOS 端配合 Info.plist 的 `UIFileSharingEnabled` +
/// `LSSupportsOpeningDocumentsInPlace`，文档目录会出现在「文件」App 里，
/// 也能被 `ifuse` 之类的 AFC 工具直接读到。
///
/// **写入走一条常驻的 [IOSink]，不做每行一次的同步写。** [debugPrint] 现在是
/// 热路径（mpv 开到 verbose 时，一次故障能连吐几百行），而每行一次
/// `writeAsStringSync` 是"开档 + seek + 写 + 关档"一整套系统调用，全部堵在
/// 负责出帧的那条线程上 —— 那是拿卡顿换日志。
///
/// 失败一律静默：日志写不进去绝不能影响播放。
const String _kConsoleLogName = 'pili-console.log';

/// 文件句柄还没就绪时先攒在内存里。上限只为兜底——万一
/// [getApplicationDocumentsDirectory] 一直失败，不能让这里无界增长。
const int _kPendingLimit = 2000;

/// 攒下的行最长在内存里待这么久就推一次。
///
/// [IOSink] 自带缓冲，不推也不会每行一次系统调用；但攒太久的话，进程被硬杀
/// 时会丢掉整段 —— 而"事后把文件取回来"恰恰是这个模块存在的理由。2 秒是
/// 折中：对播放故障而言足够小，系统调用又足够稀疏。
const Duration _kFlushInterval = Duration(seconds: 2);

/// 单个日志文件的上限。超过就**截断重来**，而不是停笔：查故障要的是最近
/// 那一段，不是最早那一段。
const int _kMaxBytes = 8 << 20; // 8 MiB

File? _consoleLogFile;
IOSink? _sink;
Timer? _flushTimer;
_ConsoleLogLifecycleObserver? _observer;

/// 装钩子之前的那个 [debugPrint]。
///
/// 存下来有两个用：一是反复安装不会层层套娃（见 [installConsoleLogCapture]），
/// 二是测试能把它还原回去（见 [resetConsoleLogCaptureForTest]）。
DebugPrintCallback? _original;

/// 写入串行队列。写一行、推一次缓冲、做一轮轮换，都排在这一条链上，一次只跑
/// 一件。**这个"串行"是必需的，不是顺手写的**，两个原因：
///
/// 1. 轮换是"关旧 sink → 截断 → 开新 sink"。不串行的话，中间插进来的写入会
///    落到一条已经关掉的 sink 上，或者被截断吃掉。测试里真出现过：轮换还没关
///    完，几十行全挤进 [_pendingLines]，等轮换结束整批倒回去时又立刻超上限、
///    再触发轮换，于是正在倒的那批写进一条已经置空的 sink —— 整段蒸发，
///    文件读出来是空的。
/// 2. [IOSink.flush] 与 [IOSink.close] **在各自的 future 完成之前会把 sink
///    标成 "bound"**，这期间再调一次就直接抛 `StreamSink is bound to a
///    stream`。原先 [Timer.periodic] 那路是即发即忘地调 `flush()`，只要和
///    写入/关闭重叠就会抛，而错误又被静默吞掉 —— 表现就是"什么都没写进去"。
///    串行之后不可能重叠。
Future<void> _queue = Future.value();

/// 攒着还没写进文件的字节数，用来判上限。
int _bytesWritten = 0;

/// 上限，生产恒为 [_kMaxBytes]；测试可调小，见 [setConsoleLogMaxBytesForTest]。
int _maxBytes = _kMaxBytes;

final List<String> _pendingLines = [];

/// 日志是否真的在落盘。
///
/// 诊断类的「话匣子」开关都以它为准：只有日志确实能写进文件时，才值得让
/// mpv 把话全说出来（见 pl_player/controller.dart 的 `logLevel` 与
/// `stream.log`）。文件打不开时退回原来的安静档，别白白刷屏。
bool get consoleLogActive => _sink != null;

/// 给一行日志盖上 `HH:mm:ss.SSS`。
///
/// 这个模块存在的理由是**事后**查故障，而自动换源的一半判据是时间窗判据 ——
/// 「6 秒内 12 条算风暴」（`_kDecodeErrorBurst` / `_kDecodeErrorWindow`）、
/// 「5ms 内算同一个坏包」（`_kDecodeLineDedupe`）、「换源后 ≥8s 没新报错才算
/// 恢复」（`_kCdnDecodeRecoverGrace` + `_kCdnDecodeCleanWindow`）。没有逐行时刻，
/// 日志只回答得了「发生过没有」，回答不了「够不够密」；而 mpv 落在日志里的原文
/// **一个时刻都不带**（`mpv [error] ffmpeg/video: av1: obu_forbidden_bit out of
/// range: 1, ...`），`awk '{print $2}'` 取到的是 `[error]` 而不是秒。2026-10-11
/// 加：真机上要判「12 条 / 6s 这道门槛到底够不够得着」，只能靠它。
///
/// 毫秒必须留着 —— `_kDecodeLineDedupe` 是 5ms。多行消息**逐行**盖戳，保证
/// 文件里每条物理行都带戳，事后拿 grep/awk 处理时不用先猜哪行有哪行没有。
String _stamp(String message) {
  final t = DateTime.now();
  final stamp = '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${t.millisecond.toString().padLeft(3, '0')}';
  return message.contains('\n')
      ? '$stamp ${message.replaceAll('\n', '\n$stamp ')}'
      : '$stamp $message';
}

/// 安装落盘钩子。必须在 binding 初始化之后、`runApp` 之前调用一次。
///
/// [logFile] 只给测试用，正常调用不传（走 [getApplicationDocumentsDirectory]）。
Future<void> installConsoleLogCapture({@visibleForTesting File? logFile}) async {
  // 取**最初**那个 debugPrint，而不是"上一个钩子"。否则重复安装会一层层
  // 套上去，每行日志被转手 N 次、写 N 遍。
  final original = _original ??= debugPrint;

  // 先把钩子装上、开始缓存，**再**去开档。开档要 await，
  // 那期间 binding 自己就会打日志；等开完档再装钩子，那些行就全丢了。
  debugPrint = (String? message, {int? wrapWidth}) {
    original(message, wrapWidth: wrapWidth);
    if (message == null) return;
    // 盖戳在**捕获**这一侧，不在落盘那一侧：开档要 await，那之前攒进
    // [_pendingLines] 的行若等补写时才盖戳，时刻会整体后移到开档之后。
    final line = _stamp(message);
    if (_sink == null) {
      if (_pendingLines.length < _kPendingLimit) _pendingLines.add(line);
      return;
    }
    _enqueue('$line\n');
  };

  // 已经装过就先把上一份收干净。生产只在 main() 里调一次，但真被调第二次
  // 时，留着一条悬空的旧 sink（缓冲里可能还有字节）比直接关掉危险得多。
  await _queue;
  final stale = _sink;
  _sink = null;
  await stale?.close();

  try {
    final file = logFile ??
        File(p.join((await getApplicationDocumentsDirectory()).path,
            _kConsoleLogName));
    await file.writeAsString('', flush: true); // 每次启动截断
    _consoleLogFile = file;
    _sink = file.openWrite(mode: FileMode.append);
    _bytesWritten = 0;
  } catch (e) {
    original('console log: 无法打开日志文件 ($e)，本次只写 stdout');
  }

  // 开档期间（以及更早）攒下的行，靠这一次补写进去。
  _flush();
  _startHousekeeping();
}

void _startHousekeeping() {
  if (_sink == null || _flushTimer != null) return;
  _flushTimer = Timer.periodic(_kFlushInterval, (_) => _flush());
  _observer = _ConsoleLogLifecycleObserver();
  WidgetsBinding.instance.addObserver(_observer!);
}

/// 把一段文本排进写入队列。必须同步返回 —— 它跑在 [debugPrint] 里。
void _enqueue(String text) {
  _queue = _queue.then((_) => _write(text));
}

/// 队列上的一步：超上限就先轮换，再把这行写下去。
///
/// 关键是顺序 —— **先轮换后写**，不是"超了就把这行扔掉"。扔掉的话，攒在
/// [_pendingLines] 里的那批（往往正好是最近、最想看的几十行）会整批消失。
Future<void> _write(String text) async {
  try {
    if (_sink == null) return; // 没装成功，或轮换失败：静默丢弃，不抛
    if (_bytesWritten + text.length > _maxBytes) {
      await _rotate();
      if (_sink == null) return; // 轮换也失败了
    }
    _sink!.write(text);
    _bytesWritten += text.length;
  } catch (_) {
    // 见上：写失败不影响播放
  }
}

/// 排进一次"推缓冲"。即发即忘，但**排在同一条队列上** ——
/// 见 [_queue] 的第 2 条原因：[IOSink.flush] 不能重叠。
void _flush() {
  _queue = _queue.then((_) => _flushStep());
}

/// 队列上的一步：先补写 [_pendingLines]（轮换那几毫秒里攒下的），再推缓冲。
Future<void> _flushStep() async {
  final sink = _sink;
  if (sink == null) return;
  try {
    if (_pendingLines.isNotEmpty) {
      final text = '${_pendingLines.join('\n')}\n';
      _pendingLines.clear();
      // 这里刻意不再判上限：这批是**最近**的行，宁可贵一点（下一次 _write
      // 会顺手轮换回来），也不能因为超限而整批丢掉。
      sink.write(text);
      _bytesWritten += text.length;
    }
    await sink.flush();
  } catch (_) {
    // 同上
  }
}

/// 到顶了就把文件清空重来，并留一行痕迹说明日志在这里断过。
///
/// 重来而不是停笔：用户报故障时，想要的是**最近**那段日志，不是最早那段。
///
/// 只由 [_write] 调用，因此总在 [_queue] 上执行：先把 [_sink] 置空再截断重开，
/// 中间不能让任何一行插进来写到那条已经关掉的旧 sink 上。
Future<void> _rotate() async {
  final file = _consoleLogFile;
  final old = _sink;
  _sink = null;
  _bytesWritten = 0;
  try {
    await old?.close();
    if (file == null) return;
    final sink = file.openWrite(mode: FileMode.write) // 截断
      ..write('${_stamp('=== 日志达到 $_maxBytes 字节上限，此处截断重来 ===')}\n');
    _sink = sink;
  } catch (_) {
    _sink = null; // 重开失败就彻底放弃落盘，绝不抛给调用方
  }
}

/// 退到后台或退出前把缓冲冲掉：硬杀的话，[IOSink] 攒在内存里的那部分
/// 是留不住的，而那往往正是崩溃前最后几行 —— 最想看的那几行。
class _ConsoleLogLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _flush();
    }
  }
}

// ---------------------------------------------------------------------------
// 测试接缝
//
// 这个模块的失败模式是**无声**的：写不进去就静默放弃，日志看起来"什么都没
// 发生"。上面那条 [_queue] 就是被 test/console_log_test.dart 逼出来的 ——
// 包括 `StreamSink is bound to a stream`（flush 没完成就再 flush/close）。
// 下面三个只给测试用，生产代码一行都不碰。
// ---------------------------------------------------------------------------

/// 把模块还原成"从未安装过"：等队列跑空、关 sink、停定时器、摘 observer、
/// 恢复 [debugPrint]。测试之间必须调，否则状态会串、钩子会一层层套上去。
///
/// `await _queue` 很关键：队列跑空前 [IOSink] 可能正处在 flush 的 "bound"
/// 状态，那时 [IOSink.close] 会直接抛。
@visibleForTesting
Future<void> resetConsoleLogCaptureForTest() async {
  final original = _original;
  if (original != null) debugPrint = original;
  _original = null;

  _flushTimer?.cancel();
  _flushTimer = null;
  if (_observer != null) {
    WidgetsBinding.instance.removeObserver(_observer!);
    _observer = null;
  }

  await _queue;
  final old = _sink;
  _sink = null;
  _consoleLogFile = null;
  _bytesWritten = 0;
  _maxBytes = _kMaxBytes;
  _pendingLines.clear();
  await old?.close();
}

/// 调小上限，好在测试里真的走到轮换那条路 —— 生产值 8MiB，没人跑得到，
/// 而"跑不到的代码"正是最容易悄悄坏掉的代码。
@visibleForTesting
void setConsoleLogMaxBytesForTest(int bytes) => _maxBytes = bytes;

/// 排一次推缓冲，等队列跑空，然后才返回。
///
/// 不这么做的话，测试只能在"写完了"和"还在攒"之间猜一个 sleep。
@visibleForTesting
Future<void> flushConsoleLogForTest() async {
  _flush();
  await _queue;
}
