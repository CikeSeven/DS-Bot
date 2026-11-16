// A Bot's team actions as chat items, for windows that draw the chat themselves
// (the phone). These are the calls the desktop chat draws as event lines
// (cells.js renderCall): messages to other Bots, Bots and groups made or
// changed, group chats read, memory changes and computer steps. Names are
// resolved to ids here, so a window can open what a line names.
import { classify } from './computer/catalog.js'

const TEAM = new Set(['message_bot', 'stop_bot', 'create_bot', 'update_bot', 'create_group', 'update_group', 'delete_group', 'post_to_group', 'read_group_chat', 'remember', 'forget'])
export const isActCall = name => typeof name === 'string' && (TEAM.has(name) || classify(name) !== undefined)

const GROUP_VERBS = { create_group: 'created', update_group: 'updated', delete_group: 'deleted', post_to_group: 'posted' }
// Group tool results quote the group's name; anything else is a refusal.
const GROUP_DONE = /^(Created group|Updated|Nothing changed in|Deleted|Posted in) "([^"]+)"/

// Keep these in step with cells.js MemoryEvent.
const MEMORY_SAVED = /^(Saved to|Updated in|Removed from) /
const MEMORY_ALREADY = /^Already in /
const MEMORY_TEAM = /^(team|团队|共享)$/i
const MEMORY_OWN = /^(own|me|mine|self|yours?|自己|我)$/i
const MEMORY_GROUP = /^(group|this group|群|本群|群聊)$/i

const named = entry => (entry === undefined ? undefined : { id: entry.id, name: entry.name })
// A Bot the call names, even one that is gone: the line still says who it was.
const namedOrRef = (entry, ref) => named(entry) ?? (typeof ref === 'string' && ref.trim() !== '' ? { name: ref.trim() } : undefined)
const where = ({ botId, roomId }) => (roomId !== undefined ? { roomId } : botId !== undefined ? { botId } : undefined)

// The first image a call answered with: a computer step's screenshot.
const shotOf = content => {
  const block = (Array.isArray(content) ? content : []).find(part => (part?.type === 'image' || part?.type === 'file') && part.attachment?.attachmentId !== undefined)
  if (block === undefined) return undefined
  const mime = block.attachment.mediaType ?? block.attachment.mime ?? block.attachment.mimeType
  return { attachmentId: String(block.attachment.attachmentId), ...(typeof mime === 'string' ? { mime } : {}) }
}

function memoryFields(args, result, scope) {
  const said = String(args.scope ?? '').trim()
  const team = MEMORY_TEAM.test(said)
  const self = scope.findBot(scope.selfId)
  const other = team || said === '' ? undefined : scope.findBot(said)
  const target = other !== undefined && other.id !== self?.id ? other : self
  // The memory a line opens: the Bot's own, the group's in a group chat, or
  // none when the scope names a Bot that is not there.
  const panel = team || MEMORY_OWN.test(said) ? where({ botId: self?.id })
    : MEMORY_GROUP.test(said) ? where({ roomId: scope.roomId })
      : said === '' ? where({ roomId: scope.roomId, botId: self?.id })
        : where({ botId: other?.id })
  const failed = result.isError === true
  if (!failed && MEMORY_ALREADY.test(result.text)) return { outcome: 'already', ...(panel ? { open: panel } : {}) }
  if (!failed && MEMORY_SAVED.test(result.text)) {
    if (target === undefined) return undefined
    const whose = team ? 'team' : target === self ? 'self' : 'bot'
    return { outcome: 'saved', whose, ...(whose === 'bot' ? { bot: named(target) } : {}), open: { botId: target.id } }
  }
  return {
    outcome: failed ? 'failed' : 'unchanged',
    ...(typeof result.code === 'string' ? { code: result.code } : {}),
    ...(panel ? { open: panel } : {}),
  }
}

// The fields of a call's item, or undefined when it shows nothing (yet). `result`
// is undefined while the call runs, else { text, isError, code?, content }.
// `scope` resolves names: { selfId, roomId?, findBot(ref), findRoom(ref), appOf?(callId) }.
export function actFields({ name, args = {}, callId }, result, scope) {
  const done = result !== undefined
  const state = !done ? 'running' : result.isError === true ? 'failed' : 'done'
  switch (name) {
    case 'message_bot':
    case 'stop_bot': {
      const ref = name === 'message_bot' ? args.to : args.bot
      const bot = namedOrRef(scope.findBot(ref), ref)
      if (bot === undefined) return undefined
      return { act: name === 'message_bot' ? 'message' : 'stop', state, bot, ...(scope.selfId ? { from: scope.selfId } : {}) }
    }
    case 'create_bot': {
      const bot = state === 'done' ? scope.findBot(args.name) : undefined
      return bot === undefined ? undefined : { act: 'create-bot', state, bot: named(bot) }
    }
    case 'update_bot': {
      if (state !== 'done') return undefined
      const bot = scope.findBot(args.name) ?? scope.findBot(args.bot) ?? (args.bot ? undefined : scope.findBot(scope.selfId))
      return bot === undefined ? undefined : { act: 'update-bot', state, bot: named(bot), ...(bot.id === scope.selfId ? { self: true } : {}) }
    }
    case 'create_group':
    case 'update_group':
    case 'delete_group':
    case 'post_to_group': {
      if (!done) return undefined
      const verb = GROUP_VERBS[name]
      const quoted = GROUP_DONE.exec(result.text)
      if (state === 'failed' || quoted === null) return { act: 'group', verb, state: 'failed' }
      const room = verb === 'deleted' ? undefined : scope.findRoom(quoted[2])
      return { act: 'group', verb, state, room: named(room) ?? { name: quoted[2] } }
    }
    case 'read_group_chat': {
      const room = state === 'done' ? scope.findRoom(args.group) : undefined
      return room === undefined ? undefined : { act: 'read-group', state, room: named(room) }
    }
    case 'remember':
    case 'forget': {
      if (!done) return undefined
      const fields = memoryFields(args, result, scope)
      return fields === undefined ? undefined : { act: 'memory', tool: name, state, ...fields }
    }
    default: {
      const call = classify(name, args)
      if (call === undefined) return undefined
      const selector = args.params?.selector
      // getApp names its target in the selector; a step record names the app later calls act on.
      const app = scope.appOf?.(callId) ?? (call.method === 'getApp' && typeof selector === 'string' && selector !== '' ? selector : undefined)
      const shot = done ? shotOf(result.content) : undefined
      return { act: 'computer', state, method: call.method, ...(app ? { app } : {}), ...(shot ? { shot } : {}) }
    }
  }
}
