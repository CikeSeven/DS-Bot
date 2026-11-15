// Port of link/src/keys.ts: X25519 identities, device ids and Base64URL.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

class KeyPair {
  const KeyPair({required this.publicKey, required this.privateKey});

  final String publicKey;
  final String privateKey;
}

const _x25519 = DartX25519();
final _random = Random.secure();

Uint8List randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i += 1) {
    out[i] = _random.nextInt(256);
  }
  return out;
}

/// The private key is kept as the raw 32 random bytes; clamping happens inside
/// each scalar multiplication, the same as @noble/curves.
KeyPair generateKeyPair([Uint8List? privateKeyBytes]) {
  final privateKey = privateKeyBytes ?? randomBytes(32);
  if (privateKey.length != 32) {
    throw ArgumentError('X25519 private keys must be 32 bytes');
  }
  return KeyPair(
    privateKey: toBase64Url(privateKey),
    publicKey: toBase64Url(x25519PublicKey(privateKey)),
  );
}

final Uint8List _basePoint = () {
  final point = Uint8List(32);
  point[0] = 9;
  return point;
}();

Uint8List x25519PublicKey(Uint8List privateKey) => x25519(privateKey, _basePoint, checkLowOrder: false);

/// Diffie-Hellman that refuses an all-zero result, which every low-order or
/// small-subgroup public key produces once the scalar is clamped.
Uint8List x25519(Uint8List privateKey, Uint8List publicKey, {bool checkLowOrder = true}) {
  if (privateKey.length != 32 || publicKey.length != 32) {
    throw ArgumentError('X25519 keys must be 32 bytes');
  }
  final pair = SimpleKeyPairData(
    privateKey,
    publicKey: SimplePublicKey(Uint8List(32), type: KeyPairType.x25519),
    type: KeyPairType.x25519,
  );
  final secret = _x25519.sharedSecretSync(
    keyPairData: pair,
    remotePublicKey: SimplePublicKey(publicKey, type: KeyPairType.x25519),
  ) as SecretKeyData;
  final out = Uint8List.fromList(secret.bytes);
  if (checkLowOrder && out.every((byte) => byte == 0)) {
    throw StateError('X25519 produced an all-zero shared secret');
  }
  return out;
}

/// Short code both screens show at pairing, so the user can see they hold the same key.
String identityFingerprint(String publicKey) {
  final digest = sha256.convert(fromBase64Url(publicKey)).bytes.sublist(0, 6);
  return digest.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}

/// A device's id is derived from its identity key, so the Server can check one against the other.
String deviceIdFor(String publicKey) {
  final key = fromBase64Url(publicKey);
  if (key.length != 32) throw ArgumentError('X25519 public keys must be 32 bytes');
  return 'd-${toBase64Url(Uint8List.fromList(sha256.convert(key).bytes.sublist(0, 16)))}';
}

String randomToken([int bytes = 32]) => toBase64Url(randomBytes(bytes));

/// RFC 4122 version 4, the same shape as crypto.randomUUID().
String randomUuid() {
  final bytes = randomBytes(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String toBase64Url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List fromBase64Url(String value) {
  final normalized = value.replaceAll('+', '-').replaceAll('/', '_');
  final padded = normalized.padRight((normalized.length + 3) ~/ 4 * 4, '=');
  return base64Url.decode(padded);
}
