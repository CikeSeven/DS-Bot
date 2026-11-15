// The exact thinking time of a Turn, read from the timed model stream DSH keeps in
// each assistant/message event: for one step, its last reasoning chunk's time minus
// its first one's, summed over the turn. assistant/attempt events are skipped on
// purpose — a failed or retried attempt's thinking never reached the reply.
import { HISTORY_TIMEOUT_MS } from './constants.js'

export function thinkingMs(events, turn) {
  let total = 0
  let timed = false
  for (const event of events) {
    if (event.type !== 'assistant/message' || event.data.turn !== turn) continue
    const span = streamReasoningMs(event.data.stream)
    if (span === undefined) continue
    timed = true
    total += span
  }
  return timed ? total : undefined
}

// One stream's reasoning span. A reasoning-chunks record packs its member times as
// the first time plus the gaps to each next member, so its last member lands at
// time0 + sum(dt).
const streamReasoningMs = (stream) => {
  let first
  let last
  for (const record of stream ?? []) {
    if (record.type !== 'reasoning-chunks' || record.texts.length === 0) continue
    const end = record.dt.reduce((time, gap) => time + gap, record.time0)
    if (first === undefined || record.time0 < first) first = record.time0
    if (last === undefined || end > last) last = end
  }
  return first === undefined ? undefined : last - first
}

// What the model thought in one Turn, step by step, cut at THINKING_TEXT_MAX.
const THINKING_TEXT_MAX = 20_000

export function thinkingText(events, turn) {
  const steps = []
  for (const event of events) {
    if (event.type !== 'assistant/message' || event.data.turn !== turn) continue
    const text = (event.data.stream ?? []).filter(record => record.type === 'reasoning-chunks').map(record => record.texts.join('')).join('')
    if (text.trim() !== '') steps.push(text.trim())
  }
  if (steps.length === 0) return undefined
  const whole = steps.join('\n\n')
  return whole.length > THINKING_TEXT_MAX ? { text: whole.slice(0, THINKING_TEXT_MAX), truncated: true } : { text: whole }
}

export function install(rt) {
  // A closed turn's events do not change; cache its answer once turn/end exists.
  const settled = new Map()
  rt.thinkingOf = async (sessionId, turn) => {
    const key = `${sessionId}:${turn}`
    if (settled.has(key)) return settled.get(key)
    const events = []
    // Newest first; events older than the turn close the read.
    for await (const event of rt.eventsBackwards(sessionId, AbortSignal.timeout(HISTORY_TIMEOUT_MS))) {
      events.push(event)
      if (typeof event.data?.turn === 'number' && event.data.turn < turn) break
    }
    // The read went through every newer turn whole, so each closed one is answered too.
    for (const event of events) {
      if (event.type === 'turn/end' && typeof event.data?.turn === 'number' && event.data.turn >= turn) {
        settled.set(`${sessionId}:${event.data.turn}`, thinkingMs(events, event.data.turn))
      }
    }
    return settled.has(key) ? settled.get(key) : thinkingMs(events, turn)
  }
  rt.thinkingTextOf = async (sessionId, turn) => {
    const events = []
    for await (const event of rt.eventsBackwards(sessionId, AbortSignal.timeout(HISTORY_TIMEOUT_MS))) {
      events.push(event)
      if (typeof event.data?.turn === 'number' && event.data.turn < turn) break
    }
    return thinkingText(events, turn)
  }
}
