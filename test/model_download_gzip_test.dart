import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:castcircle/data/services/model_download_service.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final payload = utf8.encode(
    List.generate(652, (i) => '▁token$i $i').join('\n'),
  );
  late Directory documents;
  HttpServer? server;

  AiModel modelFor(Uri uri) => AiModel(
    id: 'test_tokens',
    name: 'Test tokens',
    description: 'Local downloader fixture',
    sizeLabel: '${payload.length} B',
    sizeBytes: payload.length,
    exactSizeBytes: payload.length,
    sha256: crypto.sha256.convert(payload).toString(),
    downloadUrl: uri.toString(),
    filename: 'tokens.txt',
    subdir: 'live_asr',
  );

  setUp(() async {
    documents = await Directory.systemTemp.createTemp(
      'model_download_service_test_',
    );
  });

  tearDown(() async {
    await server?.close(force: true);
    server = null;
    if (await documents.exists()) await documents.delete(recursive: true);
  });

  Future<(Uri, List<String?>)> serve({required bool alwaysGzip}) async {
    final seenAcceptEncoding = <String?>[];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((request) async {
      final accept = request.headers.value(HttpHeaders.acceptEncodingHeader);
      seenAcceptEncoding.add(accept);
      final shouldGzip = alwaysGzip || (accept?.contains('gzip') ?? false);
      final bytes = shouldGzip ? gzip.encode(payload) : payload;
      if (shouldGzip) {
        request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      }
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    return (
      Uri.parse('http://${server!.address.host}:${server!.port}/tokens.txt'),
      seenAcceptEncoding,
    );
  }

  Future<File> downloadFrom(Uri uri) async {
    final model = modelFor(uri);
    final service = ModelDownloadService.forTesting(
      documentsDirectory: documents.path,
      models: [model],
    );
    await service.download(model);
    expect(service.getState(model.id).status, ModelStatus.downloaded);
    return File(p.join(documents.path, 'models', 'live_asr', 'tokens.txt'));
  }

  test('real service requests identity and persists verified bytes', () async {
    final (uri, seenAcceptEncoding) = await serve(alwaysGzip: false);
    final installed = await downloadFrom(uri);

    expect(seenAcceptEncoding, ['identity']);
    expect(await installed.readAsBytes(), payload);
  });

  test(
    'real service decodes forced gzip before verification and adoption',
    () async {
      final (uri, seenAcceptEncoding) = await serve(alwaysGzip: true);
      final installed = await downloadFrom(uri);

      expect(seenAcceptEncoding, ['identity']);
      expect(await installed.readAsBytes(), payload);
      expect(gzip.encode(payload).length, lessThan(payload.length));
    },
  );

  test('refresh preserves an active Dart temporary download', () async {
    final requestStarted = Completer<void>();
    final finishResponse = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((request) async {
      request.response.contentLength = payload.length;
      request.response.add(payload.sublist(0, payload.length ~/ 2));
      await request.response.flush();
      requestStarted.complete();
      await finishResponse.future;
      request.response.add(payload.sublist(payload.length ~/ 2));
      await request.response.close();
    });
    final uri = Uri.parse(
      'http://${server!.address.host}:${server!.port}/tokens.txt',
    );
    final model = modelFor(uri);
    final service = ModelDownloadService.forTesting(
      documentsDirectory: documents.path,
      models: [model],
    );

    final transfer = service.download(model);
    await requestStarted.future;
    final tempFile = File(
      p.join(documents.path, 'models', 'live_asr', 'tokens.txt.tmp'),
    );
    for (var i = 0; i < 100 && !await tempFile.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(await tempFile.exists(), isTrue);

    await service.refreshDownloadedStatus();
    expect(await tempFile.exists(), isTrue);
    expect(service.getState(model.id).status, ModelStatus.downloading);

    finishResponse.complete();
    await transfer;
    expect(service.getState(model.id).status, ModelStatus.downloaded);
  });

  test('refresh removes an old orphan temporary artifact', () async {
    final uri = Uri.parse('http://127.0.0.1/unused');
    final model = modelFor(uri);
    final service = ModelDownloadService.forTesting(
      documentsDirectory: documents.path,
      models: [model],
    );
    final orphan = File(
      p.join(documents.path, 'models', 'live_asr', 'tokens.txt.tmp'),
    );
    await orphan.parent.create(recursive: true);
    await orphan.writeAsBytes([1, 2, 3], flush: true);
    await orphan.setLastModified(
      DateTime.now().subtract(const Duration(days: 2)),
    );

    await service.refreshDownloadedStatus();
    expect(await orphan.exists(), isFalse);
  });

  test('bulk download skips a fully verified installed component', () async {
    var requests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((request) async {
      requests++;
      request.response.add(utf8.encode('corrupt replacement'));
      await request.response.close();
    });
    final uri = Uri.parse(
      'http://${server!.address.host}:${server!.port}/tokens.txt',
    );
    final model = modelFor(uri);
    final installed = File(
      p.join(documents.path, 'models', 'live_asr', 'tokens.txt'),
    );
    await installed.parent.create(recursive: true);
    await installed.writeAsBytes(payload, flush: true);
    final service = ModelDownloadService.forTesting(
      documentsDirectory: documents.path,
      models: [model],
    );

    await service.downloadAll();

    expect(requests, 0);
    expect(await installed.readAsBytes(), payload);
    expect(service.getState(model.id).status, ModelStatus.downloaded);
  });

  test(
    'corrupt replacement is discarded without touching prior bytes',
    () async {
      final priorBytes = List<int>.filled(payload.length, 0x41);
      final corruptReplacement = List<int>.filled(payload.length, 0x42);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server!.listen((request) async {
        request.response.contentLength = corruptReplacement.length;
        request.response.add(corruptReplacement);
        await request.response.close();
      });
      final uri = Uri.parse(
        'http://${server!.address.host}:${server!.port}/tokens.txt',
      );
      final model = modelFor(uri);
      final installed = File(
        p.join(documents.path, 'models', 'live_asr', 'tokens.txt'),
      );
      await installed.parent.create(recursive: true);
      await installed.writeAsBytes(priorBytes, flush: true);
      final service = ModelDownloadService.forTesting(
        documentsDirectory: documents.path,
        models: [model],
      );

      await service.downloadAll();

      expect(service.getState(model.id).status, ModelStatus.error);
      expect(await installed.readAsBytes(), priorBytes);
      expect(await File('${installed.path}.tmp').exists(), isFalse);
    },
  );
}
