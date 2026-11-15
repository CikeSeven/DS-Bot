// Port of link/src/secure-transport.ts: the end-to-end Noise channel from this
// phone to one paired computer, over any carrier.
import 'dart:async';
import 'dart:typed_data';

import 'errors.dart';
import 'frames.dart';
import 'noise.dart';
import 'pairing.dart';
import 'transport.dart';

class DeviceIdentity {
  const DeviceIdentity({required this.deviceId, required this.publicKey, required this.privateKey});

  final String deviceId;
  final String publicKey;
  final String privateKey;
}

class PairedHost {
  const PairedHost({required this.deviceId, required this.identityKey});

  final String deviceId;
  final String identityKey;
}

class SecureTransport implements RemoteTransport {
  SecureTransport(
    this._inner,
    this._identity,
    this._host, {
    this.handshakeTimeout = const Duration(seconds: 10),
    this.hello = const HandshakeHello(),
  }) {
    if (_host.identityKey.isEmpty) throw ArgumentError('The paired computer has no identity key.');
  }

  final SecureHandshakeTransport _inner;
  final DeviceIdentity _identity;
  final PairedHost _host;
  final Duration handshakeTimeout;

  /// Sent inside the encrypted handshake: the Server never sees it.
  final HandshakeHello hello;
  NoiseIkSession? _noise;
  Unsubscribe? _unsubscribeInner;
  final SecureMessageCodec _incoming = SecureMessageCodec();
  final SecureMessageCodec _outgoing = SecureMessageCodec();
  bool _closed = false;
  Future<void> _sendTail = Future<void>.value();
  HandshakeHello? _remoteHello;

  @override
  Future<void> connect() async {
    _closed = false;
    _incoming.reset();
    _outgoing.reset();
    await _inner.connect();
    final info = _inner.connectionInfo();
    if (info.localDeviceId != _identity.deviceId || info.remoteDeviceId != _host.deviceId) {
      await _inner.close();
      throw LinkError(null, 'The Server connected this phone to a different device.');
    }
    final noise = NoiseIkSession(
      initiator: true,
      localPrivateKey: _identity.privateKey,
      localPublicKey: _identity.publicKey,
      remotePublicKey: _host.identityKey,
      prologue: createNoisePrologue(info.connectionId, _host.deviceId, _identity.deviceId),
    );
    _noise = noise;
    try {
      final reply = await _waitForResponder(noise, encodeHandshakeHello(hello));
      _remoteHello = decodeHandshakeHello(reply);
    } on Object {
      noise.destroy();
      _noise = null;
      await _inner.close();
      rethrow;
    }
  }

  /// Noise counters and fragment ids are not re-entrant, so sends run one at a time.
  @override
  Future<void> send(Uint8List data) {
    final run = _sendTail.then((_) => _sendNow(data));
    _sendTail = run.catchError((_) {});
    return run;
  }

  @override
  Unsubscribe onMessage(void Function(Uint8List data) handler) {
    _unsubscribeInner?.call();
    _unsubscribeInner = _inner.onMessage((data) {
      final noise = _noise;
      if (noise == null || !noise.complete || _closed) return;
      Uint8List? message;
      try {
        message = _incoming.decode(noise.decrypt(data));
      } on Object {
        unawaited(close());
        return;
      }
      if (message != null) handler(message);
    });
    return () {
      _unsubscribeInner?.call();
      _unsubscribeInner = null;
    };
  }

  @override
  Unsubscribe onClose(void Function() handler) => _inner.onClose(handler);

  @override
  void probe() => _inner.probe();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _unsubscribeInner?.call();
    _unsubscribeInner = null;
    _incoming.reset();
    _outgoing.reset();
    _noise?.destroy();
    _noise = null;
    await _inner.close();
  }

  @override
  TransportStats getStats() => _inner.getStats();

  /// What the computer said about itself in the handshake, such as its name.
  HandshakeHello? get hostHello => _remoteHello;

  Object? get closeReason => _inner.closeReason;

  Future<void> _sendNow(Uint8List data) async {
    final frames = _outgoing.encode(data);
    try {
      for (final plaintext in frames) {
        await _inner.send(_requireNoise().encrypt(plaintext));
      }
    } on Object {
      await close().catchError((_) {});
      rethrow;
    }
  }

  NoiseIkSession _requireNoise() {
    final noise = _noise;
    if (noise == null || !noise.complete || _closed) throw LinkError(null, 'The secure channel is not connected.');
    return noise;
  }

  Future<Uint8List> _waitForResponder(NoiseIkSession noise, Uint8List helloBytes) {
    final done = Completer<Uint8List>();
    late final Timer timer;
    Unsubscribe? unsubscribe;
    Unsubscribe? unsubscribeClose;
    void finish([Object? error, Uint8List? reply]) {
      if (done.isCompleted) return;
      timer.cancel();
      unsubscribe?.call();
      unsubscribeClose?.call();
      if (error == null) {
        done.complete(reply ?? Uint8List(0));
      } else {
        done.completeError(error);
      }
    }

    timer = Timer(handshakeTimeout, () => finish(LinkError(null, 'The secure handshake timed out.')));
    unsubscribe = _inner.onHandshake((step, data) {
      if (done.isCompleted) return;
      try {
        if (step != 2) throw LinkError(null, 'The secure handshake arrived out of order.');
        final reply = noise.readHandshake(data);
        if (!noise.complete) throw LinkError(null, 'The secure handshake did not complete.');
        finish(null, reply);
      } on Object catch (error) {
        finish(error);
      }
    });
    unsubscribeClose = _inner.onClose(() {
      finish(_inner.closeReason ?? LinkError(null, 'The link closed during the secure handshake.'));
    });
    Uint8List message;
    try {
      message = noise.writeHandshake(helloBytes);
    } on Object catch (error) {
      finish(error);
      return done.future;
    }
    _inner.sendHandshake(1, message).catchError((Object error) => finish(error));
    return done.future;
  }
}
