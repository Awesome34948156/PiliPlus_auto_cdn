/// mpv / ffmpeg 在说「画面出不来了」的**两种**说法：一种怪**字节**，一种怪
/// **本机解码会话**。两者症状一模一样（声音在走、画面冻着、缓冲余量健康），
/// 但**该做的事相反** —— 前者换源，后者重建本机解码器。
///
/// 下面先讲第一种。
///
/// 这是换源型故障的**另一半**。另外几条 CDN 判据（位置冻结、缓冲饥饿、余量
/// 失真）看的都是"喂不饱"；而镜像把**坏字节**喂进来时，吞吐、余量、位置、hwdec
/// 全是健康的。2026-10-11 手机上的实测（档案 log 4）：一条 1080P AV1 流，余量
/// 27s、位置一路推进、`hwdec videotoolbox` 正常，同时 mpv 在刷 **524 行**解码
/// 报错、**横跨只有 44 毫秒**，而画面冻在最后一帧上（音频是另一条 EDL 源，照常播）。
/// 唯一看得见这件事的，就是解码器自己的报错 —— 而当时的换源逻辑只测吞吐，于是
/// 判定"基线健康 —— 卡顿多半不在 CDN"，然后放它过去。
///
/// **只收解码层**的说法。网络层的 `tcp: ffurl_read returned` /
/// `Stream ends prematurely` / `Failed to open https://` 是"没喂到"，另有
/// `stream.error` 那条恢复路径管；把它们混进来，一次普通网络抖动就会触发换源。
///
/// 每一条都取自实测日志，不是猜的：AV1 那一族来自 2026-10-11 那局的
/// `pili-console.log`（档案 log 4，`av1: obu_forbidden_bit out of range` 之类），
/// H.264 的两条来自换集边界上的零星报错 —— 那种一两条就停，不该触发换源。
///
/// 判定门槛（`PlPlayerController.PlayerTuning.decodeErrorBurst` = 12 条 / 6 秒）数的是
/// **去重后**的条数，不是原始行数 —— 两者的比由爆发有多密决定，**不是固定的
/// 3:1**（去重按时间间隔合并，不是按"一个包报几层"）。实测依据（档案 log 4 /
/// log 7，2026-10-12 复核）：log 4 的 524 行全挤在 44 毫秒里，去重后**只剩 9 条**
/// （够不到 12）；log 7 的 58 行横跨 2.4 秒，去重后 6 秒窗内峰值 **17 条**（够得到，
/// 余量 1.42×）。门槛正好卡在"换集边界 1~2 条"与"风暴十几条"中间。
const List<String> kDecoderCorruptionSignatures = [
  // AV1：ffmpeg 自己的 parser（`av1:`，以及还没绑上解码器时的无前缀 `NULL:`）
  // 和 libdav1d 软解回退。硬解失败会掉到后者，所以两种前缀会交替出现。
  'obu_forbidden_bit out of range',
  'obu_reserved_1bit out of range',
  'extension_header_reserved_3bits out of range',
  'Error parsing OBU data',
  'Error parsing sequence header',
  'Overrun in OBU bit buffer',
  'Unknown OBU type',
  // 注意还有 `Unknown Metadata OBU type N` 这个变体 —— 少了它，实测日志里有
  // 8 行漏网。子串 'Unknown OBU type' 匹配不到中间插了 'Metadata' 的那几句。
  'Metadata OBU type',
  'Invalid OBU length',
  'Failed to parse temporal unit',
  'Invalid leb128',
  'Failed to read packet',
  // H.264 / HEVC：切片长度对不上、访问单元里没有帧。
  'Invalid NAL unit size',
  'missing picture in access unit',
];

/// 预先转成小写的签名表，供 [isDecoderCorruptionLog] 做大小写无关匹配。
///
/// mpv/ffmpeg 的输出大小写并不稳定（同一句在不同版本里可能是
/// `Error parsing OBU data`，也可能是 `error parsing obu data`），而签名是
/// 从某一次的实测日志里逐字抄下来的。区分大小写的话，对方改一次大小写，
/// 整个判据就静默失效 —— 这种失配在 release 里没有任何提示。
final List<String> _kDecoderCorruptionSignaturesLower = kDecoderCorruptionSignatures
    .map((s) => s.toLowerCase())
    .toList(growable: false);

/// 这一行 mpv 日志是不是在说「解码器解不出这段字节」。
///
/// 只做子串匹配、不认前缀：同一个故障在 ffmpeg 的不同层上报时前缀各不相同
/// （`ffmpeg/video: av1:`、`ffmpeg/video: libdav1d:`、光秃秃的 `ffmpeg: NULL:`），
/// 而前缀本身没有区分度 —— 它们全是 ffmpeg。
///
/// 匹配大小写无关（见 [_kDecoderCorruptionSignaturesLower]）。
bool isDecoderCorruptionLog(String text) {
  final lower = text.toLowerCase();
  return _kDecoderCorruptionSignaturesLower.any(lower.contains);
}

/// mpv / ffmpeg 在说「**本机解码会话**已经废了」的几种说法。
///
/// 和 [kDecoderCorruptionSignatures] 是**两个不同的病**，虽然症状一模一样
/// （声音在走、画面冻着、余量健康）：
///
/// - 那一族是**镜像喂进来的字节**解不出来 —— 换源能治，`onDecodeError` 走那条路。
/// - 这一族是**本机的硬解会话**被系统作废了 —— 字节是好的，换源治不了，只能
///   重建本机解码器。2026-10-11 实测：app 退后台 6 分钟，回前台那一刻 **0.881 秒
///   内刷了 78 行**这类报错（`av1: Failed to decode frame (invalid session, -12903)`
///   ×1、`av1: vt decoder cb: output image buffer is null: -12909, reconfig 1` ×25，
///   其余两条是通用症状），随后**画面再没回来** —— 位置 19s→28s 在推进、余量 28s、
///   音频 AAC 正常，直到用户点走别的视频把它拆掉。
///
/// **刻意只收"会话 / 渲染缓冲"这一层。** 同一场风暴里的
/// `vd: Error while decoding frame (hardware decoding)!` 与
/// `av1: HW accel end frame fail.` **不收**：它们是**通用症状** —— 坏字节时也刷，
/// 而 `PLPlayerController` 里那段 `video-reload` 的事故记录（见
/// `_rebuildRenderContextOnNoVideo` 上方的墓碑注释）正是我们自己的重载弄出来的
/// 92 行同类报错。收进来会在**真正的坏
/// 字节风暴**里（那一族本该命中几百行并换源）把动作从"换源"改成"重建解码器"，
/// 等于治错了病。
const List<String> kDecoderSessionFailureSignatures = [
  // VideoToolbox 的 DecompressionSession 被系统作废。iOS 在 app 被挂起时会这么干；
  // 之后每一帧都解不出来，而音频走的是另一条 EDL 源，照常播。
  'invalid session',
  // 解码回调拿不到输出缓冲（`vt decoder cb: output image buffer is null: -12909`）。
  // 后面常跟 `reconfig N` —— mpv 自己试过重配，照样拿不到。
  'output image buffer is null',
];

/// 「解码器从 GOP 中间/没有参考帧的状态开始解」的签名 —— **续解族**。
///
/// 它既不是 [kDecoderCorruptionSignatures]（字节未必坏），也不是
/// [kDecoderSessionFailureSignatures]（会话未必被系统作废），而是在
/// **回前台重建解码器之后**最常见的那一段：`reinitDecoderAfterBackground` 切
/// hwdec 会清空参考帧池、再 seek 回原位，之后解码器先报这几条，紧接着才是成片的
/// OBU / 解码报错。2026-10-20 20:47 真机：回前台 0.35s 后先来
/// `Missing Sequence Header` + `Missing reference frame needed for
/// show_existing_frame`，随后 68ms 内 153 行 libdav1d 报错。
///
/// **只在"回前台续播窗口"里认**（`PlPlayerController._inForegroundResumeWindow`），
/// 不并进上面两张表：正常 seek 落到 GOP 中间、或镜像真的给了坏字节时，同样的字样
/// 也可能出现，只有"刚刚重建过本机解码链"这个上下文能让它指向本机。
const List<String> kDecoderContinuationSignatures = [
  'missing sequence header',
  'missing reference frame',
];

/// 预先转小写的签名表，理由同 [_kDecoderCorruptionSignaturesLower]。
final List<String> _kDecoderContinuationSignaturesLower =
    kDecoderContinuationSignatures
        .map((s) => s.toLowerCase())
        .toList(growable: false);

/// 这一行是不是「从 GOP 中间/缺参考帧开始解」的续解信号。
///
/// ⚠️ 单独看它**没有定罪价值**（见 [kDecoderContinuationSignatures]），必须由
/// 调用方用"刚重建过本机解码链"的窗口把它框住。
bool isDecoderContinuationLog(String text) {
  final lower = text.toLowerCase();
  return _kDecoderContinuationSignaturesLower.any(lower.contains);
}

/// 预先转小写的签名表，理由同 [_kDecoderCorruptionSignaturesLower]。
final List<String> _kDecoderSessionFailureSignaturesLower =
    kDecoderSessionFailureSignatures
        .map((s) => s.toLowerCase())
        .toList(growable: false);

/// 这一行 mpv 日志是不是在说「**本机硬解会话废了**」—— 注意不是"字节坏了"。
///
/// 调用方拿它做的动作与 [isDecoderCorruptionLog] **相反**：不是换源，而是重建
/// 本机解码器（`PLPlayerController.refreshPlayer`）。所以两者必须互斥地使用：
/// 有坏字节证据时让位给换源那条路（见 `_sampleDecoderSessionFailure` 里的让位判据）。
///
/// 匹配同样大小写无关、同样只做子串匹配，理由同 [isDecoderCorruptionLog]。
bool isDecoderSessionFailureLog(String text) {
  final lower = text.toLowerCase();
  return _kDecoderSessionFailureSignaturesLower.any(lower.contains);
}

/// 记一条**已判定为坏字节**的报错（[isDecoderCorruptionLog] 过了才调），
/// 返回窗口内的条数是否达到 [burst]。
///
/// [hits] 是**可变**的，就地追加并淘汰掉比 [window] 更早的时刻。淘汰用严格
/// `>`：正好落在窗口边界上的那一条还算数。
///
/// 达到 [burst] 时**不清空** [hits] —— 清不清由调用方决定，因为它还欠着一个
/// 静默期判断：静默期压的是**上报**、不是计数。静默期内攒下的那一批必须在静默期
/// 一过就兑现，否则一场风暴会被静默期整段吞掉，静默期结束后还要从头再攒一轮。
///
/// 和 [hits] 最后一条相隔不到 [lineDedupe] 的，当成同一个坏包的多份副本，不计入：
/// 同一个坏包在 ffmpeg 的各层（`av1:` / `libdav1d:` / `NULL:`）各记一行，
/// 不合并的话 [burst] 的实际含义会缩水到三分之一。
///
/// 判别用的样本全部来自实测日志，见 [kDecoderCorruptionSignatures]。
bool recordDecodeErrorHit(
  List<DateTime> hits,
  DateTime now, {
  required Duration window,
  required int burst,
  required Duration lineDedupe,
}) {
  // 时钟回拨（NTP 校正、用户改表）会让 [hits] 里的时刻落在"未来"：差值成负数，
  // 去重分支于是把**此后每一条**报错都当成同一个坏包的副本吞掉；而淘汰条件
  // `now.difference(at) > window` 对未来时刻同样不成立，那条记录永远清不掉 ——
  // 判据整个 session 静默失效。[CdnSpeedTest.recordTooOld] 就是为同一件事改成
  // "负差值算过期"的（见条目 16），这里同理：回拨之后一律当成新的一条，并把
  // 落在未来的旧记录清掉。
  if (hits.isNotEmpty &&
      !now.isBefore(hits.last) &&
      now.difference(hits.last) < lineDedupe) {
    return false;
  }
  hits
    ..add(now)
    ..removeWhere((at) => at.isAfter(now) || now.difference(at) > window);
  return hits.length >= burst;
}
