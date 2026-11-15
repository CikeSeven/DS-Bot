// What the app needs from a link to one computer. The real one runs over the
// Relay; the demo answers locally; a background service can proxy one.
import 'dart:async';

import '../link/link.dart';

abstract class LinkClient {
  Future<Object?> rpc(String method, Object? params, {Duration? timeout});
  Unsubscribe onEvent(void Function(RpcEvent event) handler);
  Unsubscribe onClose(void Function() handler);

  /// Ask for a liveness reply now; a dead link then closes itself.
  void probe();
  Future<void> close();

  /// What the computer called itself in the handshake.
  String? get hostName;
}

class PhoneIdentity extends DeviceIdentity {
  const PhoneIdentity({
    required super.deviceId,
    required super.publicKey,
    required super.privateKey,
    required this.accessToken,
  });

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

/// The encrypted link over the Relay Server.
class RelayLinkClient implements LinkClient {
  RelayLinkClient._(this._client, this._secure);

  final RpcClient _client;
  final SecureTransport _secure;

  /// Opens the link. The pairing code goes only with the first connection.
  static Future<RelayLinkClient> open(
    SavedComputer computer,
    PhoneIdentity identity, {
    String? pairingCode,
    String phoneName = 'Phone',
  }) async {
    final relay = RelayTransport(
      computer.server,
      RelayTransportOptions(
        deviceId: identity.deviceId,
        identityKey: identity.publicKey,
        accessToken: identity.accessToken,
        targetDeviceId: computer.hostDeviceId,
      ),
    );
    final name = phoneName.length > 64 ? phoneName.substring(0, 64) : phoneName;
    final secure = SecureTransport(
      relay,
      identity,
      PairedHost(deviceId: computer.hostDeviceId, identityKey: computer.hostKey),
      hello: HandshakeHello(name: name, pairingCode: pairingCode),
    );
    final client = RpcClient(secure);
    await client.connect();
    return RelayLinkClient._(client, secure);
  }

  @override
  Future<Object?> rpc(String method, Object? params, {Duration? timeout}) => _client.rpc(method, params, timeout: timeout);

  @override
  Unsubscribe onEvent(void Function(RpcEvent event) handler) => _client.onEvent(handler);

  @override
  Unsubscribe onClose(void Function() handler) => _client.onClose(handler);

  @override
  void probe() => _client.probe();

  @override
  Future<void> close() => _client.close();

  @override
  String? get hostName => _secure.hostHello?.name;
}

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
