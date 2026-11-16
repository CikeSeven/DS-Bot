// Port of the Expo app's src/team/optimistic.ts: a write's effect on the team state,
// guessed before the reply lands so a remote edit feels instant. The reply's
// state, or a full reload after a failure, always wins afterwards.
import 'json.dart';
import 'team_state.dart';

const optimisticEndpoints = {'update-bot', 'set-main', 'bot-capability', 'update-room', 'set-flags'};

class Write {
  Write(this.endpoint, this.payload);

  final String endpoint;
  final Json payload;
}

TeamState? optimistic(TeamState? team, String endpoint, Json payload) {
  if (team == null) return null;
  switch (endpoint) {
    case 'update-bot':
      return _patchBot(team, payload['id'], (bot) {
        final next = {...bot, ...payload}..remove('id');
        next['id'] = bot['id'];
        // The computer reads null or '' as "clear"; the state omits the key.
        if (payload.containsKey('effort') && payload['effort'] == null) next.remove('effort');
        if (payload['workDir'] == '') next.remove('workDir');
        return next;
      });
    case 'set-main':
      final id = '${payload['id'] ?? ''}';
      if (team.bot(id) == null) return team;
      final mains = [...team.mainBotIds];
      if (payload['main'] == false) {
        mains.remove(id);
      } else if (!mains.contains(id)) {
        mains.add(id);
      }
      return TeamState({...team.raw, 'mainBotIds': mains, 'mainBotId': mains.isEmpty ? null : mains.first});
    case 'bot-capability':
      return _patchBot(team, payload['botId'], (bot) {
        final attached = [...jStrings(bot, 'capabilities')];
        final name = '${payload['name']}';
        if (payload['attached'] == true) {
          if (!attached.contains(name)) attached.add(name);
        } else {
          attached.remove(name);
        }
        return {...bot, 'capabilities': attached};
      });
    case 'update-room':
      return _patchRoom(team, payload['id'], (room) => ({...room, ...payload})..['id'] = room['id']);
    case 'set-flags':
      // `{id, pinned?, hidden?, sectionId?}` for a Bot, a group or the DSH Agent; only given flags change.
      final flags = <String, Object?>{
        if (payload['pinned'] is bool) 'pinned': payload['pinned'],
        if (payload['hidden'] is bool) 'hidden': payload['hidden'],
      };
      final section = payload['sectionId'];
      Json apply(Json entry) {
        final next = {...entry, ...flags};
        if (payload.containsKey('sectionId')) {
          if (section == null || section == '') {
            next.remove('sectionId');
          } else {
            next['sectionId'] = section;
          }
        }
        return next;
      }

      if (team.bot('${payload['id']}') != null) return _patchBot(team, payload['id'], apply);
      return _patchRoom(team, payload['id'], apply);
    default:
      return team;
  }
}

TeamState _patchBot(TeamState team, Object? id, Json Function(Json bot) change) {
  final bots = jMaps(team.raw, 'bots');
  final index = bots.indexWhere((bot) => bot['id'] == id);
  if (index == -1) return team;
  bots[index] = change(bots[index]);
  return TeamState({...team.raw, 'bots': bots});
}

TeamState _patchRoom(TeamState team, Object? id, Json Function(Json room) change) {
  final rooms = jMaps(team.raw, 'rooms');
  final index = rooms.indexWhere((room) => room['id'] == id);
  if (index == -1) return team;
  rooms[index] = change(rooms[index]);
  return TeamState({...team.raw, 'rooms': rooms});
}

/// A state read that left before a write landed would undo the write's guess,
/// so every write still in flight is laid over each state the phone takes in.
TeamState withWrites(TeamState team, List<Write> writes) =>
    writes.fold(team, (next, write) => optimistic(next, write.endpoint, write.payload) ?? next);
