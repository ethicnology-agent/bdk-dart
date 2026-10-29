import 'dart:typed_data';

import 'package:bdk_dart/bdk.dart';
import 'package:test/test.dart';

void main() {
  for (final syncedToTip in [false, true]) {
    test(
      'polling batch codec preserves ${syncedToTip ? 'tip' : 'partial'} progress',
      () {
        final hash = BlockHash.fromString(
          hex:
              '000000000000000000003041727bb21a7c2f94d67a061357320fc9232ef28531',
        );
        final batch = CbfUpdateBatch(
          updates: {},
          scannedTip: BlockId(height: 973434, hash: hash),
          syncedToTip: syncedToTip,
        );
        try {
          // Exercise the generated native record wire format, including the
          // BlockHash handle, rather than only constructing a Dart record.
          final bytes = Uint8List(
            FfiConverterCbfUpdateBatch.allocationSize(batch),
          );
          expect(FfiConverterCbfUpdateBatch.write(batch, bytes), bytes.length);
          final decoded = FfiConverterCbfUpdateBatch.read(bytes);
          try {
            expect(decoded.bytesRead, bytes.length);
            expect(decoded.value.updates, isEmpty);
            expect(decoded.value.scannedTip.height, 973434);
            expect(decoded.value.scannedTip.hash.toString(), hash.toString());
            expect(decoded.value.syncedToTip, syncedToTip);
          } finally {
            decoded.value.scannedTip.hash.dispose();
          }
        } finally {
          hash.dispose();
        }
      },
    );
  }
}
