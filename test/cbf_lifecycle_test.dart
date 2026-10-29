import 'package:bdk_dart/bdk.dart';
import 'package:test/test.dart';

// Public BIP84 account-0 descriptors; this fixture contains no signing material.
const _external =
    "wpkh([73c5da0a/84h/0h/0h]xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V/0/*)";
const _internal =
    "wpkh([73c5da0a/84h/0h/0h]xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V/1/*)";

void main() {
  group('CBF public wallet contract', () {
    late Descriptor external;
    late Descriptor internal;
    late Persister persister;
    late Wallet wallet;

    setUp(() {
      external = Descriptor(
        descriptor: _external,
        networkKind: NetworkKind.main,
      );
      internal = Descriptor(
        descriptor: _internal,
        networkKind: NetworkKind.main,
      );
      persister = Persister.newInMemory();
      wallet = Wallet(
        descriptor: external,
        changeDescriptor: internal,
        network: Network.bitcoin,
        persister: persister,
        lookahead: 25,
      );
    });

    tearDown(() {
      wallet.dispose();
      persister.dispose();
      internal.dispose();
      external.dispose();
    });

    final exactHash =
        '000000000000000000003041727bb21a7c2f94d67a061357320fc9232ef28531';

    for (final label in [
      'sync',
      'SegWit recovery',
      'exact checkpoint recovery',
      'saved checkpoint recovery',
    ]) {
      test('$label supports acknowledged shutdown before run', () async {
        final hash = BlockHash.fromString(hex: exactHash);
        final scanType = switch (label) {
          'sync' => SyncScanType(),
          'SegWit recovery' => RecoveryScanType(
            usedScriptIndex: 100,
            checkpoint: SegwitActivationRecoveryPoint(),
          ),
          'saved checkpoint recovery' => RecoveryScanType(
            usedScriptIndex: 100,
            checkpoint: LastCheckpointRecoveryPoint(),
          ),
          _ => RecoveryScanType(
            usedScriptIndex: 100,
            checkpoint: OtherRecoveryPoint(BlockId(height: 973434, hash: hash)),
          ),
        };
        if (label == 'saved checkpoint recovery') {
          wallet.insertCheckpoint(blockId: BlockId(height: 973434, hash: hash));
        }
        final initial = CbfBuilder();
        final configured = initial.scanType(scanType: scanType);
        final peersOnly = configured.onlyConfiguredPeers();
        final components = peersOnly.build(wallet: wallet);
        try {
          expect(
            await components.node.awaitTermination(timeoutMillis: 0),
            isFalse,
          );
          components.client.shutdown();
          expect(
            await components.node.awaitTermination(timeoutMillis: 1000),
            isTrue,
          );
          // A stopped node cannot restart networking, including on repeat run.
          components.node.run();
          components.node.run();
          expect(
            await components.node.awaitTermination(timeoutMillis: 0),
            isTrue,
          );
          expect(components.client.isRunning(), isFalse);
        } finally {
          try {
            components.client.shutdown();
          } on NodeStoppedCbfException {
            // Shutdown preserves its existing closed-channel error contract.
          }
          await components.node.awaitTermination(timeoutMillis: 1000);
          components.client.dispose();
          components.node.dispose();
          peersOnly.dispose();
          configured.dispose();
          initial.dispose();
          hash.dispose();
        }
      });
    }
  });
}
