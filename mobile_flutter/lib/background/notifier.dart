// System notifications for what the computer tells the phone: questions and
// approvals (answerable from the notification), replies and finished work.
// Actions tapped while the app runs are answered on its live link; with the app
// gone, the background handler opens a short link of its own.
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../api/link_client.dart';
import '../app/platform.dart';
import '../data/json.dart';
import '../data/store.dart';
import '../data/team_session.dart';
import '../data/team_state.dart';
import '../link/link.dart';
import '../ui/i18n.dart';

const mainPortName = 'dsbot-main';

final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

const _needs = AndroidNotificationChannel('needs', 'Questions and approvals', importance: Importance.high);
const _replies = AndroidNotificationChannel('replies', 'Replies and finished work', importance: Importance.defaultImportance);
const serviceChannelId = 'link';

class Notifier {
  Notifier._();

  static final Notifier instance = Notifier._();

  bool _ready = false;
  TeamSession? _session;
  StreamSubscription<RpcEvent>? _feed;
  final Set<Object> _shown = {};
  bool foreground = true;

  /// The chat on screen, whose notices need no notification.
  String? openChat;

  /// Opens a chat when a notification is tapped; set by the home screen.
  void Function(String? botId, String? roomId)? onOpen;

  Future<void> init({bool background = false}) async {
    if (_ready) return;
    _ready = true;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
      ),
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(AndroidNotificationChannel(_needs.id, t('Questions and approvals'), importance: Importance.high));
    await android?.createNotificationChannel(AndroidNotificationChannel(_replies.id, t('Replies and finished work')));
    await android?.createNotificationChannel(AndroidNotificationChannel(serviceChannelId, t('Connection'), importance: Importance.low, showBadge: false));
    if (!background) {
      final port = ReceivePort();
      IsolateNameServer.removePortNameMapping(mainPortName);
      IsolateNameServer.registerPortWithName(port.sendPort, mainPortName);
      port.listen((message) {
        if (message is String) _onResponse(_responseFrom(message));
      });
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final response = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && response != null) {
        scheduleMicrotask(() => _onResponse(response));
      }
    }
  }

  Future<bool> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? true;
  }

  /// Follows one session's notices.
  void attach(TeamSession? session) {
    if (identical(session, _session)) return;
    unawaited(_feed?.cancel());
    _session = session;
    _feed = session?.feed.listen((event) {
      if (event.event != 'notice') return;
      final notice = asJson(event.data);
      if (foreground) return;
      final target = jStr(notice, 'roomId') ?? jStr(notice, 'botId');
      if (target != null && target == openChat) return;
      unawaited(show(notice, session.team));
    });
  }

  Future<void> show(Json notice, TeamState? team) async {
    final key = notice['seq'] ?? '${notice['time']}:${notice['text']}';
    if (!_shown.add(key)) return;
    if (_shown.length > 300) _shown.remove(_shown.first);
    final kind = jStr(notice, 'kind') ?? 'message';
    final needs = kind == 'question' || kind == 'approval';
    final actions = <AndroidNotificationAction>[];
    final payload = <String, Object?>{
      'kind': kind,
      'botId': jStr(notice, 'botId'),
      'roomId': jStr(notice, 'roomId'),
      'sessionId': jStr(notice, 'sessionId'),
    };
    if (kind == 'approval' && team != null) {
      final approval = team.approvals.where((entry) => entry['botId'] == notice['botId'] && jBool(entry, 'answerable') != false && (notice['roomId'] == null || entry['roomId'] == notice['roomId'])).lastOrNull;
      if (approval != null) {
        payload['approvalId'] = approval['id'];
        actions
          ..add(AndroidNotificationAction('reject', t('Reject')))
          ..add(AndroidNotificationAction('allow', t('Allow once')));
      }
    }
    if (kind == 'question' && team != null) {
      final sessionId = jStr(notice, 'sessionId') ?? team.bot(jStr(notice, 'botId'))?.chatSession;
      final question = sessionId == null ? null : jMap(team.questions, sessionId);
      if (question != null) {
        payload['sessionId'] = sessionId;
        payload['questionId'] = question['id'];
        final options = jList(question, 'options').map((option) => option is String ? option : jStr(option, 'label') ?? '').toList();
        payload['options'] = options;
        if (jBool(question, 'multiSelect') != true && options.isNotEmpty && options.length <= 3) {
          for (final (i, option) in options.indexed) {
            actions.add(AndroidNotificationAction('opt-$i', option.length > 24 ? '${option.substring(0, 23)}…' : option));
          }
        } else {
          actions.add(AndroidNotificationAction('answer', t('Answer'), inputs: [AndroidNotificationActionInput(label: t('Your answer'))]));
        }
      }
    }
    if (kind == 'message' && jStr(notice, 'sessionId') != null && jStr(notice, 'roomId') == null) {
      actions.add(AndroidNotificationAction('reply', t('Reply'), inputs: [AndroidNotificationActionInput(label: t('Message'))]));
    }
    final title = [jStr(notice, 'name') ?? '', if (jStr(notice, 'title') != null) jStr(notice, 'title')!].where((part) => part.isNotEmpty).join(' · ');
    await _plugin.show(
      id: (key.hashCode & 0x7fffffff),
      title: title.isEmpty ? 'DS Bot' : title,
      body: jStr(notice, 'text') ?? '',
      payload: jsonEncode(payload),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          needs ? _needs.id : _replies.id,
          needs ? t('Questions and approvals') : t('Replies and finished work'),
          importance: needs ? Importance.high : Importance.defaultImportance,
          priority: needs ? Priority.high : Priority.defaultPriority,
          category: needs ? AndroidNotificationCategory.reminder : AndroidNotificationCategory.message,
          styleInformation: BigTextStyleInformation(jStr(notice, 'text') ?? ''),
          groupKey: jStr(notice, 'roomId') ?? jStr(notice, 'botId'),
          actions: actions,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }

  Future<void> _onResponse(NotificationResponse response) async {
    final payload = asJson(_decode(response.payload));
    final session = _session;
    final call = _callFor(payload, response.actionId, response.input);
    if (call == null) {
      onOpen?.call(jStr(payload, 'roomId') == null ? jStr(payload, 'botId') : null, jStr(payload, 'roomId'));
      return;
    }
    if (session == null) return;
    try {
      await session.call(call.$1, call.$2);
    } on Object {
      onOpen?.call(jStr(payload, 'roomId') == null ? jStr(payload, 'botId') : null, jStr(payload, 'roomId'));
    }
  }
}

Object? _decode(String? text) {
  if (text == null || text.isEmpty) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// The endpoint and payload a notification action stands for; null for a plain tap.
(String, Json)? _callFor(Json payload, String? actionId, String? input) {
  if (actionId == null || actionId.isEmpty) return null;
  if (actionId == 'allow' || actionId == 'reject') {
    final id = payload['approvalId'];
    return id == null ? null : ('approval-answer', {'id': id, 'choice': actionId});
  }
  if (actionId.startsWith('opt-')) {
    final index = int.tryParse(actionId.substring(4)) ?? -1;
    final options = jStrings(payload, 'options');
    if (index < 0 || index >= options.length) return null;
    return ('answer-question', {
      'sessionId': payload['sessionId'],
      'questionId': payload['questionId'],
      'answer': {'selected': [options[index]], 'custom': ''},
    });
  }
  if (actionId == 'answer' && (input ?? '').trim().isNotEmpty) {
    return ('answer-question', {
      'sessionId': payload['sessionId'],
      'questionId': payload['questionId'],
      'answer': {'selected': <String>[], 'custom': input!.trim()},
    });
  }
  if (actionId == 'reply' && (input ?? '').trim().isNotEmpty) {
    return ('send', {'sessionId': payload['sessionId'], 'text': input!.trim()});
  }
  return null;
}

String _encodeResponse(NotificationResponse response) => jsonEncode({
      'id': response.id,
      'actionId': response.actionId,
      'input': response.input,
      'payload': response.payload,
      'type': response.notificationResponseType.index,
    });

NotificationResponse _responseFrom(String text) {
  final map = asJson(jsonDecode(text));
  return NotificationResponse(
    id: jInt(map, 'id'),
    actionId: jStr(map, 'actionId'),
    input: jStr(map, 'input'),
    payload: jStr(map, 'payload'),
    notificationResponseType: NotificationResponseType.values[jInt(map, 'type') ?? 0],
  );
}

/// A notification action while the app is in the background or gone. The live
/// app answers it when it is running; otherwise a short link of our own does.
@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse response) async {
  final main = IsolateNameServer.lookupPortByName(mainPortName);
  if (main != null) {
    main.send(_encodeResponse(response));
    return;
  }
  final payload = asJson(_decode(response.payload));
  final call = _callFor(payload, response.actionId, response.input);
  if (call == null) return;
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final store = PhoneStore(SecureKeyValueStore());
  final computer = (await store.listComputers()).active;
  if (computer == null) return;
  final identity = await store.loadIdentity();
  LinkClient? client;
  try {
    client = await RelayLinkClient.open(computer, identity, phoneName: await phoneName());
    await callBot(client, call.$1, call.$2, const Duration(seconds: 20));
  } on Object {
    // The question stays open; the user can answer in the app.
  } finally {
    await client?.close();
  }
}
