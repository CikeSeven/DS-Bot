// The Dart link against the real Relay Server and computer side from ../link,
// started by tool/link_test_host.mjs. Needs Node and `npm ci` in ../link.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsbot_mobile/link/link.dart';
import 'package:flutter_test/flutter_test.dart';

class TestHost {
  TestHost._(this._process, this._lines);

  final Process _process;
  final StreamIterator<String> _lines;
  late final String url;
  late final String hostDeviceId;
  late final String hostKey;

  static Future<TestHost> start() async {
    final process = await Process.start('node', ['tool/link_test_host.mjs']);
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    final lines = StreamIterator(process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    final host = TestHost._(process, lines);
    final ready = (await host._next())['ready'] as Map<String, dynamic>;
    host.url = ready['url'] as String;
    host.hostDeviceId = ready['hostDeviceId'] as String;
    host.hostKey = ready['hostKey'] as String;
    return host;
  }

  Future<Map<String, dynamic>> _next() async {
    if (!await _lines.moveNext().timeout(const Duration(seconds: 20))) throw StateError('test host ended');
    return jsonDecode(_lines.current) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> command(Map<String, Object?> command) async {
    _process.stdin.writeln(jsonEncode(command));
    return _next();
  }

  Future<String> pairingCode() async => ((await command({'cmd': 'pair'}))['pair'] as Map)['code'] as String;

  Future<void> stop() async {
    await _process.stdin.close();
    await _process.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      _process.kill();
      return -1;
    });
  }
}

class Phone {
  Phone(this.identity, this.token);

  factory Phone.fresh() {
    final keys = generateKeyPair();
    return Phone(
      DeviceIdentity(deviceId: deviceIdFor(keys.publicKey), publicKey: keys.publicKey, privateKey: keys.privateKey),
      randomToken(),
    );
  }

  final DeviceIdentity identity;
  final String token;

  ({RpcClient client, SecureTransport secure}) open(TestHost host, {String? code, String? hostKey}) {
    final relay = RelayTransport(
      host.url,
      RelayTransportOptions(
        deviceId: identity.deviceId,
        identityKey: identity.publicKey,
        accessToken: token,
        targetDeviceId: host.hostDeviceId,
      ),
    );
    final secure = SecureTransport(
      relay,
      identity,
      PairedHost(deviceId: host.hostDeviceId, identityKey: hostKey ?? host.hostKey),
      hello: HandshakeHello(name: 'Test phone', pairingCode: code),
      handshakeTimeout: const Duration(seconds: 3),
    );
    return (client: RpcClient(secure, timeout: const Duration(seconds: 8)), secure: secure);
  }
}

void main() {
  late TestHost host;

  setUpAll(() async {
    host = await TestHost.start();
  });

  tearDownAll(() async {
    await host.stop();
  });

  test('a phone pairs with the code, calls, sends a large message and comes back without the code', () async {
    final phone = Phone.fresh();
    final code = await host.pairingCode();
    final first = phone.open(host, code: code);
    await first.client.connect();
    expect(first.secure.hostHello?.name, 'Desk');
    expect(await first.client.rpc('bot', {'endpoint': 'state'}), {
      'method': 'bot',
      'params': {'endpoint': 'state'},
      'deviceId': phone.identity.deviceId,
    });
    final big = 'z' * 300000;
    final echoed = await first.client.rpc('bot', {'big': big}) as Map<String, dynamic>;
    expect((echoed['params'] as Map)['big'], big);
    await first.client.close();

    final again = phone.open(host);
    await again.client.connect();
    expect(((await again.client.rpc('ping', null)) as Map)['method'], 'ping');
    await again.client.close();
  });

  test('an unpaired phone and a wrong code are refused with NOT_PAIRED', () async {
    await expectLater(
      Phone.fresh().open(host).client.connect(),
      throwsA(isA<LinkError>().having((error) => error.code, 'code', 'NOT_PAIRED')),
    );
    await host.pairingCode();
    await expectLater(
      Phone.fresh().open(host, code: 'wrong').client.connect(),
      throwsA(isA<LinkError>().having((error) => error.code, 'code', 'NOT_PAIRED')),
    );
  });

  test('a phone holding the wrong computer key cannot connect', () async {
    final code = await host.pairingCode();
    await expectLater(Phone.fresh().open(host, code: code, hostKey: generateKeyPair().publicKey).client.connect(), throwsA(anything));
  });

  test('computer errors keep their code and events arrive', () async {
    final phone = Phone.fresh();
    final link = phone.open(host, code: await host.pairingCode());
    await link.client.connect();
    final events = <RpcEvent>[];
    link.client.onEvent(events.add);
    await expectLater(link.client.rpc('fail', null), throwsA(isA<LinkError>().having((error) => error.code, 'code', 'bot/refused')));
    await host.command({'cmd': 'emit', 'event': 'revision', 'data': {'revision': 9}});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(events.single.event, 'revision');
    expect(events.single.data, {'revision': 9});
    await link.client.close();
  });

  test('a removed phone is cut off and refused afterwards', () async {
    final phone = Phone.fresh();
    final link = phone.open(host, code: await host.pairingCode());
    await link.client.connect();
    final closed = Completer<void>();
    link.client.onClose(() {
      if (!closed.isCompleted) closed.complete();
    });
    await host.command({'cmd': 'revoke', 'id': phone.identity.deviceId});
    await closed.future.timeout(const Duration(seconds: 5));
    await expectLater(
      phone.open(host).client.connect(),
      throwsA(isA<LinkError>().having((error) => error.code, 'code', 'NOT_PAIRED')),
    );
  });

  test('a call pending when the link drops fails with TRANSPORT_CLOSED, and HOST_OFFLINE is reported', () async {
    final phone = Phone.fresh();
    final link = phone.open(host, code: await host.pairingCode());
    await link.client.connect();
    final slow = link.client.rpc('slow', null);
    await host.command({'cmd': 'stop-host'});
    await expectLater(slow, throwsA(isA<LinkError>().having((error) => error.code, 'code', 'TRANSPORT_CLOSED')));
    await expectLater(
      phone.open(host).client.connect(),
      throwsA(isA<LinkError>().having((error) => error.code, 'code', 'HOST_OFFLINE')),
    );
    await host.command({'cmd': 'start-host'});
    final back = phone.open(host);
    await back.client.connect();
    expect(((await back.client.rpc('ping', null)) as Map)['method'], 'ping');
    await back.client.close();
  });
}
