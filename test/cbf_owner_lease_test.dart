import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:bdk_dart/bdk.dart' as bdk;
import 'package:test/test.dart';

// Public BIP84 account-0 descriptors; no signing material or internet peers.
const _account =
    '[73c5da0a/84h/0h/0h]xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V';
const _ttlMillis = 500;

bdk.CbfComponents _components(int port, {required bool leased}) {
  final external = bdk.Descriptor(
    descriptor: 'wpkh($_account/0/*)',
    networkKind: bdk.NetworkKind.main,
  );
  final internal = bdk.Descriptor(
    descriptor: 'wpkh($_account/1/*)',
    networkKind: bdk.NetworkKind.main,
  );
  final persister = bdk.Persister.newInMemory();
  final wallet = bdk.Wallet(
    descriptor: external,
    changeDescriptor: internal,
    network: bdk.Network.bitcoin,
    persister: persister,
    lookahead: 25,
  );
  var builder = bdk.CbfBuilder();
  void replace(bdk.CbfBuilder next) {
    builder.dispose();
    builder = next;
  }

  final address = bdk.IpAddress.fromIpv4(q1: 127, q2: 0, q3: 0, q4: 1);
  try {
    replace(builder.connections(connections: 1));
    replace(builder.configureTimeoutMillis(handshake: 60000, response: 60000));
    replace(builder.onlyConfiguredPeers());
    replace(
      builder.peers(
        peers: [bdk.Peer(address: address, port: port, v2Transport: false)],
      ),
    );
    if (leased) {
      replace(builder.ownerLeaseMillis(ttlMillis: _ttlMillis));
    }
    return builder.buildWithWallets(wallets: [wallet]);
  } finally {
    address.dispose();
    builder.dispose();
    wallet.dispose();
    persister.dispose();
    internal.dispose();
    external.dispose();
  }
}

void _owner(Map<String, Object> parameters) {
  final ready = parameters['ready'] as SendPort;
  final heartbeat = parameters['heartbeat'] as SendPort;
  final components = _components(parameters['port'] as int, leased: true);
  components.node.run();
  // The node wrapper remains exclusively in this isolate, as in the reviewer's
  // reproduction. Only the client's native Arc is cloned for parent cleanup.
  ready.send(components.client.uniffiClonePointer().address);
  // Every native operation in this timer is synchronous: killing this isolate
  // leaves no foreign future with a callback address belonging to its Dart VM.
  Timer.periodic(const Duration(milliseconds: 40), (_) {
    components.client.renewLease();
    final updates = components.client.pollUpdates();
    if (updates != null) {
      for (final update in updates.values) {
        update.dispose();
      }
    }
    for (final info in components.client.drainInfo()) {
      if (info is bdk.SyncedInfo) info.tip.hash.dispose();
    }
    components.client.drainWarnings();
    components.client.status().syncedTip?.hash.dispose();
    heartbeat.send(null);
  });
}

Future<Set<String>> _nativeNodeThreads() async {
  final threads = <String>{};
  await for (final task in Directory('/proc/self/task').list()) {
    try {
      if ((await File('${task.path}/comm').readAsString()).trim() ==
          'bdk-cbf') {
        threads.add(task.path);
      }
    } on FileSystemException {
      // A thread can disappear between listing /proc and reading its name.
    }
  }
  return threads;
}

Future<void> _until(bool Function() predicate) async {
  final deadline = Stopwatch()..start();
  while (!predicate()) {
    if (deadline.elapsed > const Duration(seconds: 3)) {
      fail('native node did not acknowledge termination');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _LocalPeer {
  final ServerSocket server;
  final connected = Completer<void>();
  final closed = Completer<void>();
  final sockets = <Socket>[];
  late final StreamSubscription<Socket> listener;

  _LocalPeer(this.server) {
    listener = server.listen((socket) {
      sockets.add(socket);
      socket.listen(
        (_) {},
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object error) {
          if (!closed.isCompleted) closed.completeError(error);
        },
      );
      if (!connected.isCompleted) connected.complete();
    });
  }

  Future<void> dispose() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await listener.cancel();
    await server.close();
  }
}

void _shutdown(bdk.CbfClient client) {
  try {
    client.shutdown();
  } on bdk.NodeStoppedCbfException {
    // The lease or an earlier explicit shutdown may already have closed it.
  }
}

void main() {
  for (final explicitShutdown in [false, true]) {
    test(
      explicitShutdown
          ? 'explicit shutdown after owner death has no stale Dart callback'
          : 'renewed node loses its peer and thread after owner lease expiry',
      () async {
        final before = await _nativeNodeThreads();
        final peer = _LocalPeer(
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        );
        final ready = ReceivePort();
        final exited = ReceivePort();
        final heartbeat = ReceivePort();
        var ticks = 0;
        final ticksSubscription = heartbeat.listen((_) => ticks++);
        Isolate? owner;
        bdk.CbfClient? client;
        try {
          owner = await Isolate.spawn(
            _owner,
            <String, Object>{
              'ready': ready.sendPort,
              'heartbeat': heartbeat.sendPort,
              'port': peer.server.port,
            },
            onExit: exited.sendPort,
            errorsAreFatal: true,
          );
          final pointer =
              await ready.first.timeout(const Duration(seconds: 10)) as int;
          client = bdk.CbfClient.lift(Pointer<Void>.fromAddress(pointer));
          await peer.connected.future.timeout(const Duration(seconds: 5));
          // More than three TTLs pass with renewals from the owning isolate.
          await Future<void>.delayed(const Duration(milliseconds: 1700));
          expect(ticks, greaterThan(10));
          expect(client.status().running, isTrue);
          expect(client.status().terminated, isFalse);
          expect((await _nativeNodeThreads()).difference(before), hasLength(1));
          final elapsed = Stopwatch()..start();
          owner.kill(priority: Isolate.immediate);
          await exited.first.timeout(const Duration(seconds: 5));
          if (explicitShutdown) {
            expect(elapsed.elapsedMilliseconds, lessThan(_ttlMillis));
            _shutdown(client);
          }
          await _until(() => client!.status().terminated);
          await peer.closed.future.timeout(const Duration(seconds: 1));
          expect(
            elapsed.elapsedMilliseconds,
            lessThanOrEqualTo(_ttlMillis + 250),
            reason:
                'lease deadline plus bounded scheduler/observation tolerance',
          );
          expect(await _nativeNodeThreads(), before);
          final status = client.status();
          expect(status.running, isFalse);
          expect(status.terminated, isTrue);
          if (!explicitShutdown) {
            expect(status.lastError, contains('lease'));
          }
          // Still synchronous after owner death, including repeated shutdown.
          expect(client.pollUpdates(), isNull);
          client.drainInfo();
          client.drainWarnings();
          _shutdown(client);
          print(
            'owner death: explicit=$explicitShutdown, '
            'termination=${elapsed.elapsedMilliseconds}ms, ticks=$ticks',
          );
        } finally {
          owner?.kill(priority: Isolate.immediate);
          if (client != null) {
            _shutdown(client);
            await _until(() => client!.status().terminated);
          }
          client?.dispose();
          await peer.dispose();
          await ticksSubscription.cancel();
          heartbeat.close();
          ready.close();
          exited.close();
          expect(await _nativeNodeThreads(), before);
        }
      },
      skip: !Platform.isLinux
          ? 'thread acknowledgement uses Linux /proc'
          : false,
    );
  }

  test('leased clients reject legacy receivers before they can wait', () async {
    final components = _components(1, leased: true);
    try {
      expect(components.client.pollUpdates(), isNull);
      expect(components.client.drainInfo(), isEmpty);
      expect(components.client.drainWarnings(), isEmpty);
      final rejectsLegacy = throwsA(
        isA<bdk.InvalidConfigurationCbfException>(),
      );
      await expectLater(components.client.update(), rejectsLegacy);
      await expectLater(components.client.updates(), rejectsLegacy);
      await expectLater(components.client.nextInfo(), rejectsLegacy);
      await expectLater(components.client.nextWarning(), rejectsLegacy);
      expect(components.node.isTerminated(), isFalse);
      _shutdown(components.client);
      expect(components.node.isTerminated(), isTrue);
    } finally {
      _shutdown(components.client);
      components.client.dispose();
      components.node.dispose();
    }
  });

  test(
    'legacy pending receivers still finish during live-owner shutdown',
    () async {
      final components = _components(1, leased: false);
      Future<void> finishes(Future<Object?> result) async {
        try {
          await result.timeout(const Duration(seconds: 3));
        } on bdk.NodeStoppedCbfException {
          // Live-owner callbacks safely deliver the existing stopped error.
        }
      }

      try {
        final pending = [
          finishes(components.client.updates()),
          finishes(components.client.nextInfo()),
          finishes(components.client.nextWarning()),
        ];
        _shutdown(components.client);
        await Future.wait(pending);
        expect(
          await components.node.awaitTermination(timeoutMillis: 1000),
          isTrue,
        );
      } finally {
        _shutdown(components.client);
        components.client.dispose();
        components.node.dispose();
      }
    },
  );
}
