// Port of the Expo app's src/team/demo.ts. Demo mode (--dart-define=DSB_DEMO=1): no
// computer and no link. The fixture answers with the shapes the real host
// returns (channel.js `state` view + live(), parts.js `chat` pages).
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../api/link_client.dart';
import 'json.dart';

const demoMode = bool.fromEnvironment('DSB_DEMO');

class DemoLinkClient implements LinkClient {
  DemoLinkClient(Json data)
      : _state = _deepCopy(data['state']) as Json,
        _chats = _deepCopy(data['chats']) as Json,
        _images = (data['images'] as Map? ?? const {}).cast<String, dynamic>();

  final Json _state;
  final Json _chats;
  final Map<String, dynamic> _images;
  final Set<void Function(RpcEvent)> _events = {};
  final _random = Random();

  static Object? _deepCopy(Object? value) => jsonDecode(jsonEncode(value));

  @override
  String? get hostName => 'Demo computer';

  @override
  Unsubscribe onEvent(void Function(RpcEvent event) handler) {
    _events.add(handler);
    return () => _events.remove(handler);
  }

  @override
  LinkStatus get status => const LinkStatus(LinkPhase.online);

  @override
  Stream<LinkStatus> get statuses => const Stream.empty();

  @override
  void networkChanged() {}

  @override
  void setForeground(bool foreground) {}

  @override
  Future<void> close() async {}

  void _touch() {
    _state['revision'] = (jInt(_state, 'revision') ?? 0) + 1;
    scheduleMicrotask(() {
      for (final handler in [..._events]) {
        handler(RpcEvent('revision', {'revision': _state['revision']}));
      }
    });
  }

  String _id(String prefix) => '$prefix-${_random.nextInt(1 << 30).toRadixString(36)}';

  List<Json> get _bots => (_state['bots'] as List).cast<Json>();

  String _sessionOf(String id) => jStr(_bots.where((bot) => bot['id'] == id).firstOrNull, 'sessionId') ?? id;

  List<Object?>? _pagesOf(String id) {
    final direct = _chats[id];
    if (direct is List) return direct;
    final owner = _bots.where((bot) => bot['sessionId'] == id).firstOrNull;
    final pages = owner == null ? null : _chats[owner['id']];
    return pages is List ? pages : null;
  }

  void _append(List<Object?> pages, Json item) {
    final first = (pages.first as Map).cast<String, dynamic>();
    final items = (first['items'] as List?) ?? [];
    final last = items.isEmpty ? null : items.last;
    item['seq'] = (jInt(last, 'seq') ?? 0) + 1;
    items.add(item);
    first['items'] = items;
  }

  @override
  Future<Object?> rpc(String method, Object? params, {Duration? timeout}) async {
    final map = asJson(params);
    final endpoint = jStr(map, 'endpoint') ?? '';
    final body = jMap(map, 'payload') ?? {};
    try {
      final value = _answer(endpoint, body);
      return {'ok': true, 'value': value};
    } on BotError catch (error) {
      return {
        'ok': false,
        'error': {'code': error.code, 'message': error.message},
      };
    }
  }

  Object? _answer(String endpoint, Json body) {
    final now = DateTime.now().millisecondsSinceEpoch;
    switch (endpoint) {
      case 'hello':
        return {
          'api': 1,
          'apiMin': 1,
          'apiMax': 1,
          'capabilities': [
            'state', 'state-avatar-refs', 'avatar', 'chat', 'room-chat', 'send', 'feed', 'feed-room', 'notices',
            'questions', 'views', 'approvals', 'stop-member-work', 'memory', 'memory-edit', 'usage-summary',
            'stop-chat', 'row-meta', 'chat-steps', 'link-feed', 'images', 'send-images', 'write-state',
          ],
          'boot': 'demo',
          'seq': 0,
        };
      case 'notices':
        return {'boot': 'demo', 'seq': 0, 'notices': <Object?>[], 'reset': false};
      case 'state':
        if (body['since'] == _state['revision']) {
          return {'revision': _state['revision'], 'unchanged': true, 'work': _state['work'], 'activity': _state['activity']};
        }
        return _deepCopy(_state);
      case 'avatar':
        return {'botId': body['botId'], 'ref': null, 'image': null};
      case 'image':
        final data = _images['${body['attachmentId']}'];
        if (data == null) throw BotError('bot/not-found', 'Unknown attachment');
        return {'mime': 'image/png', 'data': data};
      case 'chat':
        final pages = _pagesOf('${body['botId']}');
        if (pages == null || pages.isEmpty) throw BotError('bot/not-found', 'Unknown Bot');
        final part = jInt(body['cursor'], 'part') ?? 0;
        final first = asJson(pages.first);
        final page = part < pages.length ? asJson(pages[part]) : {'items': <Object?>[], 'cursor': null};
        return {'sessionId': first['sessionId'], 'items': page['items'], 'cursor': page['cursor']};
      case 'room-chat':
        final roomId = '${body['roomId'] ?? ''}';
        final pages = _chats[roomId];
        final page = pages is List && pages.isNotEmpty ? asJson(pages.first) : {'items': <Object?>[], 'cursor': null};
        return {'roomId': roomId, 'items': page['items'], 'cursor': page['cursor'], 'running': false, 'speaking': null};
      case 'send':
        final id = '${body['sessionId'] ?? ''}';
        final pages = _pagesOf(id);
        if (pages == null || pages.isEmpty) throw BotError('bot/not-found', 'Unknown Bot');
        _append(pages, {'kind': 'user', 'text': '${body['text'] ?? ''}', 'time': now});
        _touch();
        return true;
      case 'stage-image':
        return {'id': _id('img')};
      case 'answer-question':
        final sid = _sessionOf('${body['sessionId'] ?? ''}');
        final questions = _state['questions'] as Map?;
        final question = questions?[sid];
        if (question == null || question['id'] != body['questionId']) throw BotError('bot/stale', 'This question is no longer open');
        questions!.remove(sid);
        final pages = _pagesOf(sid);
        final answer = jMap(body, 'answer') ?? {};
        if (pages != null && pages.isNotEmpty) {
          _append(pages, {
            'kind': 'answer',
            'questions': [
              {'question': question['question']},
            ],
            'answers': [
              {'selected': answer['selected'] ?? <Object?>[], 'custom': answer['custom'] ?? ''},
            ],
            'time': now,
          });
        }
        _touch();
        return true;
      case 'approval-answer':
        final list = (jMap(_state, 'work')?['approvals'] as List?) ?? [];
        final index = list.indexWhere((entry) => (entry as Map)['id'] == body['id']);
        if (index == -1) throw BotError('bot/stale', 'This approval is no longer open');
        list.removeAt(index);
        _touch();
        return true;
      case 'stop-chat':
        (jMap(_state, 'work')?['bots'] as Map?)?.remove(_sessionOf('${body['botId']}'));
        (jMap(_state, 'work')?['bots'] as Map?)?.remove('${body['botId']}');
        _touch();
        return true;
      case 'stop-room-work':
        (jMap(_state, 'work')?['rooms'] as Map?)?.remove('${body['roomId']}');
        _touch();
        return true;
      case 'stop-member-work':
        final rooms = jMap(_state, 'work')?['rooms'] as Map?;
        final list = rooms?['${body['roomId']}'];
        if (list is List) list.removeWhere((entry) => (entry as Map)['botId'] == body['botId']);
        _touch();
        return true;
      case 'update-bot':
        final bot = _bots.where((entry) => entry['id'] == body['id']).firstOrNull;
        if (bot == null) throw BotError('bot/not-found', 'Unknown Bot');
        for (final entry in body.entries) {
          if (entry.key == 'id') continue;
          if (entry.value == null || entry.value == '') {
            bot.remove(entry.key);
          } else {
            bot[entry.key] = entry.value;
          }
        }
        _touch();
        return {'ok': true};
      case 'set-flags':
        final target = _bots.where((entry) => entry['id'] == body['id']).firstOrNull ??
            (_state['rooms'] as List).cast<Json>().where((entry) => entry['id'] == body['id']).firstOrNull;
        if (target != null) {
          if (body['pinned'] is bool) target['pinned'] = body['pinned'];
          if (body['hidden'] is bool) target['hidden'] = body['hidden'];
        }
        _touch();
        return {'ok': true};
      case 'create-bot':
        final id = _id('b');
        _bots.add({
          'id': id,
          'name': body['name'] ?? 'New Bot',
          'color': ?body['color'],
          'avatar': ?body['avatar'],
          'model': ?body['model'],
          'sessionId': 's-$id',
          'createdAt': now,
        });
        _chats[id] = [
          {'sessionId': 's-$id', 'items': <Object?>[], 'cursor': null},
        ];
        _touch();
        return {'id': id};
      case 'duplicate-bot':
        final bot = _bots.where((entry) => entry['id'] == body['id']).firstOrNull;
        if (bot == null) throw BotError('bot/not-found', 'Unknown Bot');
        final id = _id('b');
        _bots.add({...bot, 'id': id, 'name': '${bot['name']} (copy)', 'sessionId': 's-$id', 'createdAt': now});
        _chats[id] = [
          {'sessionId': 's-$id', 'items': <Object?>[], 'cursor': null},
        ];
        _touch();
        return {'id': id};
      case 'delete-bot':
        _bots.removeWhere((entry) => entry['id'] == body['id']);
        _touch();
        return {'ok': true};
      case 'set-main':
        final mains = jStrings(_state, 'mainBotIds').toList();
        final id = '${body['id']}';
        if (body['main'] == true) {
          if (!mains.contains(id)) mains.add(id);
        } else {
          mains.remove(id);
        }
        _state['mainBotIds'] = mains;
        _state['mainBotId'] = mains.firstOrNull;
        _touch();
        return {'ok': true};
      case 'update-room':
        final room = (_state['rooms'] as List).cast<Json>().where((entry) => entry['id'] == body['id']).firstOrNull;
        if (room == null) throw BotError('bot/not-found', 'Unknown group');
        room.addAll({...body}..remove('id'));
        _touch();
        return {'ok': true};
      case 'create-room':
        final id = _id('r');
        final members = jStrings(body, 'members');
        final name = members.map((member) => jStr(_bots.where((bot) => bot['id'] == member).firstOrNull, 'name')).whereType<String>().join(', ');
        (_state['rooms'] as List).add({'id': id, 'name': name.isEmpty ? 'New group' : name, 'members': members, 'admin': body['admin'], 'createdAt': now});
        _chats[id] = [
          {'items': <Object?>[], 'cursor': null},
        ];
        _touch();
        return {'id': id};
      case 'delete-room':
        (_state['rooms'] as List).removeWhere((entry) => (entry as Map)['id'] == body['id']);
        _touch();
        return {'ok': true};
      case 'models':
        return _state['models'] ?? <Object?>[];
      case 'efforts':
        return {
          'efforts': [
            {'id': 'low', 'name': 'Quick'},
            {'id': 'medium', 'name': 'Balanced'},
            {'id': 'high', 'name': 'Careful'},
          ],
          'defaultEffort': 'medium',
        };
      case 'memory-view' || 'memory-add' || 'memory-edit' || 'memory-forget' || 'memory-pin' || 'memory-restore':
        return _memoryView(now);
      case 'memory-ask':
        return {'reply': 'The tag is held until the screenshots land. See Release notes.', 'changes': <Object?>[], 'view': _memoryView(now)};
      case 'memory-history':
        return {
          'entries': [
            {'id': 'h1', 'at': now - 3600000, 'action': 'add', 'text': 'Tag lands Friday once screenshots are in', 'by': 'Coder'},
            {'id': 'h2', 'at': now - 86400000, 'action': 'forget', 'text': 'Old launch date', 'by': 'Chief'},
          ],
        };
      case 'schedules':
        return {
          'available': true,
          'tasks': [
            {'id': 'sch-1', 'botId': 'b-chief', 'sessionId': 's-chief', 'title': 'Morning standup', 'prompt': 'Post the team status', 'kind': 'daily', 'time': '09:00', 'scheduledAt': now + 3600000, 'status': 'active'},
            {'id': 'sch-2', 'botId': 'b-chief', 'sessionId': 's-chief', 'title': 'Weekly review', 'prompt': 'Summarize the week', 'kind': 'weekly', 'weekdays': [5], 'time': '17:00', 'scheduledAt': now + 86400000, 'status': 'active'},
          ],
        };
      case 'folders':
        return {
          'team': '/work',
          'picker': 'browse',
          'folders': [
            {'path': '/work/ds-bot', 'title': 'ds-bot'},
            {'path': '/work/docs', 'title': 'docs'},
          ],
        };
      case 'folder-list':
        final path = '${body['path'] ?? ''}';
        const tree = {
          '': ['work'],
          '/work': ['ds-bot', 'docs', 'notes'],
          '/work/ds-bot': ['mobile', 'ds-bot', 'app'],
        };
        final parent = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
        return {
          'path': path,
          'parent': path.isEmpty ? null : parent,
          'entries': [
            for (final name in tree[path] ?? const <String>[]) {'name': name, 'path': '$path/$name'},
          ],
          'truncated': false,
        };
      case 'usage-summary':
        return {
          'botId': body['botId'],
          'day': {'input': 12400, 'output': 3200, 'cacheRead': 8800},
          'week': {'input': 98200, 'output': 21400, 'cacheRead': 61100},
          'month': {'input': 402100, 'output': 90300, 'cacheRead': 251000},
          'models': [
            {'key': 'deepseek-official/deepseek-v4.1', 'name': 'DeepSeek v4.1', 'input': 300100, 'output': 70100},
            {'key': 'deepseek-official/deepseek-flash', 'name': 'DeepSeek Flash', 'input': 102000, 'output': 20200},
          ],
          'scanning': false,
        };
      case 'run-stats':
        return {
          'sessionStats': {'turns': 96, 'steps': 311},
          'tokenUsage': {'uncachedInputTokens': 52000, 'outputTokens': 9000, 'cacheReadTokens': 480000, 'cacheWriteTokens': 0},
          'contextPressure': {'pressureTokens': 61000, 'contextWindow': 1000000},
        };
      case 'usage':
        return {
          'total': {'input': 402100, 'output': 90300},
          'bots': [
            {'name': 'Chief', 'input': 152100, 'output': 40100},
            {'name': 'Writer', 'input': 120100, 'output': 30400},
            {'name': 'Coder', 'input': 80000, 'output': 13000},
          ],
          'models': [
            {'name': 'DeepSeek v4.1', 'input': 300100, 'output': 70100},
            {'name': 'DeepSeek Flash', 'input': 102000, 'output': 20200},
          ],
        };
      case 'providers':
        return {
          'available': true,
          'protocols': ['openai'],
          'providers': [
            {'id': 'deepseek', 'name': 'DeepSeek', 'key': {'configured': true, 'writable': true}, 'models': [{'name': 'DeepSeek v4.1'}, {'name': 'DeepSeek Flash'}]},
            {'id': 'openai', 'name': 'OpenAI', 'key': {'configured': false, 'writable': true}, 'removable': true, 'models': [{'name': 'GPT-5.2'}]},
          ],
          'addable': [
            {'id': 'anthropic', 'name': 'Anthropic'},
            {'id': 'openai-compat', 'name': 'OpenAI-compatible'},
          ],
        };
      case 'provider-models':
        return [
          {'name': 'DeepSeek v4.1'},
          {'name': 'DeepSeek Flash'},
          {'name': 'DeepSeek Reasoner'},
        ];
      case 'file-text':
        return {'text': '# Release notes\n\n- Drawer lands today\n- Mobile cards render natively\n- Needs-you groups the queue\n', 'truncated': false};
      case 'update-check':
        return {
          'update': {'phase': 'current', 'latest': '0.1.2', 'available': false, 'checkedAt': now - 3600000},
          'dsh': {'phase': 'installed', 'installed': '0.0.1', 'available': false},
        };
      case 'diagnostics':
        return {'size': 48200, 'entries': 214, 'last': 'Turn 96 on Coder failed once and retried.'};
      case 'diagnostics-log':
        return {'lines': ['12:00 Chief ran 3 tools', '12:01 Coder failed once and retried', '12:02 Writer posted a draft']};
      case 'avatar-library':
        return {'entries': <Object?>[], 'done': true};
      case 'browser-frame':
        return {
          'mime': 'image/png',
          'data': 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
          'url': 'https://github.com/CikeSeven/DS-Bot',
          'title': 'DS Bot on GitHub',
        };
      case 'side-new':
        final chatId = _id('sc');
        final botId = '${body['sessionId'] ?? ''}'.split(':').first;
        final side = (_state['sideChats'] ??= <String, dynamic>{}) as Map;
        ((side[botId] ??= <Object?>[]) as List).add({'chatId': chatId, 'entries': <Object?>[]});
        _touch();
        return {'chatId': chatId};
      case 'side-ask':
        final entry = {'id': _id('se'), 'question': '${body['text'] ?? ''}', 'answer': 'So far: the migration script is the only blocker; the rest is on track.', 'status': 'done'};
        for (final chats in ((_state['sideChats'] as Map?) ?? const {}).values) {
          for (final chat in (chats as List).cast<Map>()) {
            if (chat['chatId'] == body['chatId']) ((chat['entries'] ??= <Object?>[]) as List).add(entry);
          }
        }
        _touch();
        return entry;
      case 'side-close':
        for (final chats in ((_state['sideChats'] as Map?) ?? const {}).values) {
          (chats as List).removeWhere((chat) => (chat as Map)['chatId'] == body['chatId']);
        }
        _touch();
        return {'ok': true};
      case 'btw-delete':
        for (final cards in ((_state['btwCards'] as Map?) ?? const {}).values) {
          (cards as List).removeWhere((card) => (card as Map)['id'] == body['cardId']);
        }
        _touch();
        return {'ok': true};
      case 'dismiss-view':
        (_state['views'] as Map?)?.remove('${body['sessionId']}');
        _touch();
        return {'ok': true};
      case 'view-reply':
        final views = _state['views'] as Map?;
        if (views?['${body['sessionId']}'] == null) throw BotError('bot/invalid', 'This view is no longer open');
        views!.remove('${body['sessionId']}');
        _touch();
        return {'ok': true};
      case 'browser-takeover':
        ((_state['browserHolds'] ??= <String, dynamic>{}) as Map)['${body['botId']}'] = {'by': 'user', 'reason': 'takeover', 'note': 'The user is controlling this browser.'};
        _touch();
        return {'ok': true};
      case 'browser-give-back':
        (_state['browserHolds'] as Map?)?.remove('${body['botId']}');
        _touch();
        return {'ok': true};
      default:
        // Every other write succeeds without changing the demo team.
        return {'ok': true};
    }
  }

  Json _memoryView(int now) => {
        'summary': {'text': 'Chief keeps the launch plan moving.', 'at': now - 600000},
        'sizes': {'own': 420, 'team': 180},
        'limits': {'main': 4000},
        'entries': [
          {'scope': 'own', 'topic': 'Release', 'text': 'Tag lands Friday once screenshots are in', 'added': '2 days ago', 'by': 'Coder', 'source': 'chat'},
          {'scope': 'own', 'topic': null, 'text': 'Prefers concise status lines', 'added': 'last week', 'by': null, 'source': 'memory panel'},
          {'scope': 'team', 'topic': 'Team', 'text': 'Writer drafts docs first, Coder tests before merge', 'added': 'this month', 'by': 'Chief', 'source': 'chat'},
        ],
      };
}
