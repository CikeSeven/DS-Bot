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

/// A photo ready to send: shown from [bytes], sent as base64 of the type in [mediaType].
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

  static final Map<String, List<_Outgoing>> _outbox = {};
  static final Set<ChatSession> _live = {};

  ChatPageData? _page;
  List<Json> _older = [];
  Object? _cursor;
  bool gone = false;
  Object? loadError;
  bool loadingOlder = false;
  bool _loadingMore = false;
  bool _reading = false;
  bool _again = false;
  bool _disposed = false;
  bool visible = true;
  bool _wasOnline = false;
  int _chatSync = 0;
  int _linkGeneration = 0;
  int _historyVersion = 0;
  String? _knownSession;
  Timer? _timer;
  StreamSubscription<RpcEvent>? _feed;
  final Map<String, String> _attempts = {};
  final Map<String, List<Json>> _recalls = {};
  String? _streamSession;
  String streaming = '';
  List<ChatRow> _rows = const [];
  bool _rowsDirty = true;

  List<Json> get _pushed => room ? const [] : team.recentMessages(id);
  bool get loaded => _page != null || _pushed.isNotEmpty;

  String get sessionId {
    if (room) return team.team?.room(id)?.sessionId ?? id;
    final bot = team.team?.bot(id);
    final fromPage = _page?.sessionId;
    final pushed = _pushed;
    final fromFeed = _streamSession ?? (pushed.isEmpty ? null : jStr(pushed.last, 'sessionId'));
    if (fromFeed != null && !(bot?.parts.contains(fromFeed) ?? false) &&
        !_older.any((row) => row['sessionId'] == fromFeed && fromFeed != fromPage)) {
      return fromFeed;
    }
    if (bot != null && (fromPage == null || bot.parts.contains(fromPage))) return bot.chatSession;
    return fromPage ?? bot?.chatSession ?? id;
  }

  List<Json> get items {
    final saved = [..._older, ...?_page?.items].where((item) => !_isRecalled(item)).toList();
    final current = sessionId;
    for (final row in _pushed) {
      final part = jStr(row, 'sessionId');
      if (part == null || _isRecalled(row)) continue;
      final seq = jInt(row, 'seq');
      final first = _page?.firstSeq;
      final last = _page?.lastSeq;
      if (part == _page?.partSessionId && seq != null && first != null && last != null && seq >= first && seq <= last) continue;
      if (saved.any((item) => samePushedRow(item, row))) continue;
      // An event from a part that already ended belongs above the next part.
      final end = saved.lastIndexWhere((item) {
        if (item['sessionId'] != part) return false;
        final otherSeq = jInt(item, 'seq');
        return seq == null || otherSeq == null || otherSeq <= seq;
      });
      if (end >= 0) {
        saved.insert(end + 1, row);
      } else if (part == current) {
        saved.add(row);
      }
    }
    return saved;
  }

  bool _isRecalled(Json row) {
    final seq = jInt(row, 'seq');
    final part = jStr(row, 'sessionId');
    if (seq == null || part == null || row['kind'] == 'recalled') return false;
    final ranges = [...?_recalls[part], ...jMaps(jMap(team.team?.raw, 'recalls'), part)];
    return ranges.any((range) => seq >= (jInt(range, 'seq') ?? seq + 1) && seq < (jInt(range, 'until') ?? seq));
  }

  List<ChatRow> get rows {
    if (!_rowsDirty) return _rows;
    final outgoing = _outbox[chatKey] ?? const [];
    // Tool steps stay off the phone's list; what a Bot does shows only while it works.
    final all = groupActs([...items, ...outgoing.map((entry) => entry.item)].where((item) => jStr(item, 'kind') != 'steps').toList());
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
    final cached = team.chatPages.get(chatKey);
    if (cached != null) {
      _page = cached.page;
      _older = [...cached.older];
      _cursor = cached.cursor;
    }
    _wasOnline = team.online;
    _chatSync = team.chatSync;
    _linkGeneration = team.linkGeneration;
    _knownSession = room ? null : team.team?.bot(id)?.sessionId;
    team.addListener(_onTeam);
    _feed = team.feed.listen(_onFeed);
    scheduleMicrotask(() {
      if (!_disposed) _markSeen();
    });
    unawaited(_loop());
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
    final current = room ? null : team.team?.bot(id)?.sessionId;
    final switched = current != _knownSession;
    final sync = _chatSync != team.chatSync;
    final reset = _linkGeneration != team.linkGeneration;
    if (reset) _historyVersion++;
    _chatSync = team.chatSync;
    _linkGeneration = team.linkGeneration;
    _knownSession = current;
    if (reset || (switched && current != _streamSession)) _clearStreaming();
    if (sync || switched || reset) _changed();
    if (team.online && (!_wasOnline || switched || sync)) unawaited(refresh());
    _wasOnline = team.online;
  }

  Future<ChatPageData> _read([Object? cursor]) async {
    final value = room
        ? await team.call('room-chat', {'roomId': id, 'cursor': ?cursor})
        : await team.call('chat', {'botId': id, 'cursor': ?cursor});
    final map = asJson(value);
    final current = jStr(map, 'sessionId');
    final parts = team.team?.bot(id)?.parts ?? const <String>[];
    final index = jInt(cursor, 'part');
    final part = jStr(map, 'partSessionId') ?? (index != null && index >= 0 && index < parts.length ? parts[index] : current);
    return ChatPageData(
      sessionId: current,
      partSessionId: part,
      firstSeq: jInt(map, 'firstSeq'),
      lastSeq: jInt(map, 'lastSeq'),
      items: [for (final row in jMaps(map, 'items')) if (part == null) row else {...row, 'sessionId': part}],
      cursor: map['cursor'],
    );
  }

  bool _touches(ChatPageData fresh, ChatPageData previous) {
    if (fresh.partSessionId != previous.partSessionId) return false;
    final last = previous.lastSeq;
    final first = fresh.firstSeq;
    return last == null || first == null || first <= last + 1;
  }

  Future<void> _updateHistory(ChatPageData next, int version) async {
    final prev = _page;
    final pages = <ChatPageData>[next];
    var oldest = next;
    // A rollover or a large burst can put a whole page between the old and new
    // heads. Fill the gap before joining them so the scroll cursor stays valid.
    while (!room && prev != null && !_touches(oldest, prev) && oldest.cursor != null && pages.length < 8) {
      final cursor = oldest.cursor;
      oldest = await _read(cursor);
      if (_disposed || version != _historyVersion) return;
      pages.add(oldest);
      if (mapEquals(asJson(cursor), asJson(oldest.cursor))) break;
    }
    final prefix = <Json>[];
    if (prev != null) {
      if (room) {
        prefix.addAll(_older);
      } else if (_touches(oldest, prev)) {
        final before = jInt(oldest.cursor, 'beforeSeq');
        final firstTime = oldest.items.map((row) => jInt(row, 'time')).whereType<int>().firstOrNull;
        for (final row in [..._older, ...prev.items]) {
          if (row['sessionId'] != oldest.partSessionId) {
            prefix.add(row);
          } else if (before != null) {
            final seq = jInt(row, 'seq');
            final time = jInt(row, 'time');
            if (seq != null ? seq < before : time != null && firstTime != null && time < firstTime) prefix.add(row);
          }
        }
      }
    }
    if (prefix.isEmpty) _cursor = oldest.cursor;
    _older = [...prefix, for (final page in pages.skip(1).toList().reversed) ...page.items];
    _page = prev != null && prev.partSessionId == next.partSessionId ? next.withItems(keepSame(prev.items, next.items)) : next;
    if (prev != null && prev.sessionId != next.sessionId && _streamSession != next.sessionId) _clearStreaming();
  }

  /// One chat read at a time: a burst of messages becomes one read now and at
  /// most one more after it.
  Future<void> refresh() async {
    if (_disposed || id.isEmpty || !team.linked) return;
    if (_reading || _loadingMore) {
      _again = true;
      return;
    }
    _reading = true;
    final version = _historyVersion;
    try {
      final next = await _read();
      if (_disposed || version != _historyVersion) return;
      await _updateHistory(next, version);
      if (_disposed || version != _historyVersion) return;
      loadError = null;
      gone = false;
      _keep();
      _settleOutbox();
      _markSeen();
      _changed();
    } on Object catch (failure) {
      if (_disposed || version != _historyVersion) return;
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
      } else if (!room && hasMore && _older.isEmpty && (_page?.items.length ?? 0) < 12 &&
          jInt(_cursor, 'beforeSeq') == null) {
        unawaited(loadMore());
      }
    }
  }

  Future<void> reload() async {
    if (_disposed) return;
    _historyVersion++;
    _clearStreaming();
    _changed();
    await refresh();
  }

  void _clearStreaming() {
    _attempts.clear();
    _streamSession = null;
    streaming = '';
  }

  void _keep() {
    final page = _page;
    if (page != null) team.chatPages.keep(chatKey, chatKey, CachedChat(page: page, older: _older, cursor: _cursor));
  }

  bool get hasMore => _cursor != null;

  /// The page before the oldest one shown.
  Future<void> loadMore() async {
    if (!hasMore || _loadingMore || _reading || _disposed || !team.linked) return;
    _loadingMore = true;
    final version = _historyVersion;
    loadingOlder = true;
    _changed();
    try {
      for (var count = 0; count < 8 && _cursor != null; count++) {
        final cursor = _cursor;
        final next = await _read(cursor);
        if (_disposed || version != _historyVersion) return;
        _cursor = next.cursor;
        _older = [...next.items, ..._older];
        if (room || next.items.any((row) => row['kind'] != 'divider') || mapEquals(asJson(cursor), asJson(_cursor))) break;
      }
      _keep();
    } on Object {
      // Keep the page we have.
    } finally {
      _loadingMore = false;
      loadingOlder = false;
      _changed();
      if (_again && !_disposed) {
        _again = false;
        unawaited(refresh());
      }
    }
  }

  void _onFeed(RpcEvent event) {
    if (_disposed) return;
    final data = event.data;
    switch (event.event) {
      case 'room':
        if (room && jStr(data, 'roomId') == id) unawaited(refresh());
      case 'recall':
        final part = jStr(data, 'sessionId');
        if (!room && jStr(data, 'botId') == id && part != null) {
          _recalls.putIfAbsent(part, () => []).add(asJson(data));
          unawaited(reload());
        }
      case 'message':
        if (room || jStr(data, 'botId') != id) return;
        _settleOutbox();
        _markSeen();
        _changed();
        unawaited(refresh());
      case 'stream':
        if (room || jStr(data, 'botId') != id) return;
        final part = jStr(data, 'sessionId');
        if (part == null || (team.team?.bot(id)?.parts.contains(part) ?? false)) return;
        if (_streamSession != part) {
          _clearStreaming();
          _streamSession = part;
        }
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
        notifyListeners();
    }
  }

  int get latestAt {
    var max = room ? (team.team?.room(id)?.lastAt ?? 0) : 0;
    for (final item in items) {
      if (!room && !const {'bot', 'user', 'answer', 'post', 'view'}.contains(jStr(item, 'kind'))) continue;
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
        await team.call('send', {'sessionId': id, 'text': text, if (images.isNotEmpty) 'images': images});
      }
      if (files.isNotEmpty) {
        await team.call('send', {'sessionId': id, 'text': images.isEmpty ? text : '', 'files': files});
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
        if (!entry.known.contains(keys[index]) && sameMessage(all[index], entry.item) &&
            (room || all[index]['sessionId'] == entry.sessionId || all[index]['sessionId'] == sessionId)) {
          break;
        }
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
