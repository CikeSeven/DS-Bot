// What the app needs from a link to one computer. The real one is the Rust
// session (lib/link/rust_link.dart); the demo answers locally; tests fake it.
import 'dart:async';

import '../link/rust_link.dart';

typedef Unsubscribe = void Function();

/// A feed event from the computer: message, stream, notice, room, live, revision.
class RpcEvent {
  const RpcEvent(this.event, this.data);

  final String event;
  final Object? data;
}

/// An error that carries the link's or the computer's error code.
class LinkError implements Exception {
  LinkError(this.code, this.message);

  final String? code;
  final String message;

  @override
  String toString() => code == null ? message : '$message ($code)';
}

enum LinkPhase {
  /// No link yet.
  connecting,
  online,

  /// This phone lost the Server (its network, or the Server itself); the link waits.
  reconnecting,

  /// The Server is fine, but the computer is not on it.
  hostAway,

  /// The computer refused this phone. Final.
  rejected,

  /// Closed by this phone. Final.
  closed,
}

class LinkStatus {
  const LinkStatus(this.phase, {this.resumed = false, this.attempt = 0, this.code, this.message});

  static const connecting = LinkStatus(LinkPhase.connecting);
  static const closed = LinkStatus(LinkPhase.closed);

  final LinkPhase phase;

  /// Online: the old link came back, so nothing needs reading again. False
  /// after a new handshake: the app reads its state again.
  final bool resumed;

  /// Connecting and reconnecting: failed tries since the Server last answered.
  final int attempt;

  /// Rejected: why.
  final String? code;
  final String? message;

  bool get online => phase == LinkPhase.online;

  bool get ended => phase == LinkPhase.rejected || phase == LinkPhase.closed;

  @override
  String toString() => '${phase.name}${resumed ? ' (resumed)' : ''}${code == null ? '' : ' $code'}';
}

/// One computer's link. Opening one returns at once; it connects, reconnects
/// and resumes by itself until it is closed or the computer refuses the phone.
abstract class LinkClient {
  Future<Object?> rpc(String method, Object? params, {Duration? timeout});
  Unsubscribe onEvent(void Function(RpcEvent event) handler);

  /// Where the link stands now; [statuses] tells every change after it.
  LinkStatus get status;
  Stream<LinkStatus> get statuses;

  /// The phone moved to another network: the link dials again at once.
  void networkChanged();

  /// Coming to the foreground checks the link at once. Going to the background
  /// changes nothing: the link keeps itself up as long as the process runs.
  void setForeground(bool foreground);

  Future<void> close();

  /// What the computer called itself in the handshake.
  String? get hostName;
}

/// Waits for a new link to come up, as pairing does. Fails when the computer
/// refuses it or is not on the Server, or when the Server cannot be reached.
Future<void> linkSettled(LinkClient client, {Duration timeout = const Duration(seconds: 30)}) async {
  final settled = Completer<void>();
  void check(LinkStatus status) {
    if (settled.isCompleted) return;
    final failure = switch (status.phase) {
      LinkPhase.online => null,
      LinkPhase.rejected => LinkError(status.code, status.message ?? 'The computer does not accept this phone.'),
      LinkPhase.hostAway => LinkError('HOST_OFFLINE', 'The computer is not connected to the Server.'),
      LinkPhase.closed => LinkError('CLIENT_CLOSED', 'The link was closed.'),
      LinkPhase.connecting || LinkPhase.reconnecting =>
        status.attempt >= 4 ? LinkError('SERVER_UNREACHABLE', status.message ?? 'Could not reach the Server.') : null,
    };
    if (failure != null) {
      settled.completeError(failure);
    } else if (status.online) {
      settled.complete();
    }
  }

  final watch = client.statuses.listen(check);
  check(client.status);
  try {
    await settled.future.timeout(timeout, onTimeout: () => throw LinkError('SERVER_UNREACHABLE', 'Could not reach the Server.'));
  } finally {
    unawaited(watch.cancel());
  }
}

class PhoneIdentity {
  const PhoneIdentity({
    required this.deviceId,
    required this.publicKey,
    required this.privateKey,
    required this.accessToken,
  });

  final String deviceId;
  final String publicKey;
  final String privateKey;
  final String accessToken;
  Map<String, Object?> toJson() => {
        'deviceId': deviceId,
        'publicKey': publicKey,
        'privateKey': privateKey,
        'accessToken': accessToken,
      };

  static PhoneIdentity? fromJson(Object? value) {
    if (value is! Map) return null;
    final deviceId = value['deviceId'];
    final publicKey = value['publicKey'];
    final privateKey = value['privateKey'];
    final accessToken = value['accessToken'];
    if (deviceId is! String || publicKey is! String || privateKey is! String || accessToken is! String) return null;
    try {
      if (deviceIdFor(publicKey) != deviceId) return null;
    } on Object {
      return null;
    }
    return PhoneIdentity(deviceId: deviceId, publicKey: publicKey, privateKey: privateKey, accessToken: accessToken);
  }

  static PhoneIdentity generate() {
    final keys = generateKeyPair();
    return PhoneIdentity(
      deviceId: deviceIdFor(keys.publicKey),
      publicKey: keys.publicKey,
      privateKey: keys.privateKey,
      accessToken: randomToken(),
    );
  }
}

/// A paired computer, as the pairing code described it.
class SavedComputer {
  const SavedComputer({
    required this.server,
    required this.hostDeviceId,
    required this.hostKey,
    required this.name,
    this.addedAt = 0,
  });

  factory SavedComputer.fromOffer(PairingOffer offer, {int? addedAt}) => SavedComputer(
        server: offer.server,
        hostDeviceId: offer.hostDeviceId,
        hostKey: offer.hostKey,
        name: offer.name,
        addedAt: addedAt ?? DateTime.now().millisecondsSinceEpoch,
      );

  final String server;
  final String hostDeviceId;
  final String hostKey;
  final String name;
  final int addedAt;

  /// The same short code the computer can show, from the decoded key bytes.
  String get fingerprint => identityFingerprint(hostKey);

  SavedComputer copyWith({String? name, int? addedAt}) => SavedComputer(
        server: server,
        hostDeviceId: hostDeviceId,
        hostKey: hostKey,
        name: name ?? this.name,
        addedAt: addedAt ?? this.addedAt,
      );

  Map<String, Object?> toJson() =>
      {'server': server, 'hostDeviceId': hostDeviceId, 'hostKey': hostKey, 'name': name, 'addedAt': addedAt};

  static SavedComputer? fromJson(Object? value) {
    if (value is! Map) return null;
    final server = value['server'];
    final hostDeviceId = value['hostDeviceId'];
    final hostKey = value['hostKey'];
    if (server is! String || hostDeviceId is! String || hostKey is! String) return null;
    final name = value['name'];
    final addedAt = value['addedAt'];
    return SavedComputer(
      server: server,
      hostDeviceId: hostDeviceId,
      hostKey: hostKey,
      name: name is String ? name : '',
      addedAt: addedAt is int ? addedAt : 0,
    );
  }
}

typedef LinkOpener = Future<LinkClient> Function(SavedComputer computer, PhoneIdentity identity, {String? pairingCode});

/// An error from the computer's DS Bot, or a local one with the same shape.
class BotError implements Exception {
  BotError(this.code, this.message);

  final String? code;
  final String message;

  @override
  String toString() => message;
}

/// Calls one DS Bot endpoint on the computer, the same one its window calls.
Future<Object?> callBot(LinkClient client, String endpoint, [Object? payload, Duration? timeout]) async {
  final reply = await callBotState(client, endpoint, payload ?? const <String, Object?>{}, null, timeout);
  return reply.value;
}

class BotReply {
  const BotReply(this.value, this.state);

  final Object? value;
  final Map<String, dynamic>? state;
}

/// Same call, but the request can carry `state` (the payload the `state`
/// endpoint takes). A write that moved the team answers with the new state in
/// the same reply, so the phone needs no second round trip.
Future<BotReply> callBotState(LinkClient client, String endpoint, Object? payload, Object? state, [Duration? timeout]) async {
  final Object? result;
  try {
    result = await client.rpc(
      'bot',
      {'endpoint': endpoint, 'payload': payload ?? const <String, Object?>{}, 'state': ?state},
      timeout: timeout,
    );
  } on LinkError catch (error) {
    throw BotError(error.code, error.message);
  }
  if (result is! Map) throw BotError('bot/invalid', 'The computer sent an answer this phone cannot read.');
  if (result['ok'] != true) {
    final error = result['error'];
    final code = error is Map ? error['code'] : null;
    final message = error is Map ? error['message'] : null;
    throw BotError(code is String ? code : null, message is String ? message : 'The computer refused this.');
  }
  final teamState = result['state'];
  return BotReply(result['value'], teamState is Map<String, dynamic> ? teamState : null);
}
