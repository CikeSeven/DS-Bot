// One open chat with a Bot or a group: its pages, the messages this phone is
// still sending, the live streaming bubble, and read times. Port of the data
// half of the Expo app's src/screens/Chat.tsx.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api/link_client.dart';
import 'chat_cache.dart';
import 'chat_items.dart';
import 'json.dart';
import 'seen.dart';
import 'team_session.dart';

class ChatPageData {
  const ChatPageData({this.sessionId, required this.items, this.cursor});

  factory ChatPageData.from(Object? value) {
    final map = asJson(value);
    return ChatPageData(sessionId: jStr(map, 'sessionId'), items: jMaps(map, 'items'), cursor: map['cursor']);
  }

  final String? sessionId;
  final List<Json> items;
  final Object? cursor;

  ChatPageData withItems(List<Json> items) => ChatPageData(sessionId: sessionId, items: items, cursor: cursor);
}

/// A photo ready to send: shown from [bytes], sent as base64 JPEG.
class OutgoingPhoto {
  const OutgoingPhoto({required this.bytes, required this.mediaType, required this.base64});

  final Uint8List bytes;
  final String mediaType;
  final String base64;
}

/// A file ready to send (needs the computer's `file-upload` capability).
class OutgoingFile {
  const OutgoingFile({required this.name, required this.mediaType, required this.bytes});

  final String name;
  final String mediaType;
  final Uint8List bytes;
}

class _Outgoing {
  _Outgoing(this.item, this.photos, this.files, this.sessionId, this.known);

  Json item;
  final List<OutgoingPhoto> photos;
  final List<OutgoingFile> files;
  final String sessionId;

  /// The row keys the chat held when the message was written: only a row the
  /// chat shows after them can be this message coming back.
  final Set<String> known;
}

class ChatRow {
  const ChatRow(this.item, this.key, this.stamp, {this.photos = const []});

  final Json item;
  final String key;
  final String? stamp;

  /// Photos picked on this phone, shown from the device until the computer has them.
  final List<OutgoingPhoto> photos;

  String get kind => jStr(item, 'kind') ?? '';
  bool get local => item['local'] != null;
}

class ChatSession extends ChangeNotifier {
  ChatSession({
    required this.team,
    required this.hostId,
    required this.room,
    required this.id,
    required this.seen,
    this.pollEvery = const Duration(seconds: 15),
  }) : chatKey = '$hostId:${room ? 'room' : 'bot'}:$id';

  final TeamSession team;
  final String hostId;
  final bool room;
  final String id;
  final SeenStore seen;
  final Duration pollEvery;
  final String chatKey;

  static final ChatCache<ChatPageData, Json> _pages = ChatCache(16);
  static final Map<String, List<_Outgoing>> _outbox = {};
  static final Set<ChatSession> _live = {};

  ChatPageData? _page;
  List<Json> _older = [];
  Object? _cursor;
  bool _cursorSet = false;
  bool gone = false;
  Object? loadError;
  bool loadingOlder = false;
  bool _loadingMore = false;
  bool _reading = false;
  bool _again = false;
  bool _disposed = false;
  bool visible = true;
  bool _wasOnline = false;
  Timer? _timer;
  StreamSubscription<RpcEvent>? _feed;
  final Map<String, String> _attempts = {};
  String streaming = '';
  List<ChatRow> _rows = const [];
  bool _rowsDirty = true;

  ChatPageData? get page => _page;
  bool get loaded => _page != null;

  /// The session messages are sent to: the page's, else the Bot's own chat.
  String get sessionId {
    final fromPage = _page?.sessionId;
    if (fromPage != null) return fromPage;
    if (room) return team.team?.room(id)?.sessionId ?? id;
    return team.team?.bot(id)?.chatSession ?? id;
  }

  List<Json> get items => [..._older, ...?_page?.items];

  List<ChatRow> get rows {
    if (!_rowsDirty) return _rows;
    final outgoing = _outbox[chatKey] ?? const [];
    // Tool steps stay off the phone's list; what a Bot does shows only while it works.
    final all = [...items, ...outgoing.map((entry) => entry.item)].where((item) => jStr(item, 'kind') != 'steps').toList();
    final keys = keysOf(all);
    final photosByLocal = {for (final entry in outgoing) jStr(entry.item, 'localId'): entry.photos};
    _rows = [
      for (final (index, item) in all.indexed)
        ChatRow(
          item,
          keys[index],
          room ? null : stampOf(all, index),
          photos: photosByLocal[jStr(item, 'localId')] ?? const [],
        ),
    ];
    _rowsDirty = false;
    return _rows;
  }

  void _changed() {
    _rowsDirty = true;
    if (!_disposed) notifyListeners();
  }

  void start() {
    _live.add(this);
    final cached = _pages.get(chatKey);
    if (cached != null) {
      _page = cached.page;
      _older = [...cached.older];
      _cursor = cached.cursor;
      _cursorSet = true;
    }
    _wasOnline = team.online;
    team.addListener(_onTeam);
    _feed = team.feed.listen(_onFeed);
    unawaited(_loop());
    team.refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _live.remove(this);
    _timer?.cancel();
    unawaited(_feed?.cancel());
    team.removeListener(_onTeam);
    super.dispose();
  }

  Future<void> _loop() async {
    await refresh();
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(pollEvery, () => unawaited(_loop()));
  }

  void _onTeam() {
    // Back online after a drop: read what was missed.
    if (team.online && !_wasOnline) unawaited(refresh());
    _wasOnline = team.online;
  }

  Future<ChatPageData> _read([Object? cursor]) async {
    final value = room
        ? await team.call('room-chat', {'roomId': id, 'cursor': ?cursor})
        : await team.call('chat', {'botId': id, 'cursor': ?cursor});
    return ChatPageData.from(value);
  }

  /// One chat read at a time: a burst of messages becomes one read now and at
  /// most one more after it.
  Future<void> refresh() async {
    if (_disposed || id.isEmpty) return;
    if (_reading) {
      _again = true;
      return;
    }
    _reading = true;
    try {
      final next = await _read();
      if (_disposed) return;
      final prev = _page;
      _page = prev != null && prev.sessionId == next.sessionId ? next.withItems(keepSame(prev.items, next.items)) : next;
      if (prev != null && prev.sessionId != next.sessionId) _older = [];
      if (!_cursorSet) {
        _cursor = next.cursor;
        _cursorSet = true;
      }
      loadError = null;
      gone = false;
      _keep();
      _settleOutbox();
      _markSeen();
      _changed();
    } on Object catch (failure) {
      if (_disposed) return;
      final code = errorCode(failure);
      if (code == 'bot/not-found') {
        gone = true;
        _changed();
      } else if (code != 'link/offline') {
        loadError = failure;
        _changed();
      }
    } finally {
      _reading = false;
      if (_again && !_disposed) {
        _again = false;
        unawaited(refresh());
      }
    }
  }

  void _keep() {
    final page = _page;
    if (page != null) _pages.keep(chatKey, chatKey, CachedChat(page: page, older: _older, cursor: _cursor));
  }

  bool get hasMore => _cursorSet && _cursor != null;

  /// The page before the oldest one shown.
  Future<void> loadMore() async {
    if (!hasMore || _loadingMore || _disposed) return;
    _loadingMore = true;
    loadingOlder = true;
    _changed();
    try {
      final next = await _read(_cursor);
      if (_disposed) return;
      _cursor = next.cursor;
      _older = [...next.items, ..._older];
      _keep();
    } on Object {
      // Keep the page we have.
    } finally {
      _loadingMore = false;
      loadingOlder = false;
      _changed();
    }
  }

  void _onFeed(RpcEvent event) {
    if (_disposed) return;
    final data = event.data;
    switch (event.event) {
      case 'room':
        if (room && jStr(data, 'roomId') == id) unawaited(refresh());
      case 'message':
        if (jStr(data, 'sessionId') != sessionId) return;
        final item = jMap(data, 'item');
        final page = _page;
        if (item != null && page != null) {
          final seq = item['seq'];
          if (seq == null || !page.items.any((entry) => entry['seq'] == seq)) {
            _page = page.withItems([...page.items, item]);
            // The computer tells of the message before `send` answers: swap the
            // local row for it in the same frame, so it never shows twice.
            _keep();
            _settleOutbox();
            _changed();
          }
          final time = jInt(item, 'time');
          if (visible && time != null && time > 0) unawaited(seen.markSeen(hostId, id, time));
        }
        unawaited(refresh());
      case 'stream':
        if (jStr(data, 'sessionId') != sessionId) return;
        final attempt = jStr(data, 'attemptId') ?? '';
        final text = jStr(data, 'text');
        final phase = jStr(data, 'phase');
        if (phase == 'start') {
          _attempts[attempt] = '';
        } else if (text != null) {
          _attempts[attempt] = (_attempts[attempt] ?? '') + text;
        } else if (phase == 'end') {
          _attempts.remove(attempt);
        }
        // Each attempt is its own reply part; the saved message shows them as separate bubbles.
        streaming = _attempts.values.where((part) => part.isNotEmpty).join('\n\n');
        _changed();
    }
  }

  int get latestAt {
    var max = room ? (team.team?.room(id)?.lastAt ?? 0) : (team.team?.bot(id)?.lastAt ?? 0);
    for (final item in _page?.items ?? const <Json>[]) {
      final time = jInt(item, 'time');
      if (time != null && time > max) max = time;
    }
    return max;
  }

  void _markSeen() {
    final at = latestAt;
    if (visible && at > 0) unawaited(seen.markSeen(hostId, id, at));
  }

  void setVisible(bool value) {
    visible = value;
    if (value) _markSeen();
  }

  // Sending: the message shows at once; photos travel one by one, then the
  // message names them. It stays until the chat shows it back.
  void send(String text, {List<OutgoingPhoto> photos = const [], List<OutgoingFile> files = const []}) {
    final localId = '${DateTime.now().microsecondsSinceEpoch}';
    final entry = _Outgoing(
      {
        'kind': 'user',
        'text': text,
        'local': 'sending',
        'localId': localId,
        'time': DateTime.now().millisecondsSinceEpoch,
        'localImageCount': photos.length,
        if (files.isNotEmpty) 'files': [for (final file in files) {'name': file.name, 'bytes': file.bytes.length}],
      },
      photos,
      files,
      sessionId,
      keysOf(items).toSet(),
    );
    _outbox.putIfAbsent(chatKey, () => []).add(entry);
    _changed();
    unawaited(_deliver(chatKey, entry));
  }

  static void _notifyKey(String key) {
    for (final chat in _live) {
      if (chat.chatKey == key) chat._changed();
    }
  }

  Future<void> _deliver(String key, _Outgoing entry) async {
    void mark(String local) {
      entry.item = {...entry.item, 'local': local};
      _notifyKey(key);
    }

    mark('sending');
    try {
      final images = <String>[];
      for (final photo in entry.photos) {
        final staged = await team.call('stage-image', {'mediaType': photo.mediaType, 'data': photo.base64});
        images.add(jStr(staged, 'id') ?? '');
      }
      final files = <String>[];
      for (final file in entry.files) {
        files.add(await _stageFile(file));
      }
      final text = jStr(entry.item, 'text') ?? '';
      // The computer takes photos and files in separate messages: photos (and the
      // text) go first, then the files.
      if (images.isNotEmpty || files.isEmpty) {
        await team.call('send', {'sessionId': entry.sessionId, 'text': text, if (images.isNotEmpty) 'images': images});
      }
      if (files.isNotEmpty) {
        await team.call('send', {'sessionId': entry.sessionId, 'text': images.isEmpty ? text : '', 'files': files});
      }
      for (final chat in _live) {
        if (chat.chatKey == key) unawaited(chat.refresh());
      }
    } on Object catch (failure) {
      mark('failed');
      for (final chat in _live) {
        if (chat.chatKey == key) chat.loadError = failure;
      }
      _notifyKey(key);
    }
  }

  static const _uploadChunk = 512 * 1024;

  /// Uploads one file in chunks; the computer answers with an id `send` names.
  Future<String> _stageFile(OutgoingFile file) async {
    String? uploadId;
    var offset = 0;
    Json answer = const {};
    do {
      final end = offset + _uploadChunk < file.bytes.length ? offset + _uploadChunk : file.bytes.length;
      answer = asJson(await team.call('stage-file', {
        'name': file.name,
        'mediaType': file.mediaType,
        'size': file.bytes.length,
        'offset': offset,
        'uploadId': ?uploadId,
        'data': _b64(file.bytes.sublist(offset, end)),
      }));
      uploadId = jStr(answer, 'uploadId') ?? uploadId;
      offset = end;
    } while (offset < file.bytes.length);
    return jStr(answer, 'id') ?? uploadId ?? '';
  }

  void retry(String localId) {
    final entry = (_outbox[chatKey] ?? const []).where((item) => jStr(item.item, 'localId') == localId).firstOrNull;
    if (entry == null) return;
    loadError = null;
    unawaited(_deliver(chatKey, entry));
  }

  void discard(String localId) {
    _outbox[chatKey]?.removeWhere((item) => jStr(item.item, 'localId') == localId);
    if (_outbox[chatKey]?.isEmpty ?? false) _outbox.remove(chatKey);
    _changed();
  }

  /// A sent message leaves the outbox once the chat shows it back: a user row
  /// with its text, below every row the chat held when it was written. A row
  /// settles one message only, so the same text sent twice waits for two rows.
  void _settleOutbox() {
    final pending = _outbox[chatKey];
    if (pending == null || pending.isEmpty) return;
    final all = items;
    final keys = keysOf(all);
    for (final entry in [...pending]) {
      var index = all.length - 1;
      while (index >= 0 && !entry.known.contains(keys[index])) {
        index--;
      }
      for (index++; index < all.length; index++) {
        if (!entry.known.contains(keys[index]) && sameMessage(all[index], entry.item)) break;
      }
      if (index >= all.length) continue;
      pending.remove(entry);
      for (final other in pending) {
        other.known.add(keys[index]);
      }
    }
    if (pending.isEmpty) _outbox.remove(chatKey);
  }

  Future<void> stop() async {
    try {
      if (room) {
        await team.call('stop-room-work', {'roomId': id});
      } else {
        await team.call('stop-chat', {'botId': id});
      }
    } on Object {
      // The team state shows whether work stopped.
    }
  }
}

String _b64(List<int> bytes) => base64Encode(bytes);
