// Port of the Expo app's src/team/link.ts (useTeamLink): follows the link to one computer,
// keeps the team state fresh, and runs every /api/bot call. The link reconnects
// and resumes by itself; a session reads everything again only after a new
// handshake. Plain Dart with listeners, so it runs the same in tests, in the UI
// and in a background isolate.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/link_client.dart';
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

/// The computer no longer takes this phone: only pairing again helps.
bool isRejected(Object? error) {
  final code = error is BotError ? error.code : (error is LinkError ? error.code : null);
  return code == 'NOT_PAIRED' || code == 'PAIRING_REJECTED' || code == 'DEVICE_REVOKED' || code == 'PEER_IDENTITY_MISMATCH';
}

String? errorCode(Object? error) => error is BotError ? error.code : (error is LinkError ? error.code : null);

class TeamSession extends ChangeNotifier {
  TeamSession({
    required this.computer,
    required this.identity,
    required this.open,
    this.unlocker = const AlwaysUnlocked(),
    this.pollEvery = const Duration(seconds: 15),
  });

  final SavedComputer computer;
  final PhoneIdentity identity;
  final LinkOpener open;
  final Unlocker unlocker;

  /// Also how long a hello that failed in transit waits before it goes again.
  final Duration pollEvery;

  // Profile photos travel by reference and are fetched once per content hash.
  static final Map<String, String> _photoCache = {};
  final Set<String> _photoFetching = {};

  TeamState? _team;
  bool _online = false;
  LinkStatus _link = LinkStatus.connecting;
  Object? _error;
  Hello? _hello;
  LinkClient? _client;
  StreamSubscription<LinkStatus>? _statuses;
  Unsubscribe? _events;
  int _revision = -1;
  String? _liveKey;
  final List<Write> _writes = [];
  final NoticeCursor _notices = NoticeCursor();
  final StreamController<RpcEvent> _feed = StreamController.broadcast();
  Timer? _timer;
  Timer? _helloTimer;
  final Completer<void> _opened = Completer();
  bool _stopped = true;
  bool _reading = false;
  bool _again = false;
  bool _background = false;

  TeamState? get team => _team;

  /// The link is up and hello said the computer's DS Bot is current.
  bool get online => _online;

  /// The encrypted link is up (calls can go), before hello says the computer is current.
  bool get linked => _link.online;

  /// The Server is reachable but the computer is not on it.
  bool get computerAway => _link.phase == LinkPhase.hostAway;

  /// This phone lost the Server (its network, or the Server); the link is coming back.
  bool get reconnecting => _link.phase == LinkPhase.connecting || _link.phase == LinkPhase.reconnecting;
  Object? get error => _error;
  Hello? get hello => _hello;
  String? get hostName => _client?.hostName;

  /// Every feed event from the computer: message, stream, notice, room, live, revision.
  Stream<RpcEvent> get feed => _feed.stream;

  bool has(String capability) => _hello?.has(capability) ?? false;

  /// Completes once the link is opened (not connected): from then on another
  /// handle on the same computer can close without ending this session's link.
  Future<void> get opened => _opened.future;

  Json get _stateQuery => {'since': _revision, 'avatars': 'ref', if (_liveKey != null) 'live': _liveKey};

  void start() {
    if (!_stopped) return;
    _stopped = false;
    unawaited(_open());
  }

  Future<void> stop() async {
    _stopped = true;
    if (!_opened.isCompleted) _opened.complete();
    _timer?.cancel();
    _helloTimer?.cancel();
    final client = _client;
    _drop();
    await client?.close();
  }

  void _drop() {
    unawaited(_statuses?.cancel());
    _statuses = null;
    _events?.call();
    _events = null;
    _client = null;
  }

  @override
  void dispose() {
    unawaited(stop());
    unawaited(_feed.close());
    super.dispose();
  }

  void _set({TeamState? team, bool clearTeam = false, bool? online, Object? error, bool clearError = false, Hello? hello}) {
    if (team != null || clearTeam) _team = team;
    if (online != null) _online = online;
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
      if (errorCode(failure) == 'CLIENT_CLOSED') throw offlineError();
      rethrow;
    }
  }

  void refresh() => unawaited(_poll());

  /// The link checks itself on waking; the team is read again at once. In the
  /// background only the periodic read stops: the link stays as it is.
  void setForeground(bool foreground) {
    _background = !foreground;
    _client?.setForeground(foreground);
    if (foreground) {
      unawaited(_poll());
    } else {
      _timer?.cancel();
    }
  }

  void networkChanged() => _client?.networkChanged();

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
      // Before hello the error is hello's to clear: an outdated computer still answers reads.
      _set(clearError: _hello != null);
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

  Future<void> _open() async {
    final LinkClient client;
    try {
      client = await open(computer, identity);
    } on Object catch (failure) {
      if (!_opened.isCompleted) _opened.complete();
      if (!_stopped) _set(error: failure);
      return;
    }
    if (!_opened.isCompleted) _opened.complete();
    if (_stopped) {
      unawaited(client.close());
      return;
    }
    _client = client;
    _events = client.onEvent((event) => _onEvent(client, event));
    _statuses = client.statuses.listen((status) => _onStatus(client, status));
    _onStatus(client, client.status);
  }

  void _onStatus(LinkClient client, LinkStatus status) {
    if (_stopped || !identical(_client, client)) return;
    _link = status;
    switch (status.phase) {
      case LinkPhase.online:
        // A resumed link lost nothing; a new handshake, or the first one this
        // session sees, reads everything again.
        if (status.resumed && _hello != null) {
          _set(online: true);
          unawaited(_poll());
        } else {
          unawaited(_sync(client));
        }
      case LinkPhase.connecting || LinkPhase.reconnecting || LinkPhase.hostAway:
        _set(online: false);
      case LinkPhase.rejected:
        final failure = LinkError(status.code, status.message ?? 'The computer does not accept this phone.');
        _set(online: false, error: failure, clearTeam: isRejected(failure));
      case LinkPhase.closed:
        // Someone else ended this session (a new pairing with the same
        // computer): join the one that replaced it.
        _drop();
        _set(online: false);
        unawaited(_open());
    }
  }

  void _onEvent(LinkClient client, RpcEvent event) {
    final hello = _hello;
    if (_stopped || !identical(_client, client) || hello == null) return;
    if (event.event == 'notice' && !_notices.acceptLive(hello.boot, event.data)) return;
    if (event.event == 'revision' || event.event == 'live') unawaited(_poll());
    _feed.add(event);
  }

  /// hello, the team and missed notices, after a new handshake.
  Future<void> _sync(LinkClient client) async {
    _helloTimer?.cancel();
    _hello = null;
    // hello says whether the computer's DS Bot is current: api is null when it
    // is too old for this app. The team read goes out with it, not after it:
    // each is a round trip through the Relay.
    unawaited(_poll());
    final Object? answer;
    try {
      answer = await callBot(client, 'hello', {
        'api': [1],
        'client': {'name': 'dsbot-flutter', 'platform': defaultTargetPlatform.name},
      });
    } on Object catch (failure) {
      if (_stopped || !identical(_client, client)) return;
      // Lost in transit, not an old computer: try again while the link is up.
      _set(error: failure);
      _helloTimer = Timer(pollEvery, () {
        if (!_stopped && identical(_client, client) && _link.online && _hello == null) unawaited(_sync(client));
      });
      return;
    }
    if (_stopped || !identical(_client, client)) return;
    final hello = answer is Map<String, dynamic> ? Hello(answer) : null;
    if (hello == null || hello.api == null) {
      _set(error: BotError('link/outdated', 'Update DS Bot on the computer to use this phone.'), online: false);
      return;
    }
    _hello = hello;
    _set(hello: hello, online: true, clearError: true);
    final cursor = _notices.connect(boot: hello.boot, seq: hello.seq);
    callBot(client, 'notices', {'boot': hello.boot, 'since': cursor.since}).then((answer) {
      if (_stopped || !identical(_client, client)) return;
      final catchUp = _notices.acceptCatchUp(hello.boot, answer);
      if (catchUp.reset || catchUp.replay.isNotEmpty) unawaited(_poll());
      if (!catchUp.reset) {
        for (final entry in catchUp.replay) {
          _feed.add(RpcEvent('notice', entry));
        }
      }
    }).catchError((Object _) {});
  }
}

BotError offlineError() => BotError('link/offline', 'Not connected to the computer yet.');
