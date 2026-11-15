// Byte-exact checks against vectors that tool/gen_link_vectors.mjs writes from
// the TypeScript link in ../link/src.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsbot_mobile/link/link.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List unhex(String value) {
  final out = Uint8List(value.length ~/ 2);
  for (var i = 0; i < out.length; i += 1) {
    out[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String hex(List<int> bytes) => bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List Function(int) deterministic(int seed) {
  var counter = 0;
  return (length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i += 1) {
      out[i] = (seed + counter * 31 + i * 13) & 0xff;
    }
    counter += 1;
    return out;
  };
}

void main() {
  final vectors = jsonDecode(File('test/fixtures/link_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final keys = vectors['keys'] as Map<String, dynamic>;
  final phoneKeys = keys['phone'] as Map<String, dynamic>;
  final hostKeys = keys['host'] as Map<String, dynamic>;
  final handshake = vectors['handshake'] as Map<String, dynamic>;
  final transport = vectors['transport'] as Map<String, dynamic>;
  final fragments = vectors['fragments'] as Map<String, dynamic>;

  test('keys, device ids and fingerprints match', () {
    for (final side in [phoneKeys, hostKeys]) {
      final pair = generateKeyPair(fromBase64Url(side['privateKey'] as String));
      expect(pair.publicKey, side['publicKey']);
      expect(deviceIdFor(pair.publicKey), side['deviceId']);
      expect(identityFingerprint(pair.publicKey), side['fingerprint']);
    }
  });

  test('Base64URL round-trips without padding', () {
    for (var length = 0; length < 40; length += 1) {
      final bytes = Uint8List.fromList(List.generate(length, (i) => (i * 53 + 7) & 0xff));
      final encoded = toBase64Url(bytes);
      expect(encoded.contains('='), isFalse);
      expect(fromBase64Url(encoded), bytes);
    }
  });

  test('the prologue matches', () {
    final prologue = createNoisePrologue(vectors['connectionId'] as String, hostKeys['deviceId'] as String, phoneKeys['deviceId'] as String);
    expect(hex(prologue), vectors['prologue']);
  });

  test('the Noise IK handshake and transport messages match byte for byte', () {
    final prologue = unhex(vectors['prologue'] as String);
    final random = vectors['random'] as Map<String, dynamic>;
    final phone = NoiseIkSession(
      initiator: true,
      localPrivateKey: phoneKeys['privateKey'] as String,
      localPublicKey: phoneKeys['publicKey'] as String,
      remotePublicKey: hostKeys['publicKey'] as String,
      prologue: prologue,
      random: deterministic(random['phoneSeed'] as int),
    );
    final host = NoiseIkSession(
      initiator: false,
      localPrivateKey: hostKeys['privateKey'] as String,
      localPublicKey: hostKeys['publicKey'] as String,
      remotePublicKey: phoneKeys['publicKey'] as String,
      prologue: prologue,
      random: deterministic(random['hostSeed'] as int),
    );

    final phoneHello = encodeHandshakeHello(const HandshakeHello(name: 'Pixel 9 Pro', pairingCode: 'Qk3x_9-AbCdEfGhIjKlMnOpQ'));
    expect(hex(phoneHello), handshake['phoneHello']);
    final msg1 = phone.writeHandshake(phoneHello);
    expect(hex(msg1), handshake['msg1']);
    expect(hex(host.readHandshake(msg1)), handshake['readByHost']);

    final msg2 = host.writeHandshake(unhex(handshake['hostHello'] as String));
    expect(hex(msg2), handshake['msg2']);
    expect(hex(phone.readHandshake(msg2)), handshake['readByPhone']);
    expect(phone.complete && host.complete, isTrue);

    final frames = (fragments['frames'] as List).cast<String>();
    for (final (index, step) in (transport['toHost'] as List).cast<Map<String, dynamic>>().indexed) {
      final plain = index == 0 ? unhex(step['plain'] as String) : unhex(frames[index - 1]);
      expect(hex(phone.encrypt(plain)), step['cipher']);
      expect(hex(host.decrypt(unhex(step['cipher'] as String))), hex(plain));
    }
    for (final step in (transport['toPhone'] as List).cast<Map<String, dynamic>>()) {
      final plain = unhex(step['plain'] as String);
      expect(hex(host.encrypt(plain)), step['cipher']);
      expect(hex(phone.decrypt(unhex(step['cipher'] as String))), hex(plain));
    }
  });

  test('a phone holding the wrong computer key fails the handshake', () {
    final prologue = unhex(vectors['prologue'] as String);
    final wrong = generateKeyPair();
    final phone = NoiseIkSession(
      initiator: true,
      localPrivateKey: phoneKeys['privateKey'] as String,
      localPublicKey: phoneKeys['publicKey'] as String,
      remotePublicKey: wrong.publicKey,
      prologue: prologue,
    );
    final host = NoiseIkSession(
      initiator: false,
      localPrivateKey: hostKeys['privateKey'] as String,
      localPublicKey: hostKeys['publicKey'] as String,
      remotePublicKey: phoneKeys['publicKey'] as String,
      prologue: prologue,
    );
    expect(() => host.readHandshake(phone.writeHandshake()), throwsA(isA<NoiseSessionError>()));
  });

  test('handshake messages out of order are refused', () {
    final phone = NoiseIkSession(
      initiator: true,
      localPrivateKey: phoneKeys['privateKey'] as String,
      localPublicKey: phoneKeys['publicKey'] as String,
      remotePublicKey: hostKeys['publicKey'] as String,
      prologue: unhex(vectors['prologue'] as String),
    );
    expect(
      () => phone.readHandshake(Uint8List(48)),
      throwsA(isA<NoiseSessionError>().having((error) => error.code, 'code', 'NOISE_HANDSHAKE_ORDER')),
    );
  });

  test('a low-order public key is refused', () {
    final zero = Uint8List(32);
    expect(() => x25519(fromBase64Url(phoneKeys['privateKey'] as String), zero), throwsStateError);
  });

  test('fragments match and reassemble', () {
    final length = fragments['length'] as int;
    final message = Uint8List.fromList(List.generate(length, (i) => (i * 37 + 11) & 0xff));
    final encoded = SecureMessageCodec().encode(message);
    expect(encoded.map(hex).toList(), fragments['frames']);
    final decoder = SecureMessageCodec();
    Uint8List? whole;
    for (final frame in encoded) {
      whole = decoder.decode(frame);
    }
    expect(whole, message);
    expect(SecureMessageCodec().decode(Uint8List.fromList(utf8.encode('{}'))), utf8.encode('{}'));
  });

  test('fragments out of order are refused', () {
    final message = Uint8List(200000);
    final frames = SecureMessageCodec().encode(message);
    expect(frames.length, 5);
    expect(() => SecureMessageCodec().decode(frames[1]), throwsFormatException);
  });

  test('control frames encode to the same JSON text', () {
    for (final item in (vectors['frames'] as List).cast<Map<String, dynamic>>()) {
      final frame = item['frame'] as Map<String, dynamic>;
      final envelope = Envelope(
        frame['type'] as String,
        (frame['payload'] as Map).cast<String, Object?>(),
        id: frame['id'] as String,
        timestamp: frame['timestamp'] as num,
      );
      expect(encodeControlFrame(envelope), item['encoded']);
      expect(decodeControlFrame(item['encoded'] as String).toJson(), frame);
    }
  });

  test('control frame size limits apply', () {
    final big = Envelope('pong', {'nonce': 'x' * (70 * 1024)});
    expect(() => encodeControlFrame(big), throwsFormatException);
    final relay = Envelope('relay', {'ciphertext': 'x' * 2000});
    expect(() => encodeControlFrame(relay, const FrameLimits(maxRelayFrameBytes: 1000)), throwsFormatException);
  });

  test('the pairing link round-trips and is checked', () {
    final pairing = vectors['pairing'] as Map<String, dynamic>;
    final offer = pairing['offer'] as Map<String, dynamic>;
    final parsed = parsePairingUri(pairing['uri'] as String);
    expect(parsed.server, offer['server']);
    expect(parsed.hostDeviceId, offer['hostDeviceId']);
    expect(parsed.hostKey, offer['hostKey']);
    expect(parsed.code, offer['code']);
    expect(parsed.name, offer['name']);
    expect(pairingUri(parsed), pairing['uri']);

    final tampered = (pairing['uri'] as String).replaceFirst('host=d-', 'host=d-x');
    expect(() => parsePairingUri(tampered), throwsFormatException);
    expect(() => parsePairingUri('https://example.test/pair?v=1'), throwsFormatException);
    final http = (pairing['uri'] as String).replaceFirst('wss%3A', 'https%3A');
    expect(() => parsePairingUri(http), throwsFormatException);
  });

  test('handshake hellos are checked', () {
    expect(utf8.decode(encodeHandshakeHello(const HandshakeHello())), '{}');
    expect(decodeHandshakeHello(const []).name, isNull);
    expect(() => encodeHandshakeHello(HandshakeHello(name: 'n' * 65)), throwsFormatException);
    expect(() => decodeHandshakeHello(utf8.encode('[1]')), throwsFormatException);
    expect(() => decodeHandshakeHello(utf8.encode('{"pairingCode":""}')), throwsFormatException);
  });
}
