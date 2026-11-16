import 'dart:async';

import 'package:dsbot_mobile/api/link_client.dart';

typedef BotHandler = FutureOr<Map<String, Object?>> Function(String endpoint, Map<String, dynamic> payload, Object? state);

/// A computer in memory: answers `bot` calls with a handler and can push events.
/// Like the real link, a call waits while the link is down and fails once it
/// has ended; tests move the link through its states with [setStatus].
class FakeLinkClient implements LinkClient {
  FakeLinkClient(this.handler, {this._status = const LinkStatus(LinkPhase.online)});

  final BotHandler handler;
  final Set<void Function(RpcEvent)> _events = {};
  final StreamController<LinkStatus> _statuses = StreamController.broadcast(sync: true);
  LinkStatus _status;
  final List<String> calls = [];
  final List<bool> foregrounds = [];
  int networkChanges = 0;
  bool closed = false;

  @override
  String? get hostName => 'Desk';

  @override
  LinkStatus get status => _status;

  @override
  Stream<LinkStatus> get statuses => _statuses.stream;

  void setStatus(LinkStatus status) {
    _status = status;
    _statuses.add(status);
  }

  /// The socket dropped and the same link came back.
  void resume() {
    setStatus(const LinkStatus(LinkPhase.reconnecting));
    setStatus(const LinkStatus(LinkPhase.online, resumed: true));
  }

  /// A new handshake, as after the computer restarted.
  void renew() {
    setStatus(const LinkStatus(LinkPhase.reconnecting));
    setStatus(const LinkStatus(LinkPhase.online));
  }

  @override
  Future<Object?> rpc(String method, Object? params, {Duration? timeout}) async {
    if (!_status.online && !_status.ended) await statuses.firstWhere((status) => status.online || status.ended);
    if (closed || _status.ended) throw LinkError(_status.code ?? 'CLIENT_CLOSED', _status.message ?? 'closed');
    final map = params! as Map<String, Object?>;
    final endpoint = map['endpoint']! as String;
    calls.add(endpoint);
    return handler(endpoint, (map['payload'] as Map).cast<String, dynamic>(), map['state']);
  }

  void emit(String event, Object? data) {
    for (final handler in [..._events]) {
      handler(RpcEvent(event, data));
    }
  }

  @override
  Unsubscribe onEvent(void Function(RpcEvent event) handler) {
    _events.add(handler);
    return () => _events.remove(handler);
  }

  @override
  void networkChanged() => networkChanges += 1;

  @override
  void setForeground(bool foreground) => foregrounds.add(foreground);

  @override
  Future<void> close() async {
    closed = true;
  }
}

Map<String, Object?> ok(Object? value, [Map<String, Object?>? state]) => {'ok': true, 'value': value, 'state': ?state};

Map<String, Object?> refuse(String code, String message) => {
      'ok': false,
      'error': {'code': code, 'message': message},
    };

Map<String, Object?> hello({String boot = 'b1', int seq = 0, List<String> capabilities = const []}) =>
    {'api': 1, 'apiMin': 1, 'apiMax': 1, 'capabilities': capabilities, 'boot': boot, 'seq': seq};

const testComputer = SavedComputer(server: 'wss://relay.test/v2/link', hostDeviceId: 'd-host', hostKey: 'key', name: 'Desk');

/// Never checked by a fake link, so it needs no real key.
const testIdentity = PhoneIdentity(deviceId: 'd-phone', publicKey: 'phone-key', privateKey: 'phone-private', accessToken: 'token');

Future<void> settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));
