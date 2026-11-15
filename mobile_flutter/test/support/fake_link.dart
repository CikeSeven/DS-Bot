import 'dart:async';

import 'package:dsbot_mobile/api/link_client.dart';
import 'package:dsbot_mobile/link/link.dart';

typedef BotHandler = FutureOr<Map<String, Object?>> Function(String endpoint, Map<String, dynamic> payload, Object? state);

/// A computer in memory: answers `bot` calls with a handler and can push events.
class FakeLinkClient implements LinkClient {
  FakeLinkClient(this.handler);

  final BotHandler handler;
  final Set<void Function(RpcEvent)> _events = {};
  final Set<void Function()> _closes = {};
  final List<String> calls = [];
  bool closed = false;
  int probes = 0;

  @override
  String? get hostName => 'Desk';

  @override
  Future<Object?> rpc(String method, Object? params, {Duration? timeout}) async {
    if (closed) throw LinkError('TRANSPORT_CLOSED', 'closed');
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

  void drop() {
    closed = true;
    for (final handler in [..._closes]) {
      handler();
    }
  }

  @override
  Unsubscribe onEvent(void Function(RpcEvent event) handler) {
    _events.add(handler);
    return () => _events.remove(handler);
  }

  @override
  Unsubscribe onClose(void Function() handler) {
    _closes.add(handler);
    return () => _closes.remove(handler);
  }

  @override
  void probe() => probes += 1;

  @override
  Future<void> close() async => closed = true;
}

Map<String, Object?> ok(Object? value, [Map<String, Object?>? state]) => {'ok': true, 'value': value, 'state': ?state};

Map<String, Object?> refuse(String code, String message) => {
      'ok': false,
      'error': {'code': code, 'message': message},
    };

Map<String, Object?> hello({String boot = 'b1', int seq = 0, List<String> capabilities = const []}) =>
    {'api': 1, 'apiMin': 1, 'apiMax': 1, 'capabilities': capabilities, 'boot': boot, 'seq': seq};

const testComputer = SavedComputer(server: 'wss://relay.test/v1/link', hostDeviceId: 'd-host', hostKey: 'key', name: 'Desk');

final testIdentity = PhoneIdentity.generate();

Future<void> settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));
