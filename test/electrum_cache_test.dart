import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:bdk_dart/bdk.dart';
import 'package:test/test.dart';

// Version 2, one input spending 00…00:0, one 1 000 sat P2WPKH output.
final _rawTx = Uint8List.fromList([
  2, 0, 0, 0, //
  1, ...List.filled(32, 0), 0, 0, 0, 0, 1, 0x51, 0xff, 0xff, 0xff, 0xff, //
  1, 0xe8, 0x03, 0, 0, 0, 0, 0, 0, 22, 0x00, 0x14, ...List.filled(20, 0xab), //
  0, 0, 0, 0,
]);

/// Loopback Electrum server answering version negotiation and raw
/// transaction requests. It runs in its own isolate because the client's
/// calls block the calling isolate until the server replies.
class _ElectrumStub {
  final Isolate _isolate;
  final SendPort _control;
  final int port;

  _ElectrumStub(this._isolate, this._control, this.port);

  static Future<_ElectrumStub> start() async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_serve, ready.sendPort);
    final [control as SendPort, port as int] = await ready.first as List;
    return _ElectrumStub(isolate, control, port);
  }

  String get url => 'tcp://127.0.0.1:$port';

  /// Number of `blockchain.transaction.get` requests served so far.
  Future<int> transactionGets() async {
    final reply = ReceivePort();
    _control.send(reply.sendPort);
    return await reply.first as int;
  }

  void close() => _isolate.kill(priority: Isolate.immediate);

  static Future<void> _serve(SendPort ready) async {
    var transactionGets = 0;
    final hex = _rawTx.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    Object answer(Object? request) {
      if (request is List) return request.map(answer).toList();
      final call = request as Map<String, dynamic>;
      final result = switch (call['method']) {
        'server.version' => ['stub', '1.4'],
        'blockchain.transaction.get' => (() {
          transactionGets++;
          return hex;
        })(),
        _ => null,
      };
      return {'jsonrpc': '2.0', 'id': call['id'], 'result': result};
    }

    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .listen(
            (line) => socket.write('${jsonEncode(answer(jsonDecode(line)))}\n'),
          );
    });
    final control = ReceivePort();
    control.listen((reply) => (reply as SendPort).send(transactionGets));
    ready.send([control.sendPort, server.port]);
  }
}

ElectrumClient _client(_ElectrumStub stub) => ElectrumClient(
  url: stub.url,
  socks5: null,
  timeout: 5,
  retry: 0,
  validateDomain: false,
);

void main() {
  group('ElectrumClient cache prefill', () {
    late _ElectrumStub stub;
    late Transaction tx;

    setUp(() async {
      stub = await _ElectrumStub.start();
      tx = Transaction(transactionBytes: _rawTx);
    });

    tearDown(() => stub.close());

    test('fetchTx downloads a transaction the client has not seen', () async {
      final client = _client(stub);
      final fetched = client.fetchTx(txid: tx.computeTxid());
      expect(fetched.computeTxid().toString(), tx.computeTxid().toString());
      expect(await stub.transactionGets(), 1);
    });

    test('populateTxCache lets fetchTx answer without a request', () async {
      final client = _client(stub);
      client.populateTxCache(transactions: [tx]);
      final fetched = client.fetchTx(txid: tx.computeTxid());
      expect(fetched.computeTxid().toString(), tx.computeTxid().toString());
      expect(await stub.transactionGets(), 0);
    });

    test('populateAnchorCache accepts an anchor without a request', () async {
      final client = _client(stub);
      client.populateAnchorCache(
        anchors: [
          TxAnchor(
            txid: tx.computeTxid(),
            anchor: ConfirmationBlockTime(
              blockId: BlockId(
                height: 1,
                hash: BlockHash.fromBytes(bytes: Uint8List(32)),
              ),
              confirmationTime: 1296689202,
            ),
          ),
        ],
      );
      expect(await stub.transactionGets(), 0);
    });
  });
}
