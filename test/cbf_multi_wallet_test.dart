import 'package:bdk_dart/bdk.dart';
import 'package:test/test.dart';

// Public BIP84 account-0 xpub only. Distinct branch pairs identify two wallets.
const _account =
    '[73c5da0a/84h/0h/0h]xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V';

class _PublicWallet {
  final Descriptor external;
  final Descriptor internal;
  final Persister persister;
  final Wallet wallet;

  _PublicWallet._(this.external, this.internal, this.persister, this.wallet);

  factory _PublicWallet(int branch) {
    final external = Descriptor(
      descriptor: 'wpkh($_account/$branch/*)',
      networkKind: NetworkKind.main,
    );
    final internal = Descriptor(
      descriptor: 'wpkh($_account/${branch + 1}/*)',
      networkKind: NetworkKind.main,
    );
    final persister = Persister.newInMemory();
    final wallet = Wallet(
      descriptor: external,
      changeDescriptor: internal,
      network: Network.bitcoin,
      persister: persister,
      lookahead: 1000,
    );
    return _PublicWallet._(external, internal, persister, wallet);
  }

  void dispose() {
    wallet.dispose();
    persister.dispose();
    internal.dispose();
    external.dispose();
  }
}

void main() {
  test(
    'multi-wallet node accepts a birthday checkpoint and stops before run',
    () async {
      final recovering = _PublicWallet(0);
      final other = _PublicWallet(2);
      final hash = BlockHash.fromString(
        hex: '000000000000000000003041727bb21a7c2f94d67a061357320fc9232ef28531',
      );
      final checkpoint = BlockId(height: 973434, hash: hash);
      final initial = CbfBuilder();
      final builder = initial.onlyConfiguredPeers();
      CbfComponents? components;
      try {
        recovering.wallet.insertCheckpoint(blockId: checkpoint);
        expect(recovering.wallet.latestCheckpoint().height, checkpoint.height);
        final recoveringId = recovering.wallet.descriptorId(
          keychain: KeychainKind.external_,
        );
        final otherId = other.wallet.descriptorId(
          keychain: KeychainKind.external_,
        );
        expect(recoveringId, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(otherId, isNot(recoveringId));

        final built = builder.buildWithWallets(
          wallets: [recovering.wallet, other.wallet],
        );
        components = built;
        expect(await built.node.awaitTermination(timeoutMillis: 0), isFalse);
        await expectLater(built.client.update(), throwsA(isA<CbfException>()));
        built.client.shutdown();
        expect(await built.node.awaitTermination(timeoutMillis: 1000), isTrue);
        built.node.run();
        expect(built.client.isRunning(), isFalse);
      } finally {
        if (components != null) {
          try {
            components.client.shutdown();
          } on NodeStoppedCbfException {
            // Shutdown preserves the closed-channel contract after termination.
          }
          await components.node.awaitTermination(timeoutMillis: 1000);
          components.client.dispose();
          components.node.dispose();
        }
        builder.dispose();
        initial.dispose();
        hash.dispose();
        other.dispose();
        recovering.dispose();
      }
    },
  );

  test('multi-wallet builder rejects empty and duplicate wallet sets', () {
    final public = _PublicWallet(0);
    final builder = CbfBuilder();
    try {
      expect(
        () => builder.buildWithWallets(wallets: []),
        throwsA(isA<CbfException>()),
      );
      expect(
        () => builder.buildWithWallets(wallets: [public.wallet, public.wallet]),
        throwsA(isA<CbfException>()),
      );
    } finally {
      builder.dispose();
      public.dispose();
    }
  });

  test(
    'multi-wallet recovery uses wallet checkpoints rather than ScanType',
    () {
      final public = _PublicWallet(0);
      final builder = CbfBuilder();
      final recovery = builder.scanType(
        scanType: RecoveryScanType(
          usedScriptIndex: 1000,
          checkpoint: GenesisBlockRecoveryPoint(),
        ),
      );
      try {
        expect(
          () => recovery.buildWithWallets(wallets: [public.wallet]),
          throwsA(isA<CbfException>()),
        );
      } finally {
        recovery.dispose();
        builder.dispose();
        public.dispose();
      }
    },
  );
}
