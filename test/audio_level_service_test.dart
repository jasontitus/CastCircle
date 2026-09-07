import 'dart:async';

import 'package:castcircle/data/services/audio_level_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transient analysis failure is not cached', () async {
    var calls = 0;
    final service = AudioLevelService.forTesting((_) async {
      calls++;
      if (calls == 1) throw StateError('decoder warming up');
      return {'rmsDbfs': -6.0};
    });

    expect(await service.volumeFor('/take.m4a'), 1.0);
    expect(await service.volumeFor('/take.m4a'), closeTo(0.3, 0.0001));
    expect(calls, 2);
  });

  test('measured unity gain is cached', () async {
    var calls = 0;
    final service = AudioLevelService.forTesting((_) async {
      calls++;
      return {'rmsDbfs': -30.0};
    });

    expect(await service.volumeFor('/quiet.m4a'), 1.0);
    expect(await service.volumeFor('/quiet.m4a'), 1.0);
    expect(calls, 1);
  });

  test('concurrent cache misses share one native analysis', () async {
    var calls = 0;
    final result = Completer<dynamic>();
    final service = AudioLevelService.forTesting((_) {
      calls++;
      return result.future;
    });

    final first = service.volumeFor('/shared.m4a');
    final second = service.volumeFor('/shared.m4a');
    expect(calls, 1);

    result.complete({'rmsDbfs': -12.0});
    expect(
      await Future.wait([first, second]),
      everyElement(closeTo(0.5011872336, 0.0000001)),
    );
    expect(calls, 1);
  });

  test('cache eviction honors recent reads', () async {
    final calls = <String, int>{};
    final service = AudioLevelService.forTesting((path) async {
      calls[path] = (calls[path] ?? 0) + 1;
      return {'rmsDbfs': -30.0};
    });

    for (var i = 0; i < 512; i++) {
      await service.volumeFor('/$i.m4a');
    }
    await service.volumeFor('/0.m4a');
    await service.volumeFor('/512.m4a');

    await service.volumeFor('/0.m4a');
    await service.volumeFor('/1.m4a');
    expect(calls['/0.m4a'], 1);
    expect(calls['/1.m4a'], 2);
  });
}
