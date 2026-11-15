// The app's own state: the phone identity, the paired computers, local prefs,
// read times, and the live session with the active computer.
import 'dart:async';

import 'package:flutter/material.dart';

import '../api/link_client.dart';
import '../data/demo_link.dart';
import '../data/gate.dart';
import '../data/seen.dart';
import '../data/store.dart';
import '../data/team_session.dart';
import '../link/link.dart';
import '../ui/i18n.dart';
import 'platform.dart';

class AppPrefs {
  const AppPrefs({
    this.themeMode = ThemeMode.system,
    this.lang = LangPref.system,
    this.banners = true,
    this.glass = true,
    this.keepConnected = false,
    this.enterToSend = false,
    this.welcomed = false,
  });

  factory AppPrefs.from(Map<String, String> raw) => AppPrefs(
        themeMode: switch (raw['theme']) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        lang: switch (raw['lang']) {
          'zh' => LangPref.zh,
          'en' => LangPref.en,
          _ => LangPref.system,
        },
        banners: raw['banners'] != 'off',
        glass: raw['glass'] != 'off',
        keepConnected: raw['keepConnected'] == 'on',
        enterToSend: raw['enterToSend'] == 'on',
        welcomed: raw['welcomed'] == 'on',
      );

  final ThemeMode themeMode;
  final LangPref lang;
  final bool banners;
  final bool glass;
  final bool keepConnected;
  final bool enterToSend;

  /// The welcome page has been seen; it shows once per install.
  final bool welcomed;
}

/// Opens the link once with the pairing code inside the handshake.
typedef PairOpener = Future<LinkClient> Function(SavedComputer candidate, PhoneIdentity identity, String pairingCode);

Future<LinkClient> _openRelayPair(SavedComputer candidate, PhoneIdentity identity, String pairingCode) async =>
    RelayLinkClient.open(candidate, identity, pairingCode: pairingCode, phoneName: await phoneName());

/// A computer that accepted this phone, not saved yet.
class PairedComputer {
  const PairedComputer(this.offer, this.hostName);

  final PairingOffer offer;
  final String? hostName;

  /// The name it is saved under: the pairing code's, else the one the computer gave.
  String get name => offer.name.isNotEmpty ? offer.name : (hostName ?? '');
}

class AppState extends ChangeNotifier {
  AppState._(this.store, this.seen, this.identity, this._computers, this._prefs, {this.demo, PairOpener? pairOpener, LinkOpener? sessionOpener})
      : _openPair = pairOpener ?? _openRelayPair,
        _openSession = sessionOpener;

  final PhoneStore store;
  final SeenStore seen;
  final PhoneIdentity identity;
  final DemoLinkClient? demo;
  final PairOpener _openPair;
  final LinkOpener? _openSession;
  ComputerList _computers;
  AppPrefs _prefs;
  TeamSession? _session;

  /// Set when the app should open the pairing screen with this link filled in.
  String? pendingPairLink;

  static Future<AppState> load({
    KeyValueStore? kv,
    Map<String, dynamic>? demoData,
    PairOpener? pairOpener,
    LinkOpener? sessionOpener,
  }) async {
    final store = PhoneStore(kv ?? SecureKeyValueStore());
    final seen = SeenStore(store.kv);
    final identity = await store.loadIdentity();
    final computers = demoData != null
        ? const ComputerList('d-demo', [SavedComputer(server: 'wss://demo.invalid/v1/link', hostDeviceId: 'd-demo', hostKey: '', name: 'Demo computer')])
        : await store.listComputers();
    final prefs = AppPrefs.from(await store.readPrefs());
    I18n.pref = prefs.lang;
    await seen.load();
    final state = AppState._(store, seen, identity, computers, prefs, demo: demoData == null ? null : DemoLinkClient(demoData), pairOpener: pairOpener, sessionOpener: sessionOpener);
    state._startSession();
    return state;
  }

  ComputerList get computers => _computers;
  SavedComputer? get computer => _computers.active;
  AppPrefs get prefs => _prefs;
  TeamSession? get session => _session;

  void _startSession() {
    final previous = _session;
    _session = null;
    if (previous != null) {
      unawaited(previous.stop().whenComplete(previous.dispose));
    }
    final computer = this.computer;
    if (computer == null) return;
    final demo = this.demo;
    final session = TeamSession(
      computer: computer,
      identity: identity,
      unlocker: demo != null ? const AlwaysUnlocked() : DeviceUnlocker(),
      open: demo != null
          ? (computer, identity, {pairingCode}) async => demo
          : _openSession ??
              (computer, identity, {pairingCode}) async =>
                  RelayLinkClient.open(computer, identity, pairingCode: pairingCode, phoneName: await phoneName()),
    );
    _session = session;
    session.start();
  }

  /// The welcome page: a fresh install with nothing paired and no link to open.
  bool get showWelcome =>
      demo == null && _session == null && pendingPairLink == null && _computers.computers.isEmpty && !_prefs.welcomed;

  Future<void> finishWelcome() => setPrefs({'welcomed': 'on'});

  /// Back from the first pairing screen to the welcome page.
  Future<void> reopenWelcome() => setPrefs({'welcomed': 'off'});

  /// Opens the link in a pairing link once, with the code inside the encrypted
  /// handshake. Nothing is saved until [adopt].
  Future<PairedComputer> connect(String link) async {
    final offer = parsePairingUri(link);
    final client = await _openPair(SavedComputer.fromOffer(offer), identity, offer.code);
    final hostName = client.hostName;
    await client.close();
    return PairedComputer(offer, hostName);
  }

  /// Saves a computer that accepted this phone and switches to it.
  Future<SavedComputer> adopt(PairedComputer paired) async {
    final saved = await store.addComputer(paired.offer, name: paired.hostName);
    _computers = await store.listComputers();
    pendingPairLink = null;
    _startSession();
    notifyListeners();
    return saved;
  }

  Future<SavedComputer> pair(String link) async => adopt(await connect(link));

  Future<void> switchTo(String hostDeviceId) async {
    if (hostDeviceId == computer?.hostDeviceId) return;
    await store.setActiveComputer(hostDeviceId);
    _computers = await store.listComputers();
    _startSession();
    notifyListeners();
  }

  Future<void> forget(String hostDeviceId) async {
    await store.removeComputer(hostDeviceId);
    final wasActive = hostDeviceId == computer?.hostDeviceId;
    _computers = await store.listComputers();
    if (wasActive) _startSession();
    notifyListeners();
  }

  Future<void> setPrefs(Map<String, String> patch) async {
    await store.writePrefs(patch);
    _prefs = AppPrefs.from(await store.readPrefs());
    I18n.pref = _prefs.lang;
    notifyListeners();
  }

  /// Opens the pairing screen, with [link] filled in and sent when given.
  void openPairLink([String link = '']) {
    pendingPairLink = link;
    // A pairing link stands in for the welcome page, now and later.
    if (link.isNotEmpty && !_prefs.welcomed) unawaited(finishWelcome());
    notifyListeners();
  }

  void cancelPairing() {
    pendingPairLink = null;
    notifyListeners();
  }

  void setForeground(bool foreground) => _session?.setForeground(foreground);

  /// Keeps the link up in the background (Android foreground service), so
  /// questions and approvals arrive as system notifications.
  Future<void> setKeepConnected(bool on) async {
    await setPrefs({'keepConnected': on ? 'on' : 'off'});
    await onKeepConnectedChanged?.call(on);
  }

  /// Set by the background module once it is wired up.
  static Future<void> Function(bool on)? onKeepConnectedChanged;

  @override
  void dispose() {
    final session = _session;
    _session = null;
    if (session != null) unawaited(session.stop().whenComplete(session.dispose));
    super.dispose();
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

/// The live session with the active computer. Widgets that read it rebuild on
/// every team change; use [TeamScope.read] in callbacks.
class TeamScope extends InheritedNotifier<TeamSession> {
  const TeamScope({super.key, required TeamSession session, required super.child}) : super(notifier: session);

  static TeamSession of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TeamScope>()!.notifier!;

  static TeamSession read(BuildContext context) => context.getInheritedWidgetOfExactType<TeamScope>()!.notifier!;
}

/// Runs a call on the computer and shows its error as a toast; a cancelled
/// unlock stays quiet. Returns null on failure.
Future<Object?> run(BuildContext context, String endpoint, [Map<String, dynamic> payload = const {}]) async {
  final session = TeamScope.read(context);
  try {
    return await session.call(endpoint, payload);
  } on Object catch (error) {
    if (isUnlockCancel(error)) return null;
    if (context.mounted) _showError(context, error);
    return null;
  }
}

void _showError(BuildContext context, Object error) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(SnackBar(content: Text(errorText(error))));
}

/// What to tell the user about a failed call or a dropped link.
String errorText(Object? error) {
  final code = errorCode(error);
  if (isRejected(error)) return t('The computer did not accept this phone. Show a new QR code on the computer and scan it again.');
  if (code == 'HOST_OFFLINE') return t('The computer is not connected to the Server. Check that DS Bot is open and phone access is on.');
  if (code == 'SERVER_UNREACHABLE') return t("Could not reach the Server. Check the network. If the computer's Server address changed, pair again under Computers.");
  if (code == 'link/offline') return t('Not connected to the computer yet.');
  if (code == 'link/outdated') return t('Update DS Bot on the computer to use this phone.');
  if (error is BotError) return hostText(error.message);
  if (error is LinkError) return hostText(error.message);
  if (error is FormatException) return t(error.message);
  return t('Something went wrong');
}
