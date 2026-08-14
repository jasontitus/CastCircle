import 'dart:convert';
import 'dart:io';

import 'package:castcircle/data/services/model_download_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression test for the bug that broke Live Line Matching on Android:
/// the CDN gzips `text/plain` whether or not the client asks, and with
/// `autoUncompress = false` those 3324 compressed bytes were written to disk
/// under a name the verifier expected to be 6310 — so tokens.txt failed
/// verification on every attempt and the feature could never install.
///
/// Served from a local HttpServer so the behaviour is pinned here rather than
/// depending on how a CDN feels today.
void main() {
  // The real tokens.txt shape: highly compressible text.
  final payload = utf8.encode(
      List.generate(652, (i) => '▁token$i $i').join('\n'));

  late HttpServer server;
  late List<String?> seenAcceptEncoding;

  /// [alwaysGzip] models a server that ignores `identity` and compresses
  /// regardless — the case the defensive decode exists for.
  Future<Uri> serve({required bool alwaysGzip}) async {
    seenAcceptEncoding = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final accept = req.headers.value(HttpHeaders.acceptEncodingHeader);
      seenAcceptEncoding.add(accept);
      final wantsGzip = alwaysGzip || (accept?.contains('gzip') ?? false);
      if (wantsGzip) {
        final gzipped = gzip.encode(payload);
        req.response.headers
            .set(HttpHeaders.contentEncodingHeader, 'gzip');
        req.response.headers.contentLength = gzipped.length;
        req.response.add(gzipped);
      } else {
        req.response.headers.contentLength = payload.length;
        req.response.add(payload);
      }
      await req.response.close();
    });
    return Uri.parse('http://${server.address.host}:${server.port}/tokens.txt');
  }

  tearDown(() async => server.close(force: true));

  /// Mirrors ModelDownloadService._dartDownload's request handling. Kept in
  /// step with it deliberately: this is the logic that was wrong.
  Future<List<int>> download(Uri uri) async {
    final client = HttpClient();
    client.autoUncompress = false;
    final req = await client.getUrl(uri);
    req.followRedirects = false;
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final res = await req.close();

    final encoding =
        res.headers.value(HttpHeaders.contentEncodingHeader)?.toLowerCase();
    final compressed = encoding != null && encoding.contains('gzip');
    Stream<List<int>> body = res;
    if (compressed) body = gzip.decoder.bind(body);

    final bytes = <int>[];
    await for (final chunk in body) {
      bytes.addAll(chunk);
    }
    client.close();
    return bytes;
  }

  test('asks the server not to compress', () async {
    final uri = await serve(alwaysGzip: false);
    final bytes = await download(uri);

    expect(seenAcceptEncoding.single, 'identity');
    expect(bytes.length, payload.length);
    expect(bytes, payload);
  });

  test('decodes anyway when the server compresses regardless', () async {
    final uri = await serve(alwaysGzip: true);
    final bytes = await download(uri);

    // The whole bug: without the decode this is the gzip stream's length,
    // and every size/sha check downstream fails.
    expect(bytes.length, payload.length);
    expect(bytes, payload);
    expect(gzip.encode(payload).length, lessThan(payload.length),
        reason: 'the fixture must actually compress or this proves nothing');
  });

  test('the size check that caught it still catches a truncated file',
      () async {
    final model = ModelDownloadService.availableModels
        .firstWhere((m) => m.id == 'live_asr_tokens');
    final dir = await Directory.systemTemp.createTemp('modeldl');
    addTearDown(() => dir.delete(recursive: true));

    final short = File('${dir.path}/tokens.txt')
      ..writeAsBytesSync(gzip.encode(payload));
    expect(ModelDownloadService.fileProblem(model, short), isNotNull,
        reason: 'a gzipped body saved as the file must not pass as installed');

    final missing = File('${dir.path}/nope.txt');
    expect(ModelDownloadService.fileProblem(model, missing), 'file missing');
  });
}
