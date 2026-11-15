// Port of link/src/rpc-client.ts: request and reply over one secure transport.
// A call is sent once: a timeout or a closed link fails the call and never
// sends it again.
import 'dart:async';

import 'errors.dart';
import 'frames.dart';
import 'transport.dart';

class RpcEvent {
  const RpcEvent(this.event, this.data, {this.seq});

  final String event;
  final Object? data;
  final int? seq;
}

class _PendingCall {
  _PendingCall(this.method, this.completer, this.timer);

  final String method;
  final Completer<Object?> completer;
  final Timer timer;
}

class RpcClient {
  RpcClient(this.transport, {this.timeout = const Duration(seconds: 30)});

  final RemoteTransport transport;
  final Duration timeout;
  final Map<String, _PendingCall> _pending = {};
  final Set<void Function(RpcEvent)> _eventHandlers = {};
  final Set<void Function()> _closeHandlers = {};
  Unsubscribe? _unsubscribeTransport;
  Unsubscribe? _unsubscribeClose;
  bool _closeNotified = false;

  Future<void> connect() async {
    if (_unsubscribeTransport != null) return;
    _closeNotified = false;
    _unsubscribeTransport = transport.onMessage(_handleMessage);
    _unsubscribeClose = transport.onClose(_handleTransportClose);
    try {
      await transport.connect();
    } on Object {
      _unsubscribeTransport?.call();
      _unsubscribeTransport = null;
      _unsubscribeClose?.call();
      _unsubscribeClose = null;
      rethrow;
    }
  }

  Future<Object?> rpc(String method, Object? params, {Duration? timeout}) {
    final limit = timeout ?? this.timeout;
    final request = Envelope('rpc.request', {'method': method, 'params': params});
    final completer = Completer<Object?>();
    final timer = Timer(limit, () {
      _rejectPending(request.id, LinkError('RPC_TIMEOUT', 'RPC $method timed out after ${limit.inMilliseconds}ms'));
    });
    _pending[request.id] = _PendingCall(method, completer, timer);
    // The write is not awaited, so a timeout or close still settles a call whose send stalls.
    try {
      transport.send(encodeMessage(request)).catchError((Object error) => _rejectPending(request.id, _sendError(error)));
    } on Object catch (error) {
      _rejectPending(request.id, _sendError(error));
    }
    return completer.future;
  }

  Unsubscribe onEvent(void Function(RpcEvent event) handler) {
    _eventHandlers.add(handler);
    return () => _eventHandlers.remove(handler);
  }

  Unsubscribe onClose(void Function() handler) {
    _closeHandlers.add(handler);
    return () => _closeHandlers.remove(handler);
  }

  TransportStats getStats() => transport.getStats();

  void probe() => transport.probe();

  Future<void> close() async {
    _unsubscribeTransport?.call();
    _unsubscribeTransport = null;
    _unsubscribeClose?.call();
    _unsubscribeClose = null;
    _rejectAll((pending) => LinkError('CLIENT_CLOSED', 'RPC ${pending.method} ended because the client closed'));
    _notifyClose();
    await transport.close();
  }

  void _handleTransportClose() {
    _rejectAll((pending) => LinkError('TRANSPORT_CLOSED', 'RPC ${pending.method} ended because the link closed'));
    _notifyClose();
  }

  void _handleMessage(List<int> data) {
    final Envelope message;
    try {
      message = decodeMessage(data);
    } on Object {
      // The TypeScript client lets this throw into the transport, which ends the
      // link; closing does the same without an uncaught error.
      unawaited(transport.close());
      return;
    }
    final payload = message.payload;
    switch (message.type) {
      case 'rpc.response':
        _takePending(payload['requestId'])?.completer.complete(payload['result']);
      case 'rpc.error':
        final code = payload['code'];
        final text = payload['message'];
        _takePending(payload['requestId'])
            ?.completer
            .completeError(LinkError(code is String ? code : null, text is String ? text : 'The computer refused the call.'));
      case 'event':
        final name = payload['event'];
        if (name is! String) return;
        final seq = payload['seq'];
        final event = RpcEvent(name, payload['data'], seq: seq is int ? seq : null);
        for (final handler in [..._eventHandlers]) {
          handler(event);
        }
    }
  }

  _PendingCall? _takePending(Object? requestId) {
    if (requestId is! String) return null;
    final pending = _pending.remove(requestId);
    pending?.timer.cancel();
    return pending;
  }

  void _rejectPending(String requestId, Object error) {
    final pending = _takePending(requestId);
    if (pending != null && !pending.completer.isCompleted) pending.completer.completeError(error);
  }

  void _rejectAll(Object Function(_PendingCall pending) createError) {
    for (final requestId in [..._pending.keys]) {
      final pending = _takePending(requestId);
      if (pending != null && !pending.completer.isCompleted) pending.completer.completeError(createError(pending));
    }
  }

  void _notifyClose() {
    if (_closeNotified) return;
    _closeNotified = true;
    for (final handler in [..._closeHandlers]) {
      handler();
    }
  }
}

Object _sendError(Object error) => error is LinkError ? error : LinkError(null, 'link send failed: $error');
