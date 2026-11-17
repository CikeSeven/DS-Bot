import { createElement as h, Fragment, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import * as ui from '@deepseek-ai/dsh-client-ui-primitives'
import { imPlatform } from '../shared/im-platforms.js'
import { mentionSpans } from '../shared/mentions.js'
import { sentBlocks } from '../shared/sent-gif.js'
import { BotMark } from './mark.js'
import { CheckIcon, CopyIcon, RecallIcon } from './icons.js'
import { dateLocale, hostText, t } from './i18n.js'
import { noHover } from './motion.js'
import { clockLabel, currentPart, messageClock, recallOf } from './text.js'
import { useFold } from './fold.js'
import { CellEmpty } from './cell-empty.js'

// -------------------------------------------------------------------------
// The user's own messages. DSH draws every "@word" in them as a file reference, and
// cuts it at the first space, so "@新 Bot" showed as a file "新". Here the Bot mentions
// are cut out first, by the rule the group host calls them with; DSH's own drawing
// keeps everything else (files, conversation references, skills).

// DSH releases without the text projection keep their own bubble.
export const canDrawUserMessages = () => typeof ui.projectUserText === 'function'

export function contentParts(content) {
  const texts = []
  const attachments = []
  const rest = []
  for (const block of sentBlocks(content)) {
    if (block?.type === 'text' && typeof block.text === 'string') texts.push(block.text)
    else if ((block?.type === 'image' || block?.type === 'file') && block.attachment !== undefined) attachments.push(block)
    else rest.push(block)
  }
  // Joined as the group host joins them, so a mention never spans two blocks here only.
  return { text: texts.join('\n'), attachments, rest }
}

// In a group only its members are called; elsewhere a mention opens that Bot's chat.
export function mentionableBots(roster, sessionId) {
  const room = roster.roomsById[sessionId]
  if (room) return room.members.map(id => roster.byId[id]).filter(Boolean)
  return roster.byId[sessionId] ? roster.bots : []
}

// Runs of plain text and Bot mentions, in order.
export function userTextParts(text, bots, referenceLabels = []) {
  const parts = []
  let cursor = 0
  for (const span of mentionSpans(text, bots, { references: referenceLabels })) {
    if (!span.bot) continue
    if (span.start > cursor) parts.push({ text: text.slice(cursor, span.start) })
    parts.push({ bot: span.bot, label: text.slice(span.start + 1, span.end) })
    cursor = span.end
  }
  if (cursor < text.length) parts.push({ text: text.slice(cursor) })
  return parts
}

function UserText({ text, bots, referenceLabels, skillNames, references, actions }) {
  return userTextParts(text, bots, referenceLabels).map((part, index) => (part.bot
    ? h('button', { key: index, type: 'button', className: 'bt-umention', title: `@${part.bot.name}`, onClick: () => actions.openSession(part.bot.id) },
      h(BotMark, { bot: part.bot, size: 16 }), part.label)
    : h(Fragment, { key: index }, ui.projectUserText(part.text, referenceLabels, skillNames, 'skill', references))))
}

function Attachments({ attachments, renderMessageImages }) {
  const compact = attachments.length > 1
  return h('div', { className: 'bt-uattach' }, attachments.map((block, index) => {
    if (block.type === 'image') {
      return renderMessageImages ? h(Fragment, { key: index }, renderMessageImages({ images: [{ attachment: block.attachment }], align: 'end', compact })) : null
    }
    const file = block.attachment
    const meta = [ui.fileExtension?.(file.name)?.toUpperCase().slice(0, 8), ui.fileSizeText?.(file.bytes)].filter(Boolean).join(' · ')
    return h('span', { key: index, className: 'bt-ufile', title: file.name },
      ui.FileTypeIcon ? h(ui.FileTypeIcon, { path: file.name, className: 'bt-ufile-icon' }) : null,
      h('span', { className: 'bt-ufile-text' }, h('span', { className: 'bt-ufile-name' }, file.name), meta ? h('span', { className: 'bt-ufile-meta' }, meta) : null))
  }))
}

function CopyButton({ text }) {
  const [copied, setCopied] = useState(false)
  const copy = () => {
    void navigator.clipboard?.writeText(text).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1000) })
  }
  return h('button', { type: 'button', className: 'bt-tool', 'aria-label': copied ? t('Copied') : t('Copy'), title: copied ? t('Copied') : t('Copy'), onClick: copy }, copied ? h(CheckIcon) : h(CopyIcon))
}

const clock = time => (typeof time === 'number' ? new Date(time).toLocaleTimeString(dateLocale(), { hour: 'numeric', minute: '2-digit' }) : undefined)

// A message that came in over IM names its platform: "via Telegram" by the time.
export const viaOf = source => (typeof source?.rpcId === 'string' && source.rpcId.startsWith('im:') ? source.rpcId.split(':')[1] : undefined)
export const ViaTag = ({ via }) => h('span', { className: 'bt-uvia' }, t('via {platform}', { platform: t(imPlatform(via)?.name ?? via) }))

// The Bot whose current part this is, when the user can recall a message of theirs in
// it: not a group, not an earlier part, not a Bot on a local agent CLI (its CLI keeps
// its own copy of the chat).
export function recallTarget(roster, sessionId, data) {
  const bot = roster.byId[sessionId]
  if (bot === undefined || roster.roomsById[sessionId] !== undefined || currentPart(bot) !== sessionId || bot.engine !== undefined) return undefined
  if (data?.source?.kind !== 'user' || !Number.isInteger(data.seq)) return undefined
  return bot
}

// What the warning before a recall says about the files the Bot changed after the
// message; nothing when it changed none.
export function recallWarning(check, name) {
  if (check === undefined || check === null) return ''
  if (check.count === 1) return t('{name} changed a file after this message. Recalling leaves it as it is.', { name })
  if (check.count > 1) return t('{name} changed {count} files after this message. Recalling leaves them as they are.', { name, count: check.count })
  return check.maybe ? t('{name} may have changed files after this message. Recalling leaves them as they are.', { name }) : ''
}

// Where a recalled message was: one quiet line. The turns the recall took away whole
// also hide the rows DS Bot does not draw itself (a retry note, a command, the cards at
// a turn's end), scoped to the chat this line is in.
function RecalledLine({ sessionId, roster, seq }) {
  const entry = (roster.recalls?.[sessionId] ?? []).find(item => item.seq === seq)
  const turns = []
  for (let turn = entry?.opened ? entry.turn : (entry?.turn ?? 0) + 1; entry !== undefined && turn <= entry.last; turn += 1) turns.push(turn)
  const css = turns.length === 0 ? '' : `[data-chat-flow]:has([data-bt-recall="${seq}"]) :is(${turns.map(turn => `[data-chat-turn="${turn}"]`).join(',')})[data-chat-flow-kind]:not(:has(.bt-recalled)){display:none!important}`
  return h('div', { className: 'bt-event bt-recalled', 'data-bt-recall': seq },
    t('You recalled a message'),
    css ? h('style', null, css) : null)
}

// Recalling the user's own message: check first, warn when the Bot changed files after
// it, then recall and put the text back in the message box (after what is already
// there, so a draft is never lost).
function useRecall({ bot, sessionId, seq, actions, inputActions, useInput }) {
  const empty = useInput?.(state => state.draft.trim() === '' && state.attachmentIds.length === 0) !== false
  const [state, setState] = useState(null)
  const failed = error => setState({ phase: 'error', error: hostText(error?.message ?? String(error)) })
  const target = bot === undefined ? undefined : { botId: bot.id, sessionId, seq }
  const run = async () => {
    setState({ phase: 'busy' })
    try {
      const result = await actions.recallMessage(target)
      const text = typeof result?.text === 'string' ? result.text : ''
      if (text !== '' && inputActions !== undefined) {
        if (empty) inputActions.setDraft(text)
        else inputActions.insertText(`\n${text}`, inputActions.captureInsertion())
      }
      setState(null)
    } catch (error) { failed(error) }
  }
  const start = async () => {
    if (target === undefined || state?.phase === 'busy' || state?.phase === 'checking') return
    setState({ phase: 'checking' })
    try {
      const check = await actions.recallCheck(target)
      if (recallWarning(check, bot.name) !== '') setState({ phase: 'confirm', check })
      else await run()
    } catch (error) { failed(error) }
  }
  return { state, start, confirm: () => void run(), cancel: () => setState(null), busy: state?.phase === 'busy' || state?.phase === 'checking' }
}

function RecallButton({ recall }) {
  const label = t('Recall')
  return h('button', { type: 'button', className: 'bt-tool', 'aria-label': label, title: label, disabled: recall.busy, onClick: () => void recall.start() }, h(RecallIcon))
}

function RecallNote({ bot, recall }) {
  const { state, cancel, confirm } = recall
  if (state?.phase === 'error') return h('div', { className: 'bt-recall-note', role: 'alert', 'data-error': '' }, h('span', null, state.error), h('div', { className: 'bt-recall-actions' }, h('button', { type: 'button', className: 'bt-soft bt-soft-sm', onClick: cancel }, t('Close'))))
  if (state?.phase !== 'confirm') return null
  const files = state.check.files ?? []
  return h('div', { className: 'bt-recall-note', role: 'alertdialog', 'aria-label': t('Recall this message?') },
    h('span', null, recallWarning(state.check, bot.name)),
    files.length > 0 ? h('span', { className: 'bt-recall-files' }, files.slice(0, 3).join(t(', ')) + (state.check.count > Math.min(files.length, 3) ? '…' : '')) : null,
    h('div', { className: 'bt-recall-actions' },
      h('button', { type: 'button', className: 'bt-soft bt-soft-sm', onClick: cancel }, t('Cancel')),
      h('button', { type: 'button', className: 'bt-soft bt-soft-sm bt-recall-go', onClick: confirm }, t('Recall'))))
}

// DSH's own bubble, on a DSH without the text projection (dsh-user-bubble.js): drawn as
// DSH draws it, with the recall button added to its action row, the one with Copy that
// shows on hover. A warning goes under the bubble.
export function DshUserMessage(props) {
  const { Original, node, sessionId, useRoster, actions, inputActions, useInput } = props
  const roster = useRoster(value => value)
  const data = node?.data ?? {}
  const bot = recallTarget(roster, sessionId, data)
  const recall = useRecall({ bot, sessionId, seq: data.seq, actions, inputActions, useInput })
  const recalled = recallOf(roster, sessionId, node)
  const host = useRef(null)
  const [tools, setTools] = useState(null)
  // An animated GIF sent from the phone or an IM chat shows as the GIF's file, without
  // the note and the sheet of frames written for the model.
  const shown = useMemo(() => {
    const content = Array.isArray(data.content) ? sentBlocks(data.content) : data.content
    return content === data.content ? node : { ...node, data: { ...data, content } }
  }, [node, data])
  useLayoutEffect(() => {
    const found = host.current?.querySelector('[class*="_userRow"] [class*="_actions"]') ?? null
    setTools(current => (current === found ? current : found))
  })
  if (recalled === 'message') return h(RecalledLine, { sessionId, roster, seq: data.seq })
  if (recalled === 'cut') return h(CellEmpty)
  const { Original: _original, ...rest } = props
  return h('div', { ref: host, className: 'bt-udsh' },
    h(Original, { ...rest, node: shown }),
    bot !== undefined && tools !== null ? createPortal(h(RecallButton, { recall }), tools) : null,
    bot !== undefined && recall.state !== null ? h('div', { className: 'bt-udsh-note' }, h(RecallNote, { bot, recall })) : null)
}

// A sent message, or one that joined a running turn ("steering").
export function UserMessageCell({ node, sessionId, useRoster, actions, renderMessageImages, openFile, openSkill, inputActions, useInput }) {
  const roster = useRoster(value => value)
  const data = node.data ?? {}
  const { text, attachments, rest } = contentParts(data.content)
  const referenceLabels = data.referenceLabels ?? []
  const references = openFile && openSkill ? { openFile, openSkill } : undefined
  const steering = node.kind === 'steering'
  const sentAt = Number.isFinite(data.time) ? messageClock(data.time) : undefined
  const via = viaOf(data.source) ?? roster.imVia?.[sessionId]?.[data.seq]
  const { shown, folded, control } = useFold(text, { markdown: false })
  const body = h(UserText, { text: shown, bots: mentionableBots(roster, sessionId), referenceLabels, skillNames: data.skillNames ?? [], references, actions })
  const row = useRef(null)
  // Touch has no hover: a tap on the bubble opens its copy tool, a tap elsewhere closes it.
  const [toolsOpen, setToolsOpen] = useState(false)
  useEffect(() => {
    if (!toolsOpen) return undefined
    const onDown = (event) => { if (!row.current?.contains(event.target)) setToolsOpen(false) }
    window.addEventListener('mousedown', onDown)
    window.addEventListener('touchstart', onDown)
    return () => { window.removeEventListener('mousedown', onDown); window.removeEventListener('touchstart', onDown) }
  }, [toolsOpen])
  const tapTools = (event) => {
    if (!noHover() || event.target instanceof Element && event.target.closest('a,button,input,textarea,select,pre,code,[role=button],[role=link]')) return
    setToolsOpen(value => !value)
  }
  const recallBot = recallTarget(roster, sessionId, data)
  const recall = useRecall({ bot: recallBot, sessionId, seq: data.seq, actions, inputActions, useInput })
  const recalled = recallOf(roster, sessionId, node)
  if (recalled === 'message') return h(RecalledLine, { sessionId, roster, seq: data.seq })
  if (recalled === 'cut') return h(CellEmpty)
  const tools = [
    ...(text === '' ? [] : [h(CopyButton, { key: 'copy', text })]),
    ...(recallBot === undefined ? [] : [h(RecallButton, { key: 'recall', recall })]),
  ]
  return h('div', { ref: row, className: 'bt-umsg', 'data-steering': steering || undefined },
    h('div', { className: 'bt-ustack' },
      attachments.length > 0 ? h(Attachments, { attachments, renderMessageImages }) : null,
      text !== '' || rest.length > 0 ? h('div', { className: 'bt-ubody', title: clock(data.time), 'data-folded': folded || undefined, 'data-text-interaction-source': text !== '' ? '' : undefined, onClick: tapTools },
        control ? h('div', { className: 'bt-fold-body' }, body) : body,
        control,
        rest.map((block, index) => (ui.JsonBlock ? h(ui.JsonBlock, { key: index, label: t('Content'), payload: block }) : null))) : null,
      referenceLabels.length > 0 ? h('div', { className: 'bt-urefs' }, t('Referenced {labels}', { labels: referenceLabels.join(t(', ')) })) : null,
      (sentAt || via) ? h('div', { className: 'bt-utime', title: clockLabel(data.time) }, ...(via ? [h(ViaTag, { key: 'via', via })] : []), sentAt) : null,
      recallBot === undefined ? null : h(RecallNote, { bot: recallBot, recall })),
    tools.length === 0 ? null : h('div', { className: 'bt-utools', 'data-open': toolsOpen || recall.state !== null || undefined }, tools))
}

export const USER_MESSAGE_CSS = `
.bt-umsg{display:flex;flex-direction:row-reverse;align-items:center;justify-content:flex-start;gap:4px}
.bt-ustack{min-width:0;max-width:calc(var(--bt-msg-w) * 100%);display:flex;flex-direction:column;align-items:flex-end;gap:8px}
.bt-ubody{max-width:100%;box-sizing:border-box;background:var(--bt-user);color:var(--bt-user-ink);border-radius:18px;padding:7px 12px;font-size:var(--dsh-content-font-size,14px);line-height:calc(var(--dsh-content-font-size,14px) + 10px);white-space:pre-wrap;word-break:break-word;text-wrap:pretty;text-autospace:normal}
.bt-ubody a{color:inherit}
.bt-umention{display:inline-flex;align-items:center;gap:3px;vertical-align:-3px;max-width:100%;padding:0 1px;border:0;background:none;color:inherit;font:inherit;font-weight:600;line-height:inherit;cursor:pointer;border-radius:6px;white-space:nowrap}
.bt-umention:hover{text-decoration:underline;text-underline-offset:2px}
.bt-umention>:first-child{flex:none}
.bt-uattach{display:flex;flex-wrap:wrap;justify-content:flex-end;gap:8px;max-width:100%}
.bt-ufile{display:inline-flex;align-items:center;gap:10px;box-sizing:border-box;width:240px;min-height:64px;padding:8px 12px;border-radius:18px;border:.5px solid var(--bt-line-2);background:var(--bt-card)}
.bt-ufile-icon{flex:none;width:28px;height:28px}
.bt-ufile-text{display:flex;flex-direction:column;min-width:0}
.bt-ufile-name{font-size:14px;line-height:22px;font-weight:500;color:var(--bt-ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bt-ufile-meta{font-size:12px;line-height:15px;color:var(--bt-ink-3);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bt-urefs{font-size:13px;line-height:18px;color:var(--bt-ink-3)}
.bt-uvia{display:inline-block;margin-right:6px;padding:0 6px;border-radius:6px;background:var(--bt-hover);color:var(--bt-ink-3);font-size:11px;line-height:16px;vertical-align:1px}
.bt-utools{display:flex;flex:none;gap:2px;opacity:0;visibility:hidden;transition:opacity .12s ease,visibility .12s}
.bt-umsg:hover .bt-utools,.bt-umsg:focus-within .bt-utools,.bt-umsg:has(.bt-recall-note) .bt-utools{opacity:1;visibility:visible}
.bt-recall-note{display:flex;flex-direction:column;align-items:flex-end;gap:6px;max-width:min(100%,440px);box-sizing:border-box;padding:10px 12px;border-radius:16px;border:.5px solid var(--bt-line-2);background:var(--bt-card);font-size:13px;line-height:19px;color:var(--bt-ink);text-align:right}
.bt-recall-note[data-error]{color:var(--bt-danger)}
.bt-recall-files{font-size:12px;line-height:17px;color:var(--bt-ink-3);overflow-wrap:anywhere}
.bt-recall-actions{display:flex;gap:6px}
.bt-recall-go{color:var(--bt-danger)}
.bt-udsh{display:contents}
.bt-udsh-note{display:flex;justify-content:flex-end;margin-top:8px}
`
