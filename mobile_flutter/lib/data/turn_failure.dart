// A failed turn in a Bot's own chat: the `failed` chat item and notice (capability
// `turn-failures`). Port of the desktop's repair card (ds-bot/src/client/turn-error.js):
// the words and the fixes go by DSH's failure code, never by the provider's message,
// which shows only under Technical details.
import '../ui/i18n.dart';
import 'json.dart';
import 'team_state.dart';

const _signedOut = {'ACCOUNT_SIGN_IN_REQUIRED', 'ACCOUNT_SIGNED_OUT', 'ACCOUNT_TOKEN_INVALID'};
const _keyCodes = {'MISSING_CREDENTIAL', 'INVALID_CREDENTIAL', 'AUTH'};

/// Until the credentials change the computer keeps these on the Bot (`blocked`), and a
/// retry would fail the same way.
const credentialCodes = {..._keyCodes, ..._signedOut};

// Short words for codes the card has no sentence of its own for (diagnostics.js).
const _known = {
  'CONTEXT_WINDOW_EXCEEDED': 'The conversation is too long for the model',
  'INVALID_REQUEST': 'The model service refused the request',
};

const officialProvider = 'deepseek-official';
const _accountProvider = 'deepseek-account';
const topUpUrl = 'https://platform.deepseek.com/top_up';

String failureText(String code, {required String name, required String provider, int? status}) => switch (code) {
      'MISSING_CREDENTIAL' => t("{name}'s model has no API key yet.", {'name': name}),
      'INVALID_CREDENTIAL' => t('This API key is not in the right format.'),
      'AUTH' => status == null
          ? t('{provider} did not accept the current API key.', {'provider': provider})
          : t('{provider} did not accept the current API key ({status}).', {'provider': provider, 'status': status}),
      'CONTENT_POLICY' => status == null
          ? t('{provider} blocked this request with its content filter. The API key is not the problem; edit the input or start a new chat.', {'provider': provider})
          : t('{provider} blocked this request with its content filter ({status}). The API key is not the problem; edit the input or start a new chat.', {'provider': provider, 'status': status}),
      'QUOTA' => status == null
          ? t('{provider} is out of balance or quota.', {'provider': provider})
          : t('{provider} is out of balance or quota ({status}).', {'provider': provider, 'status': status}),
      'ACCOUNT_QUOTA' => t('The DeepSeek account balance is too low.'),
      'ACCOUNT_SIGN_IN_REQUIRED' || 'ACCOUNT_SIGNED_OUT' || 'ACCOUNT_TOKEN_INVALID' => t('The DeepSeek account sign-in has expired.'),
      'TRANSPORT' || 'TIMEOUT' => t('Could not reach the model service.'),
      'RATE_LIMIT' => t('Too many requests. Wait a moment, then try again.'),
      'SERVER' => t('The model service failed.'),
      'INTERRUPTED' => t('DeepSeek Harness stopped before this turn finished.'),
      'MODEL_SWITCH_COMPACTION_FAILED' => t('The conversation could not be compacted for this model. Try again or choose another model.'),
      _ => _known[code] != null ? t(_known[code]!) : t('This turn failed.'),
    };

enum FailureFix { key, rekey, model, topUp }

/// What the phone can offer for one failure, the one to try first leading. A Bot moved
/// onto the account route since a key failure has nothing left to fix there. Signing in
/// to the DeepSeek account happens on the computer, so a signed-out Bot gets another model.
List<FailureFix> failureFixes(String code, {required String? provider}) {
  if (provider == _accountProvider && _keyCodes.contains(code)) return const [];
  if (_signedOut.contains(code)) return const [FailureFix.model];
  return switch (code) {
    'MISSING_CREDENTIAL' => const [FailureFix.key, FailureFix.model],
    'INVALID_CREDENTIAL' || 'AUTH' => const [FailureFix.rekey, FailureFix.model],
    'QUOTA' => provider == officialProvider ? const [FailureFix.topUp] : const [],
    'ACCOUNT_QUOTA' => const [FailureFix.topUp],
    'MODEL_SWITCH_COMPACTION_FAILED' => const [FailureFix.model],
    _ => const [],
  };
}

String fixLabel(FailureFix fix) => switch (fix) {
      FailureFix.key => t('Enter API key'),
      FailureFix.rekey => t('Enter the key again'),
      FailureFix.model => t('Pick another model'),
      FailureFix.topUp => t('Top up ↗'),
    };

bool retryShown(String code, Json? blocked) => !credentialCodes.contains(code) || blocked == null;

/// The provider of the model a Bot runs on.
String? botProvider(TeamState team, Bot? bot) {
  final ref = bot?.model ?? bot?.appliedModel;
  if (ref == null || ref.isEmpty) return null;
  return team.models.where((model) => model.ref == ref).firstOrNull?.provider ?? ref.split('/').first;
}

/// A provider without a key may not be listed yet, so DeepSeek's own two routes keep
/// a readable name instead of their id.
String providerName(TeamState? team, String? provider) {
  if (provider == null) return t('The model service');
  final listed = team?.models.where((model) => (model.provider ?? model.ref.split('/').first) == provider && model.providerName != null).firstOrNull;
  if (listed != null) return listed.providerName!;
  return switch (provider) {
    officialProvider => t('DeepSeek'),
    _accountProvider => t('DeepSeek account'),
    _ => provider,
  };
}

/// What Technical details lists: (name for a copied report, label, value).
List<(String, String, String)> failureFacts(Json item, Json? blocked) {
  final code = jStr(item, 'code') ?? '';
  final status = jInt(item, 'status') ?? jInt(blocked, 'status');
  final requestId = jStr(item, 'requestId') ?? jStr(blocked, 'requestId');
  final message = jStr(item, 'message') ?? '';
  return [
    if (code.isNotEmpty) ('Code', t('Code'), code),
    if (status != null) ('HTTP status', t('HTTP status'), '$status'),
    if (requestId != null && requestId.isNotEmpty) ('Request ID', t('Request ID'), requestId),
    // The computer already blanks an AUTH message; it never shows here either way.
    if (code != 'AUTH' && message.isNotEmpty) ('Message', t('Provider message'), message),
  ];
}

/// The words of a `failed` notice: the computer's text is English for older phones.
String failureNoticeText(Json notice, TeamState? team) {
  final bot = team?.bot(jStr(notice, 'botId'));
  return failureText(
    jStr(notice, 'code') ?? '',
    name: bot?.name ?? jStr(notice, 'name') ?? t('This Bot'),
    provider: providerName(team, team == null ? null : botProvider(team, bot)),
    status: jInt(notice, 'status'),
  );
}
