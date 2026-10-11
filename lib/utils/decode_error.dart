/// mpv / ffmpeg 在说「你给我的这段字节我解不出来」的几种说法。
///
/// 这是换源型故障的**另一半**。另外几条 CDN 判据（位置冻结、缓冲饥饿、余量
/// 失真）看的都是"喂不饱"；而镜像把**坏字节**喂进来时，吞吐、余量、位置、hwdec
/// 全是健康的。2026-10-11 手机上的实测：一条 1080P AV1 流，余量 27s、位置一路
/// 推进、`hwdec videotoolbox` 正常，同时 mpv 在刷 400+ 条解码报错，而画面冻在
/// 最后一帧上（音频是另一条 EDL 源，照常播）。唯一看得见这件事的，就是解码器
/// 自己的报错 —— 而当时的换源逻辑只测吞吐，于是判定"基线健康 —— 卡顿多半不在
/// CDN"，然后放它过去。
///
/// **只收解码层**的说法。网络层的 `tcp: ffurl_read returned` /
/// `Stream ends prematurely` / `Failed to open https://` 是"没喂到"，另有
/// `stream.error` 那条恢复路径管；把它们混进来，一次普通网络抖动就会触发换源。
///
/// 每一条都取自实测日志，不是猜的：AV1 那一族来自上面那局的 `pili-console.log`
/// （400+ 条，`av1: obu_forbidden_bit out of range` 之类），H.264 的两条来自同一
/// 份日志里换集边界上的零星报错 —— 那种一两条就停，不该触发换源，所以判定门槛
/// （`PlPlayerController._kDecodeErrorBurst`）卡在两者之间。
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

/// 这一行 mpv 日志是不是在说「解码器解不出这段字节」。
///
/// 只做子串匹配、不认前缀：同一个故障在 ffmpeg 的不同层上报时前缀各不相同
/// （`ffmpeg/video: av1:`、`ffmpeg/video: libdav1d:`、光秃秃的 `ffmpeg: NULL:`），
/// 而前缀本身没有区分度 —— 它们全是 ffmpeg。
bool isDecoderCorruptionLog(String text) =>
    kDecoderCorruptionSignatures.any(text.contains);
