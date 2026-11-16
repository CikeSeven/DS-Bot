// Port of the Expo app's src/team/seen.ts: last-read time per (computer, Bot or group),
// kept on the phone. A row is unread when its lastAt is newer and its chat is
// not open. Loaded once at start, so read rows stay read after a restart.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'store.dart';

class SeenStore extends ChangeNotifier {
  SeenStore(this._kv);

  static const _key = 'dsbot.seenAt';

  final KeyValueStore _kv;
  final Map<String, Map<String, int>> _seen = {};
  Future<void>? _loading;
  bool _loaded = false;
  bool _dirty = false;
  bool _pendingPersist = false;
  Future<void>? _flushing;

  bool _merge(String hostId, Object? entries) {
    if (hostId.isEmpty || entries is! Map) return false;
    var changed = false;
    for (final entry in entries.entries) {
      final id = entry.key;
      final at = entry.value;
      if (id is! String || id.isEmpty || at is! num || !at.isFinite || at <= 0) continue;
      final map = _seen.putIfAbsent(hostId, () => {});
      if (at > (map[id] ?? 0)) {
        map[id] = at.toInt();
        changed = true;
      }
    }
    return changed;
  }

  Future<void> load() {
    if (_loaded) return Future.value();
    return _loading ??= () async {
      try {
        final text = await _kv.read(_key);
        if (text != null) {
          final parsed = jsonDecode(text);
          if (parsed is Map) {
            var changed = false;
            for (final entry in parsed.entries) {
              if (entry.key is String && _merge(entry.key as String, entry.value)) changed = true;
            }
            if (changed) notifyListeners();
          }
        }
      } on Object {
        // Start fresh.
      } finally {
        _loaded = true;
      }
    }();
  }

  int seenAt(String hostId, String id) => _seen[hostId]?[id] ?? 0;

  bool isUnread(String hostId, String id, int? lastAt, {bool open = false}) =>
      !open && lastAt != null && lastAt > seenAt(hostId, id);

  Future<void> markSeen(String hostId, String id, [int? at]) {
    final when = at ?? DateTime.now().millisecondsSinceEpoch;
    if (hostId.isEmpty || id.isEmpty || when <= 0) return Future.value();
    final map = _seen.putIfAbsent(hostId, () => {});
    final prev = map[id] ?? 0;
    if (when <= prev && !_pendingPersist) return _flushing ?? Future.value();
    if (when > prev) {
      map[id] = when;
      notifyListeners();
    }
    _dirty = true;
    _pendingPersist = true;
    return _flushing ??= () async {
      try {
        await load();
        while (_dirty) {
          _dirty = false;
          try {
            await _kv.write(_key, _serialize());
            if (!_dirty) _pendingPersist = false;
          } on Object {
            _pendingPersist = true;
          }
        }
      } finally {
        _flushing = null;
      }
    }();
  }

  String _serialize() => jsonEncode({
        for (final entry in _seen.entries)
          if (entry.value.isNotEmpty) entry.key: entry.value,
      });
}
