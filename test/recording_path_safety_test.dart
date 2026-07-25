import 'package:flutter_test/flutter_test.dart';
import 'package:castcircle/data/services/recording_sync_service.dart';

/// recordings.line_id is free TEXT in the cloud schema, so a hostile row can
/// carry path-traversal payloads that every castmate's device would otherwise
/// write to disk.
void main() {
  test('accepts normal uuid line ids', () {
    expect(
        RecordingSyncService.isSafePathId(
            'd46cafee-3bb8-46ee-b733-54938254f106'),
        isTrue);
    expect(RecordingSyncService.isSafePathId('line_1'), isTrue);
  });

  test('rejects traversal and absolute payloads', () {
    for (final hostile in [
      '../../evil',
      '..',
      'a/../../b',
      '/etc/passwd',
      'sub/dir',
      r'back\slash',
      'has space',
      '',
    ]) {
      expect(RecordingSyncService.isSafePathId(hostile), isFalse,
          reason: 'must reject $hostile');
    }
  });
}
