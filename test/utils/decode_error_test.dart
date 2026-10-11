import 'package:PiliPlus/utils/decode_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// 判定用的样本全部是**逐字抄下来的实测日志行**（2026-10-11 从 iPhone 上取回的
/// `pili-console.log`），不是编的：AV1 那一族来自那次 400+ 条的刷屏，H.264 的
/// 两条来自同一份日志里换集边界上的零星报错，下面的反例来自同一份日志里那些
/// **不该**触发换源的行。
void main() {
  group('isDecoderCorruptionLog 认得坏字节', () {
    test('the AV1 storm that froze the picture', () {
      const lines = [
        'av1: obu_forbidden_bit out of range: 1, but must be in [0,0].',
        'av1: Failed to read packet.',
        'av1: Invalid leb128 at obu_size: bitstream ended.',
        // 硬解放弃之后的软解回退，同一份数据换了个解码器照样报。
        'libdav1d: Error parsing OBU data',
        'libdav1d: Overrun in OBU bit buffer',
        'libdav1d: Unknown OBU type 13 of size 124',
        'libdav1d: Error parsing sequence header',
        'libdav1d: Unknown Metadata OBU type 1824451',
        // 还没绑上解码器的那几行，前缀是光秃秃的 `NULL:`。
        'NULL: Failed to parse temporal unit.',
        'NULL: extension_header_reserved_3bits out of range: 4, but must be in [0,0].',
        'NULL: obu_reserved_1bit out of range: 1, but must be in [0,0].',
      ];
      for (final line in lines) {
        expect(isDecoderCorruptionLog(line), isTrue, reason: line);
      }
    });

    test('the stray errors at a stream boundary', () {
      // 换集/seek 边界上单个损坏的 GOP。它们只值一两条，凑不满风暴门槛，
      // 但必须被认出来 —— 否则一条长期播放里迟早攒够。
      expect(isDecoderCorruptionLog('Invalid NAL unit size (34817 > 5117).'), isTrue);
      expect(
        isDecoderCorruptionLog('missing picture in access unit with size 5121'),
        isTrue,
      );
    });
  });

  group('不该认的', () {
    test('network failures are "did not arrive", not "cannot be decoded"', () {
      // 这些是"没喂到"，另有 stream.error 那条恢复路径管；算进风暴会让一次
      // 普通网络抖动触发换源。
      const lines = [
        'tcp: ffurl_read returned 0xdfb9b0bb',
        'Stream ends prematurely at 0, should be 543447102',
        "Failed to open https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/x",
        "Can not open external file https://upos-sz-mirrorcosov.bilivideo.com/x",
        'https: Error reading HTTP response: Input/output error',
        'tls: Error decoding the received TLS packet.',
      ];
      for (final line in lines) {
        expect(isDecoderCorruptionLog(line), isFalse, reason: line);
      }
    });

    test('unrelated player errors are untouched', () {
      const lines = [
        // 这一条在同一份日志里出现过两次，都跟字节无关。
        'Vulkan: Unable to open the libvulkan library!',
        "EDL: Could not open source file 'https://upos-sz-mirrorhw.bilivideo.com/x'",
        'stream 0, offset 0x9b0962: partial file',
        // 应用自己的那几行。它们和 mpv 走同一个日志文件。
        'CDN 自动切换: 判定 最快候选 hw（华为云，融合CDN） 2.94MB/s / 基线 2.04MB/s = 1.44x (阈值 1.5) -> 不切换',
        '',
      ];
      for (final line in lines) {
        expect(isDecoderCorruptionLog(line), isFalse, reason: line);
      }
    });
  });

  test('matching is on substrings, so the level/prefix wrapper cannot hide it', () {
    // 实际送进来的是 `log.text`（没有 `mpv [error] ffmpeg/video: ` 前缀），
    // 但前缀本来就没有区分度：同一个故障在三层上报时前缀各不相同。
    expect(
      isDecoderCorruptionLog(
        'mpv [error] ffmpeg/video: libdav1d: Error parsing OBU data',
      ),
      isTrue,
    );
  });
}
