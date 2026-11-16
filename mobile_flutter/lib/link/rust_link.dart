// The link to a computer is the Rust session in link/crates/client, reached
// through flutter_rust_bridge (rust/, generated Dart in lib/src/rust/). The
// session reconnects and resumes on its own. A process keeps one session per
// computer: the app and its background isolates that open the same computer
// share it instead of pushing each other off the Server.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;

import '../api/link_client.dart';
import '../src/rust/api/keys.dart' as ffi;
import '../src/rust/api/link.dart' as ffi;
import '../src/rust/frb_generated.dart';

export '../src/rust/api/keys.dart' show KeyPair, PairingOffer;

Future<void>? _loading;

/// Loads the Rust library into this isolate. Every isolate calls it before it
/// touches a key or a link.
Future<void> initRustLink({ExternalLibrary? library}) => _loading ??= RustLib.init(externalLibrary: library);

ffi.KeyPair generateKeyPair() => ffi.generateKeyPair();

/// A device's id is derived from its identity key, so the Server can check one against the other.
String deviceIdFor(String publicKey) => _plain(() => ffi.deviceIdFor(publicKey: publicKey));

/// Short code both screens show at pairing, so the user can see they hold the same key.
String identityFingerprint(String publicKey) => _plain(() => ffi.identityFingerprint(publicKey: publicKey));

String randomToken([int bytes = 32]) => ffi.randomToken(bytes: bytes);

/// Reads a pairing link; its message says what is wrong with one that is not.
ffi.PairingOffer parsePairingUri(String uri) => _plain(() => ffi.parsePairingUri(uri: uri.trim()));

T _plain<T>(T Function() run) {
  try {
    return run();
  } on ffi.LinkFailure catch (failure) {
    throw FormatException(failure.message);
  }
}

class RustLinkClient implements LinkClient {
  RustLinkClient._(this._link) : _status = _statusOf(_link.status()) ?? LinkStatus.connecting, _hostName = _link.hostName() {
    _events = _link.events().listen(_onEvent, onError: (Object _) {});
  }

  /// Opens the link to [computer], or joins the one this process already has.
  /// A pairing code always starts a new one.
  static RustLinkClient open(SavedComputer computer, PhoneIdentity identity, {String? pairingCode, String phoneName = 'Phone'}) {
    final config = ffi.PhoneLinkConfig(
      server: computer.server,
      publicKey: identity.publicKey,
      privateKey: identity.privateKey,
      accessToken: identity.accessToken,
      hostDeviceId: computer.hostDeviceId,
      hostKey: computer.hostKey,
      name: phoneName.length > 64 ? phoneName.substring(0, 64) : phoneName,
      pairingCode: pairingCode,
    );
    try {
      return RustLinkClient._(ffi.PhoneLink.open(config: config));
    } on ffi.LinkFailure catch (failure) {
      throw LinkError(failure.code, failure.message);
    }
  }

  final ffi.PhoneLink _link;
  late final StreamSubscription<ffi.PhoneLinkEvent> _events;
  final Set<void Function(RpcEvent)> _handlers = {};
  final StreamController<LinkStatus> _statuses = StreamController.broadcast();
  LinkStatus _status;
  String? _hostName;
  bool _closed = false;

  @override
  LinkStatus get status => _status;

  @override
  Stream<LinkStatus> get statuses => _statuses.stream;

  @override
  String? get hostName => _hostName;

  @override
  Future<Object?> rpc(String method, Object? params, {Duration? timeout}) async {
    if (_closed) throw LinkError('CLIENT_CLOSED', 'The link was closed.');
    final String answer;
    try {
      answer = await _link.rpc(method: method, paramsJson: jsonEncode(params), timeoutMs: timeout?.inMilliseconds ?? 0);
    } on ffi.LinkFailure catch (failure) {
      throw LinkError(failure.code, failure.message);
    }
    return jsonDecode(answer);
  }

  @override
  Unsubscribe onEvent(void Function(RpcEvent event) handler) {
    _handlers.add(handler);
    return () => _handlers.remove(handler);
  }

  @override
  void networkChanged() {
    if (!_closed) _link.networkChanged();
  }

  @override
  void setForeground(bool foreground) {
    if (!_closed) _link.setForeground(foreground: foreground);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _handlers.clear();
    await _link.close();
    await _events.cancel();
    _link.dispose();
    _setStatus(LinkStatus.closed);
    await _statuses.close();
  }

  void _onEvent(ffi.PhoneLinkEvent event) {
    if (_closed) return;
    final status = _statusOf(event.status);
    if (status != null) {
      if (status.online) _hostName = _link.hostName() ?? _hostName;
      _setStatus(status);
      return;
    }
    final Object? data;
    try {
      data = jsonDecode(event.data);
    } on FormatException {
      return;
    }
    for (final handler in [..._handlers]) {
      handler(RpcEvent(event.name, data));
    }
  }

  void _setStatus(LinkStatus status) {
    _status = status;
    if (!_statuses.isClosed) _statuses.add(status);
  }
}

LinkStatus? _statusOf(ffi.PhoneLinkStatus? status) {
  if (status == null) return null;
  final phase = switch (status.state) {
    ffi.LinkState.connecting => LinkPhase.connecting,
    ffi.LinkState.online => LinkPhase.online,
    ffi.LinkState.reconnecting => LinkPhase.reconnecting,
    ffi.LinkState.hostAway => LinkPhase.hostAway,
    ffi.LinkState.rejected => LinkPhase.rejected,
    ffi.LinkState.closed => LinkPhase.closed,
  };
  return LinkStatus(phase, resumed: status.resumed, attempt: status.attempt, code: status.code, message: status.message);
}
