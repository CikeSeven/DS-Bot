// Typed views over the team state the computer sends (`state` endpoint). The raw
// map stays the source of truth, so fields this phone does not know survive
// merges and writes.
import 'json.dart';

class Bot {
  Bot(this.raw);

  final Json raw;

  String get id => jStr(raw, 'id') ?? '';
  String get name => jStr(raw, 'name') ?? '';
  String? get role => jStr(raw, 'role');
  String? get permission => jStr(raw, 'permission');
  Json? get blocked => jMap(raw, 'blocked');
  String? get color => jStr(raw, 'color');
  Json get avatar => jMap(raw, 'avatar') ?? const {};
  String? get shape => jStr(avatar, 'shape');
  String? get image => jStr(avatar, 'image');
  String? get imageRef => jStr(avatar, 'imageRef');
  String? get model => jStr(raw, 'model');
  String? get appliedModel => jStr(raw, 'appliedModel');
  List<String> get capabilities => jStrings(raw, 'capabilities');
  String? get effort => jStr(raw, 'effort');
  String? get workDir => jStr(raw, 'workDir');
  bool get isPrivate => jBool(raw, 'private') ?? false;
  String? get instructions => jStr(raw, 'instructions');
  String? get sessionId => jStr(raw, 'sessionId');
  List<String> get parts => jStrings(raw, 'parts');
  bool get waiting => jBool(raw, 'waiting') ?? false;
  bool get pinned => jBool(raw, 'pinned') ?? false;
  bool get hidden => jBool(raw, 'hidden') ?? false;
  int? get createdAt => jInt(raw, 'createdAt');
  int? get lastAt => jInt(raw, 'lastAt');
  String? get preview => jStr(raw, 'preview');
  String? get engine => jStr(raw, 'engine');
  String? get sectionId => jStr(raw, 'sectionId');
  Json? get browserGrants => jMap(raw, 'browserGrants');

  /// The session this Bot's own chat runs in; older hosts used the Bot id.
  String get chatSession => sessionId ?? id;
}

class Room {
  Room(this.raw);

  final Json raw;

  String get id => jStr(raw, 'id') ?? '';
  String get name => jStr(raw, 'name') ?? '';
  String? get preview => jStr(raw, 'preview');
  int? get lastAt => jInt(raw, 'lastAt');
  List<String> get members => jStrings(raw, 'members');
  String? get admin => jStr(raw, 'admin');
  String? get mode => jStr(raw, 'mode');
  String? get notice => jStr(raw, 'notice');
  bool get named => jBool(raw, 'named') ?? false;
  String? get sessionId => jStr(raw, 'sessionId');
  bool get pinned => jBool(raw, 'pinned') ?? false;
  bool get hidden => jBool(raw, 'hidden') ?? false;
  int? get createdAt => jInt(raw, 'createdAt');
  Json? get goal => jMap(raw, 'goal');
  String? get workDir => jStr(raw, 'workDir');
  String? get permission => jStr(raw, 'permission');
  String? get sectionId => jStr(raw, 'sectionId');
  List<String> get ownParts => jStrings(raw, 'ownParts');
}

class ModelEntry {
  ModelEntry(this.raw);

  final Json raw;

  String get ref => jStr(raw, 'ref') ?? '';
  String get name => jStr(raw, 'name') ?? ref;
  String? get provider => jStr(raw, 'provider');
  String? get providerName => jStr(raw, 'providerName');
  bool get needsKey => jBool(raw, 'needsKey') ?? false;
  Json? get reasoning => jMap(raw, 'reasoning');
}

class TeamState {
  TeamState(this.raw, {this.messagePreviews = const {}});

  final Json raw;
  final Map<String, Json> messagePreviews;

  int get revision => jInt(raw, 'revision') ?? -1;
  bool get unchanged => jBool(raw, 'unchanged') ?? false;
  String? get liveKey => jStr(raw, 'liveKey');

  late final List<Bot> bots = jMaps(raw, 'bots').map((bot) {
    final id = jStr(bot, 'id');
    final tails = jMap(raw, 'chatTails');
    final tail = jMap(tails, id ?? '');
    final saved = tails == null ? bot : (tail ?? const <String, dynamic>{});
    final pushed = messagePreviews[id];
    final latest = pushed != null && (jInt(pushed, 'lastAt') ?? 0) >= (jInt(saved, 'lastAt') ?? 0) ? pushed : saved;
    return Bot({...bot, 'lastAt': jInt(latest, 'lastAt'), 'preview': jStr(latest, 'preview')});
  }).toList();
  late final List<Room> rooms = jMaps(raw, 'rooms').map(Room.new).toList();
  late final Map<String, Bot> _botById = {for (final bot in bots) bot.id: bot};
  late final Map<String, Room> _roomById = {for (final room in rooms) room.id: room};
  late final Map<String, Bot> _botBySession = {for (final bot in bots) bot.chatSession: bot};

  Bot? bot(String? id) => id == null ? null : _botById[id];
  Room? room(String? id) => id == null ? null : _roomById[id];
  Bot? botOfSession(String? sessionId) => sessionId == null ? null : _botBySession[sessionId];

  String? get mainBotId => jStr(raw, 'mainBotId');
  List<String> get mainBotIds {
    final ids = jStrings(raw, 'mainBotIds');
    if (ids.isNotEmpty) return ids;
    final main = mainBotId;
    return main == null ? const [] : [main];
  }

  bool isMain(String botId) => mainBotIds.contains(botId);

  late final List<ModelEntry> models = jMaps(raw, 'models').map(ModelEntry.new).toList();
  String? get defaultModel => jStr(raw, 'defaultModel');
  bool get memoryEnabled => jBool(raw, 'memory') ?? true;
  String? get readOnly => jStr(raw, 'readOnly');

  Json get questions => jMap(raw, 'questions') ?? const {};
  Json get views => jMap(raw, 'views') ?? const {};
  Json get closedCards => jMap(raw, 'closedCards') ?? const {};
  Json get secretRequests => jMap(raw, 'secretRequests') ?? const {};
  Json get connectorRequests => jMap(raw, 'connectorRequests') ?? const {};
  Json get mailRequests => jMap(raw, 'mailRequests') ?? const {};
  Json get browserHolds => jMap(raw, 'browserHolds') ?? const {};
  Json get btwCards => jMap(raw, 'btwCards') ?? const {};
  Json get sideChats => jMap(raw, 'sideChats') ?? const {};
  Json get work => jMap(raw, 'work') ?? const {};
  Json get activity => jMap(raw, 'activity') ?? const {};
  Json get prefs => jMap(raw, 'prefs') ?? const {};
  Json get capabilityStatuses => jMap(raw, 'capabilityStatuses') ?? const {};
  Json get computer => jMap(raw, 'computer') ?? const {};
  Json get computerLive => jMap(raw, 'computerLive') ?? const {};
  Json get learning => jMap(raw, 'learning') ?? const {};
  Json get memoryNews => jMap(raw, 'memoryNews') ?? const {};
  Json get im => jMap(raw, 'im') ?? const {};
  Json get imVia => jMap(raw, 'imVia') ?? const {};
  Json? get phone => jMap(raw, 'phone');
  Json? get secretStore => jMap(raw, 'secretStore');
  Object? get connectors => raw['connectors'];
  List<Json> get capabilities => jMaps(raw, 'capabilities');
  List<Json> get sections => jMaps(raw, 'sections');
  List<Json> get agents => jMaps(raw, 'agents');
  List<Json> get secrets => jMaps(raw, 'secrets');
  List<Json> get privateArchives => jMaps(raw, 'privateArchives');
  List<Json> get permissions => jMaps(raw, 'permissions');
  List<String> get colors => jStrings(raw, 'colors');
  bool get browserEnabled => jBool(raw, 'browser') ?? false;
  String? get workspace => jStr(raw, 'workspace');
  String? get dataPath => jStr(raw, 'dataPath');
  String? get version => jStr(raw, 'version');

  List<Json> get approvals => jMaps(work, 'approvals');
  Json get workBots => jMap(work, 'bots') ?? const {};
  Json get workRooms => jMap(work, 'rooms') ?? const {};
  Json get waiting => jMap(work, 'waiting') ?? const {};
  Json get turns => jMap(work, 'turns') ?? const {};

  /// The Bot is running a turn (in its own chat or in a group).
  bool botWorking(String botId) => workBots[botId] != null;

  /// Members running a turn in this group.
  List<Json> roomWork(String roomId) => jMaps(workRooms, roomId);

  /// The answer a write or a poll sent, merged the way the phone keeps it.
  TeamState mergedWith(TeamState next) =>
      next.unchanged ? TeamState({...raw, ...next.raw}) : next;
}
