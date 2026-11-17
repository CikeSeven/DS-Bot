// Recalling a message in a Bot's own chat (docs/plans/2026-11-16-message-recall.md):
// the message and everything after it leave the Bot's context and the chat, and its
// text goes back to the message box it came from. The Session log stays whole: one
// surface replacement, DSH's own mechanism for taking history out of the model's
// view, stands in for the recalled range. Files the Bot changed stay as they are.
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { REPLY_KIND, SOURCE_KIND } from './constants.js'
import { phoneBlocks } from './pictures.js'
import { textOf } from './text.js'

// The placeholder's source: a kind of its own, so no reader of `bot` messages takes it
// for a Bot's mail.
export const RECALL_KIND = 'ds-bot-recall'
// What the Bot reads in place of the recalled range. A message the user sends next joins
// it in the same request, so it must not read as advice about that message.
export const RECALL_NOTE = '[The user took back the messages that came after this point, and your replies to them. Treat them as never sent.]'
// Calls that write files. A turn that has not ended has no change summary yet, so its
// calls are the only sign of what it did.
const WRITE_TOOLS = /^(write|edit|multi_edit|apply_patch|str_replace\w*)$/
// Messages that start a turn: the user's, a Bot's mail, a scheduled task, a card answer.
const OPENERS = new Set(['user', SOURCE_KIND, 'schedule', REPLY_KIND])
const FILES_LISTED = 8
const IDLE_ATTEMPTS = 5

const refused = (message, code) => Object.assign(new Error(message), { code })

// A recall as the state keeps it: the recalled message (`seq`, in turn `turn`), the
// placeholder that ends the range (`until`), whether the message opened its turn, and
// the last turn the range reached.
const isRecall = entry => Number.isInteger(entry?.seq) && Number.isInteger(entry.until) && Number.isInteger(entry.turn) && Number.isInteger(entry.last)

// Where a seq sits against a part's recalls: 'message' for a recalled message itself,
// 'cut' for anything else in a recalled range.
export function recalledAt(recalls, seq) {
  if (!Array.isArray(recalls) || !Number.isInteger(seq)) return undefined
  for (const entry of recalls) {
    if (!isRecall(entry)) continue
    if (seq === entry.seq) return 'message'
    if (seq > entry.seq && seq <= entry.until) return 'cut'
  }
  return undefined
}

export function install(rt) {
  const { ctx, state } = rt
  // Parts whose recall is running: their turns wait (parts.js holds their input).
  const running = new Set()

  const recallsOf = sessionId => (Array.isArray(state.recalls?.[sessionId]) ? state.recalls[sessionId].filter(isRecall) : [])

  const eventAt = (session, seq) => (typeof session?.eventAt === 'function' ? session.eventAt(seq) : undefined)
  const lastSeq = session => Number(session.seq) - 1

  // The recalled message, checked: the user's own, in the Bot's current part, still in
  // the Bot's context.
  async function target({ botId, sessionId, seq, time }) {
    await rt.load()
    const bot = rt.botOf(String(botId ?? ''))
    if (bot === undefined) throw refused('Unknown Bot', 'bot/not-found')
    if (rt.localAgentOf?.(bot) !== undefined) throw refused('This Bot runs on a local agent CLI, which keeps its own copy of the conversation, so its messages cannot be recalled.', 'bot/refused')
    const part = rt.chatOf(bot.id)
    if (sessionId !== part) throw refused('Only messages in the current conversation can be recalled.', 'bot/stale')
    if (!Number.isInteger(seq)) throw refused('No message named', 'bot/invalid')
    const agent = await rt.resolveAgent(part)
    const session = agent.session
    if (typeof session?.eventAt !== 'function' || !Array.isArray(session.surface?.nodes) || typeof session.append !== 'function') {
      throw refused('This DSH cannot take messages back out of a conversation.', 'bot/refused')
    }
    const event = eventAt(session, seq)
    if (event?.type !== 'user/message' || event.data?.source?.kind !== 'user') throw refused('Only your own messages can be recalled.', 'bot/invalid')
    // A window that lists earlier parts too names the message by its time as well, so a
    // row of an earlier part never recalls the message at the same seq in this one.
    if (time !== undefined && event.time !== time) throw refused('Only messages in the current conversation can be recalled.', 'bot/stale')
    if (recalledAt(recallsOf(part), seq) !== undefined) throw refused('This message was already recalled.', 'bot/stale')
    if (!session.surface.nodes.includes(seq)) throw refused('This message was condensed with earlier ones, so it can no longer be recalled.', 'bot/stale')
    return { bot, part, agent, session, event }
  }

  // The files the turns after the message changed, as far as the change summaries tell:
  // listed paths, how many there are, and `maybe` when a turn wrote with no summary to
  // say what (it has not ended, or its summary is gone).
  function changedFiles(part, session, seq) {
    const service = ctx.get?.('workspaceChanges')
    const turns = new Map()
    const turnOf = number => turns.get(number) ?? turns.set(number, { wrote: false, summarySeq: undefined }).get(number)
    let turn = turnAt(session, seq)
    for (let at = seq; at <= lastSeq(session); at += 1) {
      const event = eventAt(session, at)
      if (event?.type === 'turn/start' && Number.isInteger(event.data?.turn)) turn = event.data.turn
      else if (event?.type === 'tool/call' && WRITE_TOOLS.test(String(event.data?.name ?? ''))) turnOf(event.data?.turn ?? turn).wrote = true
      // The latest summary of a turn replaces earlier ones.
      else if (event?.type === 'workspace/changes' && Number.isInteger(event.data?.turn)) turnOf(event.data.turn).summarySeq = at
    }
    const paths = new Set()
    let omitted = 0
    let maybe = false
    for (const entry of turns.values()) {
      let summary
      if (entry.summarySeq !== undefined) {
        try { summary = service?.summary(part, entry.summarySeq) } catch { summary = undefined }
      }
      if (summary === undefined || !Array.isArray(summary.files)) {
        if (entry.wrote || entry.summarySeq !== undefined) maybe = true
        continue
      }
      for (const file of summary.files) paths.add(String(file.display ?? file.path))
      omitted += Math.max(0, (summary.total ?? summary.files.length) - summary.files.length)
    }
    const files = [...paths]
    return { files: files.slice(0, FILES_LISTED), count: files.length + omitted, maybe: maybe && files.length === 0 }
  }

  // The turn a seq belongs to: the latest turn/start before it.
  function turnAt(session, seq) {
    for (let at = seq; at >= 0; at -= 1) {
      const event = eventAt(session, at)
      if (event?.type === 'turn/start' && Number.isInteger(event.data?.turn)) return event.data.turn
    }
    return 0
  }

  // Whether the message opened its turn: nothing came before it in that turn, neither
  // what the Bot did nor another message that started it. Context that plugins put
  // ahead of it (memory, time) does not count.
  function opensTurn(session, seq) {
    for (let at = seq - 1; at >= 0; at -= 1) {
      const event = eventAt(session, at)
      if (event?.type === 'turn/start') return true
      if (event?.type === 'user/message' && OPENERS.has(event.data?.source?.kind)) return false
      if (event?.type === 'assistant/message' || event?.type === 'tool/call' || event?.type === 'tool/result') return false
    }
    return true
  }

  async function recallCheck(body) {
    const { part, session } = await target(body)
    return changedFiles(part, session, body.seq)
  }

  async function recall(body) {
    const { bot, part, agent, event } = await target(body)
    if (running.has(part)) throw refused('A message in this chat is being recalled already.', 'bot/busy')
    running.add(part)
    try {
      // The turn at work ends; input waiting for the Bot keeps waiting, and a turn it
      // would start meanwhile is held off (parts.js) until the recall is in.
      if (agent.status !== 'idle') {
        await rt.stopSubagents?.(part)
        agent.cancel({ kind: 'user' }, { keepInbox: true })
      }
      let cut
      for (let attempt = 1; cut === undefined; attempt += 1) {
        await agent.whenIdle()
        try {
          cut = await agent.runMaintenance(() => cutFrom(agent, body.seq))
        } catch (error) {
          if (error?.code !== undefined || attempt >= IDLE_ATTEMPTS) throw error
        }
      }
      const entry = { seq: body.seq, until: cut.until, turn: cut.turn, opened: cut.opened, last: cut.last, at: Date.now() }
      state.recalls ??= {}
      state.recalls[part] = [...recallsOf(part), entry]
      closeCardsAfter(part, agent.session, body.seq)
      rt.forgetChatTail?.(part)
      await rt.save()
      await rt.dropIndexedLines?.(part, body.seq, cut.until)
      rt.publishFeed?.('recall', { botId: bot.id, sessionId: part, seq: body.seq, until: cut.until })
      const content = phoneBlocks(event.data?.content)
      return { text: textOf(content), images: content.filter(block => block?.type === 'image').length, until: cut.until }
    } finally {
      running.delete(part)
      rt.wakeInput?.(agent)
    }
  }

  // Inside the agent's maintenance window, so no turn writes meanwhile: the range from
  // the message to the end of the context gives way to the placeholder.
  async function cutFrom(agent, seq) {
    const session = agent.session
    const nodes = session.surface.nodes
    let at = nodes.indexOf(seq)
    if (at === -1) throw refused('This message was condensed with earlier ones, so it can no longer be recalled.', 'bot/stale')
    // Right after an earlier recall's note: the new note stands for both, so the Bot
    // reads one.
    while (at > 0 && eventAt(session, nodes[at - 1])?.data?.source?.kind === RECALL_KIND) at -= 1
    const shadowed = nodes.slice(at)
    const turn = turnAt(session, seq)
    const opened = opensTurn(session, seq)
    let last = turn
    for (let index = seq; index <= lastSeq(session); index += 1) {
      const event = eventAt(session, index)
      if (event?.type === 'turn/start' && Number.isInteger(event.data?.turn)) last = Math.max(last, event.data.turn)
    }
    const placeholder = createUserMessage({ content: [{ type: 'text', text: RECALL_NOTE }], source: { kind: RECALL_KIND } })
    const appended = session.append('user/message', placeholder, {
      surfaceOp: { op: 'replace', startSeq: shadowed[0], endSeq: shadowed.at(-1) },
      sourceEventSeqs: [...shadowed],
    })
    await ctx.sessions.flush(session)
    return { until: appended.seq, turn, opened, last }
  }

  // A question or view card asked in the recalled range closes with it.
  function closeCardsAfter(part, session, seq) {
    for (const cards of [state.questions, state.views]) {
      const card = cards?.[part]
      if (typeof card?.callId !== 'string') continue
      const asked = callSeq(session, card.callId, seq)
      if (asked === undefined) continue
      rt.closeCard(part, card, 'dismissed')
      delete cards[part]
    }
  }
  function callSeq(session, callId, from) {
    for (let at = from; at <= lastSeq(session); at += 1) {
      const event = eventAt(session, at)
      if (event?.type === 'tool/call' && event.data?.callId === callId) return at
    }
    return undefined
  }

  Object.assign(rt, {
    recallCheck,
    recall,
    recallsOf,
    recalledAt: (sessionId, seq) => recalledAt(recallsOf(sessionId), seq),
    isRecalling: sessionId => running.has(sessionId),
  })
}
