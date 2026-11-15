// Port of link/src/noise.ts, with the Noise core written out for one fixed
// suite: Noise_IK_25519_ChaChaPoly_SHA256 (Noise spec rev 34).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'keys.dart';

const noiseIkProtocol = 'Noise_IK_25519_ChaChaPoly_SHA256';

/// One Noise transport message holds at most 65,535 bytes, tag included.
const noiseMaxMessage = 65535;
const _tagBytes = 16;
const _dhBytes = 32;
const _maxNonce = 0xfffffffffffffff; // clatterjs stops at 2^60-1

class NoiseSessionError implements Exception {
  NoiseSessionError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'NoiseSessionError($code): $message';
}

const _aead = DartChacha20.poly1305Aead();

Uint8List _concat(List<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  for (final part in parts) {
    out.add(part);
  }
  return out.toBytes();
}

Uint8List _hmac(List<int> key, List<int> data) =>
    Uint8List.fromList(hash.Hmac(hash.sha256, key).convert(data).bytes);

Uint8List _sha256(List<int> data) => Uint8List.fromList(hash.sha256.convert(data).bytes);

List<Uint8List> _hkdf(List<int> chainingKey, List<int> input) {
  final temp = _hmac(chainingKey, input);
  final out1 = _hmac(temp, const [1]);
  final out2 = _hmac(temp, [...out1, 2]);
  return [out1, out2];
}

Uint8List _nonce(int n) {
  final nonce = Uint8List(12);
  final view = ByteData.sublistView(nonce);
  view.setUint32(4, n & 0xffffffff, Endian.little);
  view.setUint32(8, (n ~/ 0x100000000) & 0xffffffff, Endian.little);
  return nonce;
}

class CipherState {
  Uint8List? _key;
  int _n = 0;

  bool get hasKey => _key != null;

  void initializeKey(Uint8List? key) {
    _key = key;
    _n = 0;
  }

  Uint8List encryptWithAd(List<int> ad, List<int> plaintext) {
    final key = _key;
    if (key == null) return Uint8List.fromList(plaintext);
    if (_n >= _maxNonce) throw NoiseSessionError('NOISE_NONCE_EXHAUSTED', 'The Noise nonce is used up.');
    final box = _aead.encryptSync(plaintext, secretKey: SecretKeyData(key), nonce: _nonce(_n), aad: ad);
    _n += 1;
    return _concat([box.cipherText, box.mac.bytes]);
  }

  Uint8List decryptWithAd(List<int> ad, List<int> ciphertext) {
    final key = _key;
    if (key == null) return Uint8List.fromList(ciphertext);
    if (ciphertext.length < _tagBytes) throw NoiseSessionError('NOISE_DECRYPT', 'The Noise message is too short.');
    if (_n >= _maxNonce) throw NoiseSessionError('NOISE_NONCE_EXHAUSTED', 'The Noise nonce is used up.');
    final split = ciphertext.length - _tagBytes;
    try {
      final clear = _aead.decryptSync(
        SecretBox(ciphertext.sublist(0, split), nonce: _nonce(_n), mac: Mac(ciphertext.sublist(split))),
        secretKey: SecretKeyData(key),
        aad: ad,
      );
      _n += 1;
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw NoiseSessionError('NOISE_DECRYPT', 'The Noise message failed authentication.');
    }
  }

  void destroy() {
    _key?.fillRange(0, _key!.length, 0);
    _key = null;
  }
}

class _SymmetricState {
  _SymmetricState(String protocolName) {
    final name = utf8.encode(protocolName);
    h = name.length <= 32 ? Uint8List(32) : _sha256(name);
    if (name.length <= 32) h.setRange(0, name.length, name);
    ck = Uint8List.fromList(h);
  }

  late Uint8List h;
  late Uint8List ck;
  final CipherState cipher = CipherState();

  void mixKey(List<int> input) {
    final out = _hkdf(ck, input);
    ck = out[0];
    cipher.initializeKey(Uint8List.fromList(out[1].sublist(0, 32)));
  }

  void mixHash(List<int> data) {
    h = _sha256([...h, ...data]);
  }

  Uint8List encryptAndHash(List<int> plaintext) {
    final ciphertext = cipher.encryptWithAd(h, plaintext);
    mixHash(ciphertext);
    return ciphertext;
  }

  Uint8List decryptAndHash(List<int> ciphertext) {
    final plaintext = cipher.decryptWithAd(h, ciphertext);
    mixHash(ciphertext);
    return plaintext;
  }

  List<CipherState> split() {
    final out = _hkdf(ck, const []);
    return [
      CipherState()..initializeKey(Uint8List.fromList(out[0].sublist(0, 32))),
      CipherState()..initializeKey(Uint8List.fromList(out[1].sublist(0, 32))),
    ];
  }
}

/// The two halves of a finished handshake. `send` encrypts what this side writes.
class NoiseTransport {
  NoiseTransport(this._send, this._receive);

  final CipherState _send;
  final CipherState _receive;

  Uint8List encrypt(List<int> plaintext) {
    if (plaintext.length + _tagBytes > noiseMaxMessage) {
      throw NoiseSessionError('NOISE_MESSAGE_TOO_LARGE', 'A Noise message holds at most 65535 bytes.');
    }
    return _send.encryptWithAd(const [], plaintext);
  }

  Uint8List decrypt(List<int> ciphertext) {
    if (ciphertext.length > noiseMaxMessage) {
      throw NoiseSessionError('NOISE_MESSAGE_TOO_LARGE', 'A Noise message holds at most 65535 bytes.');
    }
    return _receive.decryptWithAd(const [], ciphertext);
  }

  void destroy() {
    _send.destroy();
    _receive.destroy();
  }
}

/// Noise IK with one fixed suite. The remote static key must match the paired
/// key before any transport message can be read or written.
class NoiseIkSession {
  NoiseIkSession({
    required this.initiator,
    required String localPrivateKey,
    required String localPublicKey,
    required String remotePublicKey,
    required Uint8List prologue,
    Uint8List Function(int length)? random,
  })  : _sPriv = _requireKey(localPrivateKey, 'local private key'),
        _sPub = _requireKey(localPublicKey, 'local public key'),
        _expectedRemote = _requireKey(remotePublicKey, 'remote public key'),
        _random = random ?? randomBytes,
        _state = _SymmetricState(noiseIkProtocol) {
    _state.mixHash(prologue);
    // Pre-message pattern `<- s`: the responder's static key is known to both.
    if (initiator) {
      _rs = Uint8List.fromList(_expectedRemote);
      _state.mixHash(_rs!);
    } else {
      _state.mixHash(_sPub);
    }
  }

  final bool initiator;
  final Uint8List _sPriv;
  final Uint8List _sPub;
  final Uint8List _expectedRemote;
  final Uint8List Function(int length) _random;
  final _SymmetricState _state;
  Uint8List? _ePriv;
  Uint8List? _ePub;
  Uint8List? _rs;
  Uint8List? _re;
  int _message = 0;
  NoiseTransport? _transport;
  bool _destroyed = false;

  bool get complete => _transport != null;

  bool get _writeTurn => initiator ? _message == 0 : _message == 1;

  Uint8List writeHandshake([List<int> payload = const []]) {
    _assertHandshake(reading: false);
    final out = BytesBuilder(copy: false);
    _ePriv = _random(32);
    _ePub = x25519PublicKey(_ePriv!);
    out.add(_ePub!);
    _state.mixHash(_ePub!);
    if (initiator) {
      // -> e, es, s, ss
      _state.mixKey(x25519(_ePriv!, _rs!));
      out.add(_state.encryptAndHash(_sPub));
      _state.mixKey(x25519(_sPriv, _rs!));
    } else {
      // <- e, ee, se
      _state.mixKey(x25519(_ePriv!, _re!));
      _state.mixKey(x25519(_ePriv!, _rs!));
    }
    out.add(_state.encryptAndHash(payload));
    _message += 1;
    _finishIfReady();
    return out.toBytes();
  }

  Uint8List readHandshake(List<int> message) {
    _assertHandshake(reading: true);
    final input = Uint8List.fromList(message);
    var offset = 0;
    Uint8List take(int length) {
      if (input.length - offset < length) {
        throw NoiseSessionError('NOISE_HANDSHAKE_SHORT', 'The Noise handshake message is too short.');
      }
      final part = Uint8List.sublistView(input, offset, offset + length);
      offset += length;
      return Uint8List.fromList(part);
    }

    _re = take(_dhBytes);
    _state.mixHash(_re!);
    late Uint8List payload;
    try {
      if (initiator) {
        // <- e, ee, se
        _state.mixKey(x25519(_ePriv!, _re!));
        _state.mixKey(x25519(_sPriv, _re!));
      } else {
        // -> e, es, s, ss
        _state.mixKey(x25519(_sPriv, _re!));
        _rs = _state.decryptAndHash(take(_dhBytes + _tagBytes));
        _state.mixKey(x25519(_sPriv, _rs!));
      }
      payload = _state.decryptAndHash(Uint8List.sublistView(input, offset));
    } on StateError catch (error) {
      throw NoiseSessionError('NOISE_BAD_KEY', error.message);
    }
    _verifyRemoteStatic();
    _message += 1;
    _finishIfReady();
    return payload;
  }

  Uint8List encrypt(List<int> plaintext) => _requireTransport().encrypt(plaintext);

  Uint8List decrypt(List<int> ciphertext) => _requireTransport().decrypt(ciphertext);

  void destroy() {
    _destroyed = true;
    _expectedRemote.fillRange(0, _expectedRemote.length, 0);
    _ePriv?.fillRange(0, _ePriv!.length, 0);
    _state.cipher.destroy();
    _transport?.destroy();
    _transport = null;
  }

  NoiseTransport _requireTransport() {
    _assertLive();
    final transport = _transport;
    if (transport == null) throw NoiseSessionError('NOISE_NOT_READY', 'The Noise handshake is not complete.');
    return transport;
  }

  void _finishIfReady() {
    if (_message < 2) return;
    _verifyRemoteStatic();
    final pair = _state.split();
    _transport = initiator ? NoiseTransport(pair[0], pair[1]) : NoiseTransport(pair[1], pair[0]);
    _ePriv?.fillRange(0, _ePriv!.length, 0);
  }

  void _verifyRemoteStatic() {
    final actual = _rs;
    if (actual == null || !_constantTimeEqual(actual, _expectedRemote)) {
      destroy();
      throw NoiseSessionError('PEER_IDENTITY_MISMATCH', 'The peer key does not match the paired key.');
    }
  }

  void _assertHandshake({required bool reading}) {
    _assertLive();
    if (complete) throw NoiseSessionError('NOISE_ALREADY_READY', 'The Noise handshake is already complete.');
    if (_writeTurn == reading) {
      throw NoiseSessionError('NOISE_HANDSHAKE_ORDER', 'The Noise handshake message arrived out of order.');
    }
  }

  void _assertLive() {
    if (_destroyed) throw NoiseSessionError('NOISE_DESTROYED', 'The Noise session is closed.');
  }
}

/// Binds the handshake to one connection between two known devices.
Uint8List createNoisePrologue(String connectionId, String hostDeviceId, String clientDeviceId) {
  final fields = {'connectionId': connectionId, 'hostDeviceId': hostDeviceId, 'clientDeviceId': clientDeviceId};
  for (final entry in fields.entries) {
    if (entry.value.isEmpty || entry.value.contains('\u0000')) {
      throw ArgumentError('${entry.key} is not safe for a Noise prologue');
    }
  }
  return Uint8List.fromList(utf8.encode(
    'DS-BOT-LINK\u0000v=1\u0000connection=$connectionId\u0000host=$hostDeviceId\u0000client=$clientDeviceId',
  ));
}

Uint8List _requireKey(String value, String label) {
  final key = fromBase64Url(value);
  if (key.length != 32) throw NoiseSessionError('INVALID_KEY', '$label must be a 32-byte X25519 key.');
  return Uint8List.fromList(key);
}

bool _constantTimeEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var different = 0;
  for (var i = 0; i < left.length; i += 1) {
    different |= left[i] ^ right[i];
  }
  return different == 0;
}
