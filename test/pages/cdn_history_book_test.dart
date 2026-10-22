import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/pages/video/cdn_history_book.dart';
import 'package:PiliPlus/pages/video/cdn_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 10, 22, 13, 0, 0);

  CdnHistoryBook book() =>
      CdnHistoryBook(readRecord: () => const [], writeRecord: (_) {});

  group('clearObjectScoped 只清按对象记的那一本（评审 §2.10）', () {
    test('坏 host 清掉：换个视频，同一条边完全可能是好的', () {
      final b = book()
        ..noteBadHost('upos-sz-mirrorali.bilivideo.com')
        ..clearObjectScoped();
      expect(b.isBadHost('upos-sz-mirrorali.bilivideo.com'), isFalse);
    });

    test('冠军欠账跨集延续：短视频一集只跑一轮预检，按集清零永远降不下来', () {
      final b = book()
        ..championMisses[CDNService.ali] = CdnTuning.championMisses - 1
        ..clearObjectScoped();
      expect(b.championMisses[CDNService.ali], CdnTuning.championMisses - 1);
    });

    test('试过 / 无样本的冷却也跨集延续（原本就是这样，别被顺手改掉）', () {
      final b = book()
        ..noteTried([CDNService.cos], t0)
        ..noteNoSample(CDNService.hw)
        ..clearObjectScoped();
      expect(b.triedAt[CDNService.cos], t0);
      expect(b.noSample, contains(CDNService.hw));
    });
  });
}
