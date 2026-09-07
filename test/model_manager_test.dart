import 'dart:io';

import 'package:castcircle/data/services/model_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late Directory pack;
  late ModelManager manager;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('model_manager_test_');
    pack = Directory(p.join(temp.path, 'kokoro-en-fp16-v1_0'));
    for (final artifact in ModelManager.kokoroRequiredArtifacts) {
      final file = File(p.join(pack.path, artifact.relativePath));
      await file.parent.create(recursive: true);
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(artifact.sizeBytes);
      await handle.close();
    }
    await File(
      p.join(pack.path, '.castcircle-pack.json'),
    ).writeAsString(ModelManager.kokoroManifestJson, flush: true);
    manager = ModelManager.forTesting(temp.path);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('complete verified manifest supplies every engine path', () async {
    expect(await manager.kokoroProblem(), isNull);
    expect(await manager.isKokoroReady(), isTrue);

    final paths = await manager.getKokoroPaths();
    expect(paths, isNotNull);
    expect(paths!.lexicon, contains('lexicon-us-en.txt'));
    expect(paths.lexicon, contains('lexicon-gb-en.txt'));
    expect(paths.dataDir, endsWith('espeak-ng-data'));
  });

  for (final artifact in ModelManager.kokoroRequiredArtifacts) {
    test(
      'truncated ${artifact.relativePath} makes the whole pack unready',
      () async {
        final file = File(p.join(pack.path, artifact.relativePath));
        final handle = await file.open(mode: FileMode.write);
        await handle.truncate(artifact.sizeBytes - 1);
        await handle.close();

        expect(
          await manager.kokoroProblem(),
          startsWith('${artifact.relativePath} size'),
        );
        expect(await manager.isKokoroReady(), isFalse);
        expect(await manager.getKokoroPaths(), isNull);
      },
    );

    test(
      'missing ${artifact.relativePath} makes the whole pack unready',
      () async {
        await File(p.join(pack.path, artifact.relativePath)).delete();

        expect(
          await manager.kokoroProblem(),
          '${artifact.relativePath} missing',
        );
        expect(await manager.isKokoroReady(), isFalse);
        expect(await manager.getKokoroPaths(), isNull);
      },
    );
  }

  test(
    'missing espeak data directory is surfaced before engine load',
    () async {
      await Directory(
        p.join(pack.path, 'espeak-ng-data'),
      ).delete(recursive: true);

      expect(await manager.kokoroProblem(), 'espeak-ng-data missing');
      expect(await manager.getKokoroPaths(), isNull);
    },
  );

  test('manifest from another pack release is rejected', () async {
    await File(
      p.join(pack.path, '.castcircle-pack.json'),
    ).writeAsString('{"model":"other"}', flush: true);

    expect(
      await manager.kokoroProblem(),
      'verification manifest does not match kokoro-en-fp16-v1_0',
    );
    expect(await manager.isKokoroReady(), isFalse);
  });

  test('reconciles crash after active pack was moved aside', () async {
    final backup = Directory('${pack.path}.previous-123456789');
    final abandonedStaging = Directory(
      p.join(temp.path, '.kokoro_staging_before_publish'),
    );
    await pack.rename(backup.path);
    await abandonedStaging.create(recursive: true);
    await File(p.join(abandonedStaging.path, 'partial')).writeAsString('x');

    final readiness = await Future.wait([
      manager.isKokoroReady(),
      manager.isKokoroReady(),
    ]);
    expect(readiness, everyElement(isTrue));
    expect(await pack.exists(), isTrue);
    expect(await backup.exists(), isFalse);
    expect(await abandonedStaging.exists(), isFalse);
  });

  test(
    'reconciles crash after verified pack publish but before cleanup',
    () async {
      final leftoverBackup = Directory('${pack.path}.previous-987654321');
      final leftoverStaging = Directory(
        p.join(temp.path, '.kokoro_staging_after_publish'),
      );
      await leftoverBackup.create(recursive: true);
      await File(p.join(leftoverBackup.path, 'old')).writeAsString('x');
      await leftoverStaging.create(recursive: true);
      await File(p.join(leftoverStaging.path, 'empty-root')).writeAsString('x');

      expect(await manager.isKokoroReady(), isTrue);
      expect(await pack.exists(), isTrue);
      expect(await leftoverBackup.exists(), isFalse);
      expect(await leftoverStaging.exists(), isFalse);
    },
  );

  test(
    'active extraction lease is preserved and cleanup retries later',
    () async {
      final leasedStaging = Directory(
        p.join(temp.path, '.kokoro_staging_in_flight'),
      );
      await leasedStaging.create(recursive: true);
      await File(p.join(leasedStaging.path, 'partial')).writeAsString('x');
      final whileActive = ModelManager.forTesting(
        temp.path,
        activePackStagingPaths: {leasedStaging.path},
      );

      expect(await whileActive.isKokoroReady(), isTrue);
      expect(await leasedStaging.exists(), isTrue);

      final afterRestart = ModelManager.forTesting(temp.path);
      expect(await afterRestart.isKokoroReady(), isTrue);
      expect(await leasedStaging.exists(), isFalse);
    },
  );
}
