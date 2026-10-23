import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/background_resume.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('先等重建完成，再检查现场并续播', () async {
    final releaseRebuild = Completer<void>();
    final events = <String>[];

    final future = reinitThenResumePlayback(
      reinit: () async {
        events.add('rebuild:start');
        await releaseRebuild.future;
        events.add('rebuild:end');
      },
      canResume: () {
        events.add('check');
        return true;
      },
      resume: () async {
        events.add('resume');
      },
    );

    await Future<void>.delayed(Duration.zero);
    expect(events, ['rebuild:start']);

    releaseRebuild.complete();
    expect(await future, isTrue);
    expect(events, ['rebuild:start', 'rebuild:end', 'check', 'resume']);
  });

  test('重建期间现场变化时取消续播', () async {
    final releaseRebuild = Completer<void>();
    var canResume = true;
    var resumed = false;

    final future = reinitThenResumePlayback(
      reinit: () async {
        await releaseRebuild.future;
      },
      canResume: () => canResume,
      resume: () async {
        resumed = true;
      },
    );

    canResume = false;
    releaseRebuild.complete();

    expect(await future, isFalse);
    expect(resumed, isFalse);
  });

  test('重建异常时绝不续播', () async {
    var resumed = false;
    final future = reinitThenResumePlayback(
      reinit: () async => throw StateError('rebuild failed'),
      canResume: () => true,
      resume: () async {
        resumed = true;
      },
    );

    await expectLater(future, throwsStateError);
    expect(resumed, isFalse);
  });
}
