// The client API for windows that draw the team themselves, a phone app above all
// (docs/plans/2026-10-24-mobile-api.md). On top of the calls the web client makes:
// a versioned handshake, group chats as display items, notices that a client which
// was away (a phone in the background, a dropped link) reads back on its return,
// profile photos by reference, direct memory edits, and usage totals for one Bot.
import { createHash, randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { open, readFile, stat } from 'node:fs/promises'
import { isAbsolute, resolve } from 'node:path'
import { HANDOFF_ACK, HISTORY_TIMEOUT_MS, SOURCE_KIND } from './constants.js'
import { linkPath } from './links.js'
import { PREVIEW_EDGE, previewImage } from './preview.js'
import { relayRange } from '../shared/group-replies.js'
import { textOf } from './text.js'
import { hourKeys } from './usage.js'

const PKG = JSON.parse(readFileSync(new URL('../../package.json', import.meta.url), 'utf8'))

// `api` changes only when a client written for the old one would misread an answer.
// Everything added beside it (an endpoint, a field, an item, notice or feed event kind)
// is named in CAPABILITIES instead, and clients skip what they do not know.
export const API_VERSION = 1
export const API_MIN = 1
export const CAPABILITIES = [
  'state',
  'state-avatar-refs',
  'avatar',
  'chat',
  'room-chat',
  'send',
  'send-images',
  'feed',
  'feed-room',
  'notices',
  'questions',
  'views',
  'approvals',
  'stop-member-work',
  'memory',
  'memory-edit',
  'usage-summary',
  'stop-chat',
  'row-meta',
  'chat-steps',
  'link-feed',
  'images',
  'image-preview',
  'file-download',
  'file-download-chunks',
  'write-state',
  'file-upload',
  'message-search',
  'step-detail',
  'thinking-text',
  'chat-acts',
  'shown-images',
  'recall',
]
export const NOTICE_KINDS = ['message', 'group', 'done', 'question', 'view', 'approval']

// Notices live in memory: a client away longer than this many notices, or across a
// restart (a new `boot`), reads the team again instead.
const NOTICES_KEPT = 200
// Chat photo previews kept in memory, about 50 KB each.
const PREVIEWS_KEPT = 200
const NOTICE_TEXT_MAX = 300
const ROOM_PAGE = 60
// A round's events come in bursts; one `room` feed event covers each burst.
const ROOM_SIGNAL_MS = 150
// Non-revision pending items (approvals, browser holds) coalesce briefly into one `live` signal.
const LIVE_SIGNAL_MS = 50
const ROUND_EVENTS = new Set(['done', 'stopped', 'working', 'approval', 'failed', 'missed', 'lookup', 'resumed', 'cut'])
const POST_HEADER = /^\[Group post from [^\r\n]*\]\r?\n/

const flat = text => String(text ?? '').replace(/\s+/g, ' ').trim()
const noticeText = (text) => {
  const line = flat(text)
  return line.length > NOTICE_TEXT_MAX ? `${line.slice(0, NOTICE_TEXT_MAX)}…` : line
}
// DSH names an image's type `mediaType`; older records said `mime`.
const mediaOf = attachment => attachment?.mediaType ?? attachment?.mime ?? attachment?.mimeType
export const avatarRef = image => createHash('sha256').update(image).digest('hex').slice(0, 16)

// The prompts of a due scheduled task, as DSH frames them for the model.
function reminderText(text) {
  const one = /^reminder_prompt_json: (.*)$/m.exec(text)
  const batch = /^reminders_json: (.*)$/m.exec(text)
  try {
    const prompts = [...(one ? [JSON.parse(one[1])] : []), ...(batch ? JSON.parse(batch[1]).map(entry => entry?.reminder_prompt) : [])]
    return prompts.filter(prompt => typeof prompt === 'string' && prompt.trim() !== '').join(' · ')
  } catch {
    return ''
  }
}

// One reply of a round as an item: a member's message, the user's message that came in
// while the round ran, or an event of the round. `id` names it the same while the round
// runs and once its result is logged, so a client can swap the one for the other.
function replyItem(reply, id, extra = {}) {
  const who = { ...(reply.botId ? { botId: reply.botId } : {}), ...(reply.name ? { name: reply.name } : {}), ...(reply.color ? { color: reply.color } : {}) }
  const time = Number.isFinite(reply.time) ? reply.time : null
  if (reply.kind === 'user') return { id, kind: 'user', text: String(reply.text ?? ''), time, ...extra }
  if (reply.kind === undefined) return { id, kind: 'bot', ...who, text: String(reply.text ?? ''), time, ...(Number.isFinite(reply.duration) ? { duration: reply.duration } : {}), ...extra }
  if (!ROUND_EVENTS.has(reply.kind)) return undefined
  return {
    id, kind: 'event', event: reply.kind, ...who,
    ...(typeof reply.text === 'string' && reply.text !== '' ? { text: reply.text } : {}),
    ...(reply.code ? { code: reply.code } : {}),
    time, ...extra,
  }
}

// A group chat's own Session as display items, oldest first. The Session holds the
// user's messages, Bots' posts from outside the group, and one group_relay call per
// round. A round's result names where its rows are in the group's book of the ledger
// (`rowsOf` reads them); one from before the ledger lists the replies itself.
export function roomItems(events, rowsOf = () => []) {
  const items = []
  const relays = new Map()
  for (const event of events) {
    const seq = event.seq
    if (event.type === 'user/message') {
      const source = event.data?.source
      const content = Array.isArray(event.data?.content) ? event.data.content : []
      if (source?.kind === 'user') {
        const imageBlocks = content.filter(block => block?.type === 'image' && block.attachment !== undefined)
        const imageRefs = imageBlocks.map(block => ({ attachmentId: block.attachment.attachmentId, mime: mediaOf(block.attachment), name: block.attachment.name }))
        items.push({ id: `${seq}`, kind: 'user', text: textOf(content), ...(imageBlocks.length > 0 ? { images: imageBlocks.length, imageRefs } : {}), time: event.time ?? null })
      } else if (source?.kind === 'schedule') {
        items.push({ id: `${seq}`, kind: 'event', event: 'schedule', text: reminderText(textOf(content)), time: event.time ?? null })
      } else if (source?.kind === SOURCE_KIND && source.role === 'post') {
        // A post a running round logged shows inside that round; a member's late failure,
        // picked-up work, stopped work or finished work is an event of the round it opens.
        if (source.logged !== undefined || source.failed !== undefined || source.resumed === true || source.stopped === true || source.done === true) continue
        const file = source.length === undefined ? undefined : content.find(block => block?.type === 'file')?.attachment
        items.push({
          id: `${seq}`, kind: 'bot', botId: source.senderSessionId ?? null, name: source.senderName ?? null,
          text: textOf(content).replace(POST_HEADER, ''), time: event.time ?? null,
          ...(file ? { whole: { length: source.length, file } } : {}),
        })
      }
      continue
    }
    if (event.type === 'tool/call' && event.data?.name === 'group_relay') {
      relays.set(event.data.callId, items.length)
      continue
    }
    if (event.type !== 'tool/result') continue
    const callId = event.data?.message?.toolCallId
    const text = textOf(event.data?.message?.content)
    const range = relayRange(text)
    let replies
    if (range !== undefined) replies = rowsOf(range)
    else {
      try { replies = JSON.parse(text)?.replies } catch { continue }
    }
    if (!Array.isArray(replies)) continue
    relays.delete(callId)
    replies.forEach((reply, index) => {
      const item = replyItem(reply ?? {}, `${callId ?? seq}:${index}`)
      if (item !== undefined) items.push(item)
    })
  }
  // Relays whose result is not in these events yet: still running, or answered on the
  // next page.
  return { items, open: [...relays.entries()].map(([callId, at]) => ({ callId, at })) }
}

// Totals of usage rows, [hour, owner, model, kind, input, cacheRead, cacheWrite, output, calls].
const totals = rows => rows.reduce((sum, row) => ({
  input: sum.input + row[4], cacheRead: sum.cacheRead + row[5], cacheWrite: sum.cacheWrite + row[6], output: sum.output + row[7], calls: sum.calls + row[8],
}), { input: 0, cacheRead: 0, cacheWrite: 0, output: 0, calls: 0 })

export function install(rt) {
  const { ctx, state } = rt
  const boot = randomUUID()
  let seq = 0
  const kept = []

  function addNotice(entry) {
    if (!NOTICE_KINDS.includes(entry.kind)) return undefined
    seq += 1
    const notice = { seq, time: Date.now(), ...entry, text: noticeText(entry.text) }
    kept.push(notice)
    if (kept.length > NOTICES_KEPT) kept.splice(0, kept.length - NOTICES_KEPT)
    rt.publishFeed?.('notice', notice)
    return notice
  }

  // A notice for a Bot names it as it is called now; a deleted Bot leaves none.
  const botNotice = (botId, entry) => {
    const bot = rt.botOf(botId)
    return bot === undefined ? undefined : addNotice({ botId, name: bot.name, ...entry })
  }

  const roomTimers = new Map()
  const roomChanged = (roomId) => {
    if (roomTimers.has(roomId)) return
    const timer = setTimeout(() => {
      roomTimers.delete(roomId)
      rt.publishFeed?.('room', { roomId })
    }, ROOM_SIGNAL_MS)
    // Not unref'd: the signal is due shortly and dispose clears it; an unref'd timer left
    // a client waiting on it with nothing else to keep the loop alive (Node 22).
    roomTimers.set(roomId, timer)
  }

  // Every line a group logs: the group changed, and a member's message or finished work
  // is news for a client that is not looking.
  rt.roomLineAdded = (room, line) => {
    roomChanged(room.id)
    if (line.botId === undefined || line.who === 'User') return
    const base = { roomId: room.id, title: room.name }
    if (line.kind === undefined) botNotice(line.botId, { kind: 'group', ...base, text: line.text })
    else if (line.kind === 'done') botNotice(line.botId, { kind: 'done', ...base, text: '' })
  }

  // A card in a Bot's own chat waits for the user.
  rt.cardShown = (sessionId, kind, text) => {
    const botId = rt.chatOwners.get(sessionId)
    if (botId !== undefined) botNotice(botId, { kind, sessionId, text })
  }
  rt.approvalWaiting = (entry) => {
    const room = rt.roomOf(entry.roomId)
    botNotice(entry.botId, { kind: 'approval', sessionId: entry.sessionId, ...(room ? { roomId: room.id, title: room.name } : {}), text: entry.tool })
  }

  ctx.on('session/event', (session, event) => {
    const id = session?.id
    if (id === undefined) return
    const room = rt.roomOf(id)
    if (room !== undefined) {
      // A round starts or ends.
      if (event.type === 'tool/call' || event.type === 'tool/result' || event.type === 'user/message') roomChanged(room.id)
      return
    }
    if (event.type !== 'assistant/message') return
    const botId = rt.chatOwners.get(id)
    if (botId === undefined || (state.exchangeTurns[id] ?? []).includes(event.data?.turn)) return
    const text = textOf(event.data?.message?.content)
    // The fixed reply that opens a fresh part is not the Bot speaking.
    if (text !== '' && text !== HANDOFF_ACK) botNotice(botId, { kind: 'message', sessionId: id, text })
  })

  let liveTimer
  const liveChanged = () => {
    if (liveTimer !== undefined) return
    liveTimer = setTimeout(() => {
      liveTimer = undefined
      rt.publishFeed?.('live', {})
    }, LIVE_SIGNAL_MS)
  }
  const offApproval = rt.onApproval?.(() => liveChanged())
  const offHolds = rt.browserChannel?.subscribeHolds?.(() => liveChanged())

  ctx.effect(() => () => {
    for (const timer of roomTimers.values()) clearTimeout(timer)
    roomTimers.clear()
    clearTimeout(liveTimer)
    liveTimer = undefined
    offApproval?.()
    offHolds?.()
  }, 'ds-bot: mobile room signals')

  rt.apiVersion = API_VERSION
  rt.noticeCursor = () => ({ boot, seq })

  function hello(body) {
    const offered = Array.isArray(body.api) ? body.api.filter(Number.isInteger) : [API_VERSION]
    const common = offered.filter(version => version >= API_MIN && version <= API_VERSION)
    const rpc = rt.remoteRpc?.()
    return {
      api: common.length > 0 ? Math.max(...common) : null,
      apiMin: API_MIN,
      apiMax: API_VERSION,
      plugin: { name: PKG.name, version: PKG.version },
      capabilities: rpc ? [...CAPABILITIES, 'rpc'] : CAPABILITIES,
      boot,
      seq,
      revision: state.revision,
      readOnly: rt.readOnly() ?? null,
      memory: rt.memoryEnabled !== false,
      feed: 'api/bot/feed',
      ...(rpc ? { rpc } : {}),
    }
  }

  function notices(body) {
    const fresh = body.boot !== boot
    const since = fresh ? 0 : Number.isInteger(body.since) ? body.since : 0
    const oldest = kept[0]?.seq ?? seq + 1
    // Notices past the ring were dropped: the client reads the team again.
    const gap = !fresh && since < oldest - 1
    return { boot, seq, reset: fresh || gap, notices: kept.filter(notice => notice.seq > since) }
  }

  // A state answer with each photo replaced by its reference; `avatar` sends the image.
  rt.slimAvatars = value => (Array.isArray(value?.bots)
    ? { ...value, bots: value.bots.map(bot => (typeof bot.avatar?.image === 'string' ? { ...bot, avatar: { ...bot.avatar, image: undefined, imageRef: avatarRef(bot.avatar.image) } } : bot)) }
    : value)

  function avatar(body) {
    const bot = rt.botOf(String(body.botId ?? ''))
    if (bot === undefined) throw Object.assign(new Error('Unknown Bot'), { code: 'bot/not-found' })
    const image = bot.avatar?.image
    return typeof image === 'string' ? { botId: bot.id, ref: avatarRef(image), image } : { botId: bot.id, ref: null, image: null }
  }

  async function roomChat(body) {
    const room = rt.roomOf(String(body.roomId ?? ''))
    if (room === undefined) throw Object.assign(new Error('Unknown group chat'), { code: 'bot/not-found' })
    const cursor = body.cursor ?? undefined
    const parts = rt.partsOf(undefined, room.id)
    const index = Number.isInteger(cursor?.part) ? cursor.part : parts.length - 1
    if (index < 0 || index >= parts.length) return { roomId: room.id, items: [], cursor: null, running: false, speaking: null }
    const part = parts[index]
    const agent = await rt.resolveAgent(part.sessionId).catch((error) => {
      if (index === parts.length - 1) throw error
      return undefined
    })
    const page = await ctx.sessionController.page({
      address: { kind: 'session', sessionId: part.sessionId },
      ...(agent ? { throughSeq: Number(agent.session.seq) - 1 } : {}),
      ...(Number.isInteger(cursor?.beforeSeq) ? { beforeSeq: cursor.beforeSeq } : {}),
      maxMessages: ROOM_PAGE,
    }, AbortSignal.timeout(HISTORY_TIMEOUT_MS))
    const events = page.records.map(record => record.event)
    const { items, open } = roomItems(events, range => rt.groupRows?.(room.id, range.from, range.to, range.anchor) ?? [])
    if (body.steps === true) await rt.applySteps?.(items, events, part.sessionId)
    const running = [...rt.roomProgress.entries()].filter(([, round]) => round.roomId === room.id)
    // The newest page shows what the running round has said so far, where its call sits.
    if (cursor === undefined) {
      for (const { callId, at } of open.reverse()) {
        const round = rt.roomProgress.get(callId)
        if (round === undefined) continue
        const said = Number.isInteger(round.from) ? rt.groupRows?.(room.id, round.from) ?? [] : round.replies ?? []
        const live = said.map((reply, index) => replyItem(reply, `${callId}:${index}`, { live: true })).filter(Boolean)
        items.splice(at, 0, ...live)
      }
    }
    const more = page.hasMore && events.length > 0
    return {
      roomId: room.id,
      items,
      cursor: more ? { part: index, beforeSeq: events[0].seq } : index > 0 ? { part: index - 1 } : null,
      running: running.length > 0,
      speaking: running.map(([, round]) => round.slots?.find(slot => slot.status === 'speaking')?.id ?? round.speaking).find(Boolean) ?? null,
    }
  }

  function memoryTarget(body) {
    return body.roomId !== undefined && body.roomId !== null ? { roomId: String(body.roomId) } : { botId: String(body.botId ?? '') }
  }

  async function usageSummary(body) {
    const bot = rt.botOf(String(body.botId ?? ''))
    if (bot === undefined) throw Object.assign(new Error('Unknown Bot'), { code: 'bot/not-found' })
    const timeZone = typeof body.timeZone === 'string' ? body.timeZone.slice(0, 64) : undefined
    const view = await rt.usageView({ timeZone })
    const owner = view.owners.findIndex(entry => entry.kind === 'bot' && entry.id === bot.id)
    const rows = owner < 0 ? [] : view.rows.filter(row => row[1] === owner)
    const hourOf = hourKeys(timeZone)
    const since = hours => hourOf(Date.now() - (hours - 1) * 3_600_000)
    const within = hours => rows.filter(row => row[0] >= since(hours))
    const month = within(24 * 30)
    const models = view.models.map((model, index) => ({ key: model.key, name: model.name, ...totals(month.filter(row => row[2] === index)) }))
      .filter(model => model.calls > 0 || model.input > 0 || model.output > 0)
    return { botId: bot.id, day: totals(within(24)), week: totals(within(24 * 7)), month: totals(month), models, scanning: view.scanning }
  }

  // Previews by attachment id, least recently used first; null for a photo sent whole.
  const previews = new Map()
  const keep = (key, small) => {
    previews.delete(key)
    previews.set(key, small)
    while (previews.size > PREVIEWS_KEPT) previews.delete(previews.keys().next().value)
  }
  const shown = (key) => {
    const small = previews.get(key)
    keep(key, small)
    return { mime: 'image/jpeg', data: small.toString('base64'), preview: true }
  }

  // A screenshot can come back as a file block; its type or its name says it is an image.
  const isImageBlock = block => block?.attachment !== undefined
    && (block.type === 'image' || (block.type === 'file'
      && ((mediaOf(block.attachment) ?? '').startsWith('image/') || /\.(png|jpe?g|gif|webp)$/i.test(block.attachment.name ?? ''))))
  async function imageBytes(attachments, block) {
    const signal = AbortSignal.timeout(HISTORY_TIMEOUT_MS)
    // An image block's ref names no file: DSH reads it as an image, not a file.
    if (block.type === 'image') return Buffer.from((await attachments.readImage(block.attachment, signal)).data)
    const chunks = []
    for await (const chunk of attachments.readFileStream(block.attachment, signal)) chunks.push(chunk)
    return Buffer.concat(chunks)
  }

  async function image(body) {
    if (typeof body.path === 'string') return shownImage(body)
    if (Number.isInteger(body.seq)) return presentedImage(body)
    const sessionId = String(body.sessionId ?? '')
    const room = rt.roomOf(sessionId) ?? rt.roomOf(rt.pastOwners.get(sessionId)?.roomId)
    const botId = room === undefined ? rt.chatOwners.get(sessionId) ?? rt.pastOwners.get(sessionId)?.botId : undefined
    if (botId === undefined && room === undefined) throw Object.assign(new Error('Unknown session'), { code: 'bot/not-found' })
    const attachments = ctx.get?.('attachments')
    if (attachments === undefined) throw Object.assign(new Error('Attachments unavailable'), { code: 'bot/refused' })
    const sessions = [...new Set([
      ...(room !== undefined ? [rt.sessionOfRoom(room)] : []),
      sessionId,
      ...rt.partsOf(botId, room?.id).map(part => part.sessionId).reverse(),
    ])]
    for (const targetId of sessions) {
      let beforeSeq
      for (;;) {
        const page = await ctx.sessionController.page({
          address: { kind: 'session', sessionId: targetId },
          ...(beforeSeq !== undefined ? { beforeSeq } : {}),
          maxMessages: 500,
        }, AbortSignal.timeout(HISTORY_TIMEOUT_MS))
        for (const record of page.records) {
          // A message's photos, and the screenshot a computer step answered with.
          const data = record.event?.data
          const content = Array.isArray(data?.content) ? data.content : Array.isArray(data?.message?.content) ? data.message.content : []
          for (const block of content) {
            if (isImageBlock(block) && String(block.attachment?.attachmentId) === String(body.attachmentId)) {
              const key = String(block.attachment.attachmentId)
              if (body.preview === true && previews.get(key)) return shown(key)
              const bytes = await imageBytes(attachments, block)
              const mime = mediaOf(block.attachment) ?? 'image/png'
              const { width, height } = block.attachment
              if (body.preview === true && !(Math.max(width, height) <= PREVIEW_EDGE)) {
                // A photo that cannot be shrunk is sent as it is, and remembered as such.
                const small = await previewImage(bytes, mime).catch(() => null)
                keep(key, small)
                if (small !== null) return shown(key)
              }
              return { mime, data: bytes.toString('base64') }
            }
          }
        }
        if (page.hasMore !== true) break
        beforeSeq = page.records[0]?.event?.seq
        if (beforeSeq === undefined) break
      }
    }
    throw Object.assign(new Error('Unknown attachment'), { code: 'bot/not-found' })
  }

  // Save an attachment or a presented file onto the device. The bytes travel as
  // base64 over the same call the rest of the phone API uses; the client writes
  // them to a file it can hand to Android.
  const FILE_DOWNLOAD_MAX = 16 * 1024 * 1024 // Compatibility for older, whole-file clients.
  const FILE_CHUNK_BYTES = 512 * 1024
  const FILE_MIMES = { pdf: 'application/pdf', txt: 'text/plain', md: 'text/markdown', csv: 'text/csv', json: 'application/json', zip: 'application/zip', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp', mp3: 'audio/mpeg', mp4: 'video/mp4' }
  const nameOf = value => String(value).split(/[\\/]/).pop() || 'file'
  const mimeOf = value => FILE_MIMES[(nameOf(value).split('.').pop() ?? '').toLowerCase()] ?? 'application/octet-stream'
  const tooLarge = () => Object.assign(new Error('This file is too large to save here (over 16 MB)'), { code: 'bot/refused' })
  const unavailable = () => Object.assign(new Error('This file is no longer available'), { code: 'bot/not-found' })

  // The Sessions a phone may fetch files from through the chat `sessionId` names: a Bot's
  // own chat or a group with every part of it, or one member's Session in a group.
  function ownedSessions(sessionId) {
    const groupOwner = rt.groupOwners?.get(sessionId)
    const pastOwner = rt.pastOwners.get(sessionId)
    const memberBotId = groupOwner?.botId ?? (pastOwner?.roomId !== undefined ? pastOwner.botId : undefined)
    const room = rt.roomOf(sessionId) ?? rt.roomOf(groupOwner?.roomId ?? pastOwner?.roomId)
    const botId = memberBotId ?? (room === undefined
      ? rt.chatOwners.get(sessionId) ?? pastOwner?.botId ?? rt.botOf(sessionId)?.id
      : undefined)
    if (botId === undefined && room === undefined) throw Object.assign(new Error('Unknown session'), { code: 'bot/not-found' })
    return new Set([
      ...(room !== undefined && memberBotId === undefined ? [rt.sessionOfRoom(room)] : []),
      ...(room !== undefined && memberBotId !== undefined && room.sessions?.[memberBotId] ? [room.sessions[memberBotId]] : []),
      ...(room === undefined && botId !== undefined ? [rt.chatOf(botId)] : []),
      ...rt.partsOf(botId, room?.id).map(part => part.sessionId),
    ].filter(Boolean))
  }

  // A file on this computer outside DSH's and the team's data: its real path and stat.
  async function fileAt(path) {
    const realPath = await rt.real?.(path) ?? path
    if (await rt.inData?.(realPath)) throw unavailable()
    const info = await stat(realPath).catch(() => undefined)
    if (info?.isFile() !== true) throw unavailable()
    return { path: realPath, info }
  }

  // A file a turn presented, by the coordinates its Bot row carries. Presented files keep
  // their own part's sessionId, because seq is local to one Session.
  async function presentedFile(sessionId, seq, index) {
    if (!ownedSessions(sessionId).has(sessionId)) throw unavailable()
    let beforeSeq
    for (;;) {
      const page = await ctx.sessionController.page({
        address: { kind: 'session', sessionId },
        ...(beforeSeq !== undefined ? { beforeSeq } : {}),
        maxMessages: 500,
      }, AbortSignal.timeout(HISTORY_TIMEOUT_MS))
      for (const record of page.records) {
        const event = record.event
        if (event?.type !== 'deliverables/presented' || Number(event.seq) !== seq) continue
        const file = Array.isArray(event.data?.files) ? event.data.files[index] : undefined
        if (typeof file?.path !== 'string') continue
        return { name: typeof file.name === 'string' && file.name !== '' ? file.name : nameOf(file.path), ...await fileAt(file.path) }
      }
      if (page.hasMore !== true) break
      beforeSeq = page.records[0]?.event?.seq
      if (beforeSeq === undefined) break
    }
    throw unavailable()
  }

  // Images a Bot's reply shows from files on this computer: a Markdown image, or an image
  // file the turn presented. One message over the phone link carries at most 4 MiB
  // (link/crates/core/src/frag.rs) after base64, so a larger image goes as a JPEG of it.
  const SHOWN_IMAGE = /\.(png|jpe?g|gif|webp)$/i
  const SHOWN_WHOLE_MAX = 2 * 1024 * 1024
  const SHOWN_READ_MAX = 32 * 1024 * 1024
  const SHOWN_EDGE = 2048
  const notImage = () => Object.assign(new Error('Not an image'), { code: 'bot/invalid' })
  const tooLargeToShow = () => Object.assign(new Error('This image is too large to show on the phone'), { code: 'bot/refused' })

  async function fileImage({ path, info }, preview) {
    // The file's version is in the key, so an image written over shows anew.
    const key = `file:${path}:${info.size}:${info.mtimeMs}`
    if (preview && previews.get(key)) return shown(key)
    if (info.size > SHOWN_READ_MAX) throw tooLargeToShow()
    const bytes = await readFile(path)
    const mime = mimeOf(path)
    if (preview) {
      const small = await previewImage(bytes, mime).catch(() => null)
      keep(key, small)
      if (small !== null) return shown(key)
    } else if (bytes.length > SHOWN_WHOLE_MAX) {
      const large = await previewImage(bytes, mime, { edge: SHOWN_EDGE, quality: 85, always: true }).catch(() => null)
      if (large !== null) return { mime: 'image/jpeg', data: large.toString('base64') }
    }
    if (bytes.length > SHOWN_WHOLE_MAX) throw tooLargeToShow()
    return { mime, data: bytes.toString('base64') }
  }

  // A Markdown image, by the destination the reply wrote. A relative path names a file in
  // the folder of the chat that shows it, as DSH's chat reads it.
  async function shownImage(body) {
    const sessionId = String(body.sessionId ?? '')
    ownedSessions(sessionId)
    const path = linkPath(body.path)
    if (path === undefined || !SHOWN_IMAGE.test(path)) throw notImage()
    if (isAbsolute(path)) return fileImage(await fileAt(path), body.preview === true)
    const folder = rt.sessionFolder?.(ctx.get?.('agents')?.get?.(sessionId)?.session ?? { id: sessionId })
    if (folder === undefined) throw unavailable()
    return fileImage(await fileAt(resolve(folder, path)), body.preview === true)
  }

  async function presentedImage(body) {
    const file = await presentedFile(String(body.sessionId ?? ''), body.seq, Number.isInteger(body.index) ? body.index : 0)
    if (!SHOWN_IMAGE.test(file.name) && !SHOWN_IMAGE.test(file.path)) throw notImage()
    return fileImage(file, body.preview === true)
  }

  async function fileDownload(body) {
    const chunked = body.offset !== undefined
    const offset = chunked ? body.offset : 0
    if (!Number.isSafeInteger(offset) || offset < 0) throw Object.assign(new Error('Invalid file offset'), { code: 'bot/invalid' })
    const attachments = ctx.get?.('attachments')
    if (attachments === undefined) throw Object.assign(new Error('Attachments unavailable'), { code: 'bot/refused' })
    const attachmentId = typeof body.attachmentId === 'string' ? body.attachmentId : undefined
    const presentedSeq = Number.isInteger(body.seq) ? body.seq : undefined
    const presentedIndex = Number.isInteger(body.index) ? body.index : 0
    if (attachmentId === undefined && presentedSeq === undefined) throw Object.assign(new Error('No file named'), { code: 'bot/invalid' })
    const sessionId = String(body.sessionId ?? '')
    if (presentedSeq !== undefined) {
      const { name, path, info } = await presentedFile(sessionId, presentedSeq, presentedIndex)
      if (chunked) {
        const version = `${info.dev}:${info.ino}:${info.size}:${info.mtimeMs}`
        if (body.version !== undefined && body.version !== version) throw unavailable()
        if (offset > info.size) throw unavailable()
        const handle = await open(path, 'r')
        try {
          const bytes = Buffer.alloc(Math.min(FILE_CHUNK_BYTES, info.size - offset))
          const { bytesRead } = await handle.read(bytes, 0, bytes.length, offset)
          if (bytesRead !== bytes.length) throw unavailable()
          return { name, mime: mimeOf(path), bytes: bytes.toString('base64'), size: info.size, version, nextOffset: offset + bytesRead, done: offset + bytesRead === info.size }
        } finally { await handle.close() }
      }
      if (info.size > FILE_DOWNLOAD_MAX) throw tooLarge()
      const bytes = await readFile(path)
      return { name, mime: mimeOf(path), bytes: bytes.toString('base64'), size: bytes.length }
    }
    for (const targetId of [...ownedSessions(sessionId)].reverse()) {
      let beforeSeq
      for (;;) {
        const page = await ctx.sessionController.page({
          address: { kind: 'session', sessionId: targetId },
          ...(beforeSeq !== undefined ? { beforeSeq } : {}),
          maxMessages: 500,
        }, AbortSignal.timeout(HISTORY_TIMEOUT_MS))
        for (const record of page.records) {
          const event = record.event
          const content = Array.isArray(event?.data?.content) ? event.data.content : []
          for (const block of content) {
            if (block?.type !== 'file' || String(block.attachment?.attachmentId) !== attachmentId) continue
            if (chunked) {
              // Attachment ids are content hashes. Stream only as far as this chunk needs.
              const chunks = []
              let seen = 0
              let length = 0
              for await (const chunk of attachments.readFileStream(block.attachment, AbortSignal.timeout(HISTORY_TIMEOUT_MS))) {
                const start = Math.max(0, offset - seen)
                seen += chunk.length
                const data = Buffer.from(chunk).subarray(start, start + FILE_CHUNK_BYTES - length)
                if (data.length > 0) { chunks.push(data); length += data.length }
                if (length === FILE_CHUNK_BYTES) break
              }
              const size = block.attachment.bytes
              if (offset > size || (length === 0 && offset < size)) throw unavailable()
              const nextOffset = offset + length
              return { name: nameOf(block.attachment.name), mime: mediaOf(block.attachment) ?? mimeOf(block.attachment.name), bytes: Buffer.concat(chunks).toString('base64'), size, version: attachmentId, nextOffset, done: nextOffset >= size }
            }
            const chunks = []
            let size = 0
            for await (const chunk of attachments.readFileStream(block.attachment, AbortSignal.timeout(HISTORY_TIMEOUT_MS))) {
              size += chunk.length
              if (size > FILE_DOWNLOAD_MAX) throw tooLarge()
              chunks.push(Buffer.from(chunk))
            }
            const bytes = Buffer.concat(chunks)
            return { name: nameOf(block.attachment.name ?? 'file'), mime: mediaOf(block.attachment) ?? mimeOf(block.attachment.name ?? ''), bytes: bytes.toString('base64'), size: bytes.length }
          }
        }
        if (page.hasMore !== true) break
        beforeSeq = page.records[0]?.event?.seq
        if (beforeSeq === undefined) break
      }
    }
    throw unavailable()
  }

  // Messages of one Bot's own chat, every part, with all the words: newest first.
  const SEARCH_TEXT_MAX = 2000
  async function messageSearch(body) {
    const bot = rt.botOf(String(body.botId ?? ''))
    if (bot === undefined) throw Object.assign(new Error('Unknown Bot'), { code: 'bot/not-found' })
    const query = String(body.query ?? '').slice(0, 200)
    const rows = await rt.findOwnChat(bot.id, query)
    return { results: rows.map(row => ({ ...row, text: row.text.length > SEARCH_TEXT_MAX ? `${row.text.slice(0, SEARCH_TEXT_MAX)}…` : row.text })) }
  }

  // One tool call of a Turn, by its place in the Turn's steps row: what it was
  // called with and what it gave back, each cut at STEP_PART_MAX.
  const STEP_PART_MAX = 8000
  const HIDDEN_STEPS = new Set(['ask_user', 'request_secret', 'group_relay'])
  const cut = text => (text.length > STEP_PART_MAX ? { text: text.slice(0, STEP_PART_MAX), truncated: true } : { text, truncated: false })
  async function stepDetail(body) {
    const sessionId = String(body.sessionId ?? '')
    const turn = Number(body.turn)
    const index = Number(body.index)
    if (rt.selfOf(sessionId) === undefined) throw Object.assign(new Error('Unknown session'), { code: 'bot/not-found' })
    if (!Number.isInteger(turn) || !Number.isInteger(index) || index < 0) throw Object.assign(new Error('Name a turn and a step'), { code: 'bot/invalid' })
    const events = []
    for await (const event of rt.eventsBackwards(sessionId, AbortSignal.timeout(HISTORY_TIMEOUT_MS))) {
      events.push(event)
      if (event.type === 'turn/start' && event.data?.turn === turn) break
    }
    events.reverse()
    let current
    const calls = []
    for (const event of events) {
      if (event.type === 'turn/start') current = event.data?.turn
      else if (current === turn && event.type === 'tool/call' && typeof event.data?.name === 'string' && !HIDDEN_STEPS.has(event.data.name)) calls.push(event)
    }
    const call = calls[index]
    if (call === undefined) throw Object.assign(new Error('That step is no longer there'), { code: 'bot/not-found' })
    const result = events.find(event => event.type === 'tool/result' && event.data?.message?.toolCallId === call.data.callId)
    const args = typeof call.data.arguments === 'string' ? call.data.arguments : JSON.stringify(call.data.arguments ?? {})
    let pretty = args
    try { pretty = JSON.stringify(JSON.parse(args), null, 2) } catch { /* not JSON: shown as sent */ }
    const input = cut(pretty)
    const output = cut(result === undefined ? '' : textOf(result.data.message.content))
    return {
      name: call.data.name,
      arguments: input.text,
      output: output.text,
      ...(typeof result?.data?.message?.ok === 'boolean' ? { ok: result.data.message.ok } : {}),
      done: result !== undefined,
      truncated: input.truncated || output.truncated,
    }
  }

  async function mobileEndpoint(endpoint, body) {
    switch (endpoint) {
      case 'message-search': return messageSearch(body)
      case 'step-detail': return stepDetail(body)
      case 'hello': return hello(body)
      case 'notices': return notices(body)
      case 'avatar': return avatar(body)
      case 'room-chat': return roomChat(body)
      case 'image': return image(body)
      case 'file-download': return fileDownload(body)
      case 'usage-summary': return usageSummary(body)
      case 'memory-edit': return rt.memoryEdit({ ...memoryTarget(body), scope: body.scope, topic: body.topic, text: body.text, next: body.next })
      case 'memory-add': return rt.memoryAdd({ ...memoryTarget(body), scope: body.scope, topic: body.topic, text: body.text })
      default: throw Object.assign(new Error(`Unknown endpoint ${endpoint}`), { code: 'bot/not-found' })
    }
  }

  Object.assign(rt, { addNotice, mobileEndpoint })
}
