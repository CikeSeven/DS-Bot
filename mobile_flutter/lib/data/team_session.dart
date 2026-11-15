// Port of mobile/src/team/link.ts (useTeamLink): keeps the link to one computer
// up and the team state fresh, and runs every /api/bot call. Plain Dart with
// listeners, so it runs the same in tests, in the UI and in a background isolate.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/link_client.dart';
import '../link/link.dart';
import 'gate.dart';
import 'json.dart';
import 'notices.dart';
import 'optimistic.dart';
import 'team_state.dart';

/// Writes that settle pending items without always bumping state.revision.
const _pendingMutating = {
  'approval-answer',
  'browser-give-back',
  'browser-takeover',
  'browser-stop',
  'answer-question',
  'view-reply',
  'dismiss-question',
  'dismiss-view',
  'secret-set',
  'secret-allow',
  'secret-cancel',
  'computer-app-answer',
  'learning-answer',
};

const _plainReads = {'state', 'hello', 'notices'};

class Hello {
  Hello(this.raw);

  final Json raw;

  int? get api => jInt(raw, 'api');
  List<String> get capabilities => jStrings(raw, 'capabilities');
  String get boot => jStr(raw, 'boot') ?? '';
  int get seq => jInt(raw, 'seq') ?? 0;
  String? get pluginVersion => jStr(jMap(raw, 'plugin'), 'version');

  bool has(String capability) => capabilities.contains(capability);
}

bool isRejected(Object? error) {
  final code = error is BotError ? error.code : (error is LinkError ? error.code : null);
  return code == 'NOT_PAIRED' || code == 'PAIRING_REJECTED';
}

String? errorCode(Object? error) => error is BotError ? error.code : (error is LinkError ? error.code : null);

class TeamSession extends ChangeNotifier {
  TeamSession({
    required this.computer,
    required this.identity,
    required this.open,
    this.unlocker = const AlwaysUnlocked(),
    this.pollEvery = const Duration(seconds: 15),
    this.retryAfter = const Duration(seconds: 2),
  });

  final SavedComputer computer;
  final PhoneIdentity identity;
  final LinkOpener open;
  final Unlocker unlocker;
  final Duration pollEvery;
  final Duration retryAfter;

  // Profile photos travel by reference and are fetched once per content hash.
  static final Map<String, String> _photoCache = {};
  final Set<String> _photoFetching = {};

  TeamState? _team;
  bool _online = false;
  bool _linked = false;
  Object? _error;
  Hello? _hello;
  LinkClient? _client;
  int _revision = -1;
  String? _liveKey;
  final List<Write> _writes = [];
  final NoticeCursor _notices = NoticeCursor();
  final StreamController<RpcEvent> _feed = StreamController.broadcast();
  Timer? _timer;
  bool _stopped = true;
  bool _reading = false;
  bool _again = false;
  bool _background = false;

  TeamState? get team => _team;
  bool get online => _online;

  /// The encrypted link is up (calls can go), before hello says the computer is current.
  bool get linked => _linked;
  Object? get error => _error;
  Hello? get hello => _hello;
  String? get hostName => _client?.hostName;

  /// Every feed event from the computer: message, stream, notice, room, live, revision.
  Stream<RpcEvent> get feed => _feed.stream;

  bool has(String capability) => _hello?.has(capability) ?? false;

  Json get _stateQuery => {'since': _revision, 'avatars': 'ref', if (_liveKey != null) 'live': _liveKey};

  void start() {
    if (!_stopped) return;
    _stopped = false;
    unawaited(_connect());
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    final client = _client;
    _client = null;
    await client?.close();
  }

  @override
  void dispose() {
    unawaited(stop());
    unawaited(_feed.close());
    super.dispose();
  }

  void _set({TeamState? team, bool clearTeam = false, bool? online, bool? linked, Object? error, bool clearError = false, Hello? hello}) {
    if (team != null || clearTeam) _team = team;
    if (online != null) _online = online;
    if (linked != null) _linked = linked;
    if (error != null || clearError) _error = error;
    if (hello != null) _hello = hello;
    if (!_stopped) notifyListeners();
  }

  void _later(Duration delay, void Function() run) {
    _timer?.cancel();
    if (!_stopped) _timer = Timer(delay, run);
  }

  /// One place every state answer goes through. An older in-flight poll must
  /// not overwrite a newer write reply.
  void _apply(Json raw) {
    final next = TeamState(raw);
    if (next.revision < _revision) return;
    _revision = next.revision;
    final live = next.liveKey;
    if (live != null) _liveKey = live;
    final prev = _team;
    final merged = prev != null ? prev.mergedWith(next) : next;
    _set(team: _fillPhotos(withWrites(merged, _writes), prev));
  }

  /// Every Bot whose photo came as a ref gets the cached image, or keeps the
  /// previous team's photo while the fetch runs: never a blank avatar.
  TeamState _fillPhotos(TeamState team, TeamState? prev) {
    var changed = false;
    final bots = jMaps(team.raw, 'bots').map((bot) {
      final avatar = jMap(bot, 'avatar');
      final ref = jStr(avatar, 'imageRef');
      if (ref == null) return bot;
      final cached = _photoCache[ref];
      if (cached != null) {
        if (jStr(avatar, 'image') == cached) return bot;
        changed = true;
        return {...bot, 'avatar': {...?avatar, 'image': cached}};
      }
      _fetchPhoto(jStr(bot, 'id') ?? '', ref);
      final kept = prev?.bot(jStr(bot, 'id'))?.image;
      if (kept == null || kept == jStr(avatar, 'image')) return bot;
      changed = true;
      return {...bot, 'avatar': {...?avatar, 'image': kept}};
    }).toList();
    return changed ? TeamState({...team.raw, 'bots': bots}) : team;
  }

  void _fetchPhoto(String botId, String ref) {
    final client = _client;
    if (client == null || _photoFetching.contains(ref)) return;
    _photoFetching.add(ref);
    callBot(client, 'avatar', {'botId': botId}).then((answer) {
      final image = jStr(answer, 'image');
      if (image != null) _photoCache[jStr(answer, 'ref') ?? ref] = image;
      final team = _team;
      if (team != null) _set(team: _fillPhotos(team, team));
    }).catchError((Object _) {}).whenComplete(() => _photoFetching.remove(ref));
  }

  /// Runs one endpoint on the computer. Writes show their effect at once; the
  /// reply's state (or a full reload on failure) puts the computer's truth back.
  Future<Object?> call(String endpoint, [Json payload = const {}]) async {
    final client = _client;
    if (client == null) throw offlineError();
    await ensureUnlock(unlocker, endpoint);
    if (!identical(_client, client)) throw offlineError();
    try {
      if (_plainReads.contains(endpoint)) return await callBot(client, endpoint, payload);
      final write = Write(endpoint, payload);
      if (optimisticEndpoints.contains(endpoint)) _writes.add(write);
      final guessed = optimistic(_team, endpoint, payload);
      if (guessed != null && !identical(guessed, _team)) _set(team: guessed);
      try {
        final answer = await callBotState(client, endpoint, payload, _stateQuery);
        _writes.remove(write);
        if (answer.state != null && identical(_client, client)) {
          _apply(answer.state!);
        } else if (_pendingMutating.contains(endpoint) && identical(_client, client)) {
          unawaited(_poll());
        }
        return answer.value;
      } finally {
        _writes.remove(write);
      }
    } on Object catch (failure) {
      // Snap back to the computer's truth: forget the revision and re-read all.
      if (optimisticEndpoints.contains(endpoint) && identical(_client, client)) {
        _revision = -1;
        unawaited(_poll());
      }
      if (errorCode(failure) == 'TRANSPORT_CLOSED') throw offlineError();
      rethrow;
    }
  }

  void refresh() => unawaited(_poll());

  /// Waking is the common half-open case: probe first so a dead socket declares
  /// itself instead of letting the poll hang.
  void setForeground(bool foreground) {
    _background = !foreground;
    if (foreground) {
      _client?.probe();
      unawaited(_poll());
    } else {
      _timer?.cancel();
    }
  }

  /// One read at a time: a burst of feed events becomes one read now and at most
  /// one more after it, not a pile of reads over a slow link.
  Future<void> _poll() async {
    final client = _client;
    if (_stopped || client == null) return;
    if (_reading) {
      _again = true;
      return;
    }
    _reading = true;
    try {
      final next = await callBot(client, 'state', _stateQuery);
      if (_stopped || !identical(_client, client)) return;
      if (next is Map<String, dynamic>) _apply(next);
      _set(clearError: true);
    } on Object catch (failure) {
      if (!_stopped && identical(_client, client)) _set(error: failure);
    } finally {
      _reading = false;
      if (!_stopped && identical(_client, client)) {
        if (_again) {
          _again = false;
          unawaited(_poll());
        } else if (!_background) {
          _later(pollEvery, () => unawaited(_poll()));
        }
      } else {
        _again = false;
      }
    }
  }

  Future<void> _connect() async {
    if (_stopped) return;
    try {
      final client = await open(computer, identity);
      if (_stopped) {
        unawaited(client.close());
        return;
      }
      _client = client;
      _set(linked: true);
      // hello is the handshake: api is null when the computer's DS Bot is too old
      // for this app. The team read goes out with it, not after it: each is a
      // round trip through the Relay.
      unawaited(_poll());
      Hello? hello;
      try {
        final answer = await callBot(client, 'hello', {
          'api': [1],
          'client': {'name': 'dsbot-flutter', 'platform': defaultTargetPlatform.name},
        });
        if (answer is Map<String, dynamic>) hello = Hello(answer);
      } on Object {
        hello = null;
      }
      if (_stopped) {
        unawaited(client.close());
        return;
      }
      if (hello == null || hello.api == null) {
        if (identical(_client, client)) _client = null;
        _set(error: BotError('link/outdated', 'Update DS Bot on the computer to use this phone.'), linked: false);
        unawaited(client.close());
        _later(retryAfter, () => unawaited(_connect()));
        return;
      }
      final helloNow = hello;
      _set(hello: helloNow, online: true, clearError: true);
      final cursor = _notices.connect(boot: helloNow.boot, seq: helloNow.seq);
      client.onEvent((event) {
        if (_stopped || !identical(_client, client)) return;
        if (event.event == 'notice' && !_notices.acceptLive(helloNow.boot, event.data)) return;
        if (event.event == 'revision' || event.event == 'live') unawaited(_poll());
        _feed.add(event);
      });
      callBot(client, 'notices', {'boot': helloNow.boot, 'since': cursor.since}).then((answer) {
        if (_stopped || !identical(_client, client)) return;
        final catchUp = _notices.acceptCatchUp(helloNow.boot, answer);
        if (catchUp.reset || catchUp.replay.isNotEmpty) unawaited(_poll());
        if (!catchUp.reset) {
          for (final entry in catchUp.replay) {
            _feed.add(RpcEvent('notice', entry));
          }
        }
      }).catchError((Object _) {});
      client.onClose(() {
        if (_stopped || !identical(_client, client)) return;
        _client = null;
        _set(online: false, linked: false);
        _timer?.cancel();
        _later(retryAfter, () => unawaited(_connect()));
      });
    } on Object catch (failure) {
      if (_stopped) return;
      _set(error: failure);
      if (isRejected(failure)) {
        _set(clearTeam: true);
      } else {
        _later(retryAfter, () => unawaited(_connect()));
      }
    }
  }
}

BotError offlineError() => BotError('link/offline', 'Not connected to the computer yet.');
