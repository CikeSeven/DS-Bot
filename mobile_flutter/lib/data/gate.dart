// Endpoints that can hand out or change secrets, keys, capabilities or code on
// the computer need a device unlock, every time. A cancelled unlock means the
// call was never sent.
import '../api/link_client.dart';

const gatedEndpoints = {
  'provider-key', 'provider-add', 'provider-remove',
  'secret-set', 'secret-update', 'secret-delete', 'secret-allow',
  'secret-unlock', 'secret-encrypt', 'secret-decrypt', 'secret-store',
  'connector-connect', 'connector-disconnect', 'connector-retry', 'connector-add', 'connector-remove', 'connector-import',
  'mail-account-add', 'mail-account-remove',
  'capability-save', 'capability-delete', 'capability-approve', 'bot-capability',
  'local-agent-add', 'local-agent-remove', 'local-agent-set', 'add-agent', 'remove-agent',
  'im-add', 'im-update', 'im-remove',
  'computer-set-enabled', 'computer-set-level', 'computer-revoke-app',
  'update-install', 'dsh-update-install',
};

abstract class Unlocker {
  /// Throws a [BotError] with code `unlock/unavailable` or `unlock/canceled`.
  Future<void> unlock(String reason);
}

class AlwaysUnlocked implements Unlocker {
  const AlwaysUnlocked();

  @override
  Future<void> unlock(String reason) async {}
}

Future<void> ensureUnlock(Unlocker unlocker, String endpoint) async {
  if (!gatedEndpoints.contains(endpoint)) return;
  await unlocker.unlock(endpoint);
}

bool isUnlockCancel(Object error) => error is BotError && error.code == 'unlock/canceled';
