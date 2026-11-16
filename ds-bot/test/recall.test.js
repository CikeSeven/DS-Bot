import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { createAssistantMessage, createToolResultMessage, createUserMessage } from '@deepseek-ai/dsh-llm'
import { Session } from '@deepseek-ai/dsh-session'
import { createRuntime } from '../index.js'
import { RECALL_KIND, RECALL_NOTE, recalledAt } from '../src/host/recall.js'
import { fakeContext } from './fake-ctx.js'

// Writer chats in `w2`; `w1` is an earlier part.
const TEAM = {
  version: 1,
  mainBotIds: ['m1'],
  revision: 1,
  bots: {
    m1: { id: 'm1', sessionId: 'm1', name: 'Chief', role: 'Chief of Staff', instructions: '', createdAt: 1 },
    w1: { id: 'w1', sessionId: 'w2', name: 'Writer', role: '', instructions: '', createdAt: 2, segments: [{ sessionId: 'w1', endedAt: 3 }] },
  },
  rooms: {},
  exchanges: [],
  exchangeTurns: {},
  questions: {},
}

// A Session the way the agent loop writes it: each turn a message, then the Bot's steps.
function chat() {
  const session = Session.create('w2')
  let turn = 0
  const said = (text, kind = 'user') => session.append('user/message', createUserMessage({ content: [{ type: 'text', text }], source: { kind } }), { surfaceOp: 'append' }).seq
  const answer = (text, step = 1) => {
    session.append('step/start', { turn, step })
    const seq = session.append('assistant/message', { turn, step, message: createAssistantMessage({ content: [{ type: 'text', text }] }), stream: [] }, { surfaceOp: 'append' }).seq
    session.append('step/end', { turn, step })
    return seq
  }
  const call = (name, step = 1) => {
    session.append('step/start', { turn, step })
    const callSeq = session.append('tool/call', { turn, step, callId: `${name}-${turn}`, name, arguments: '{}' }).seq
    session.append('assistant/message', {
      turn, step,
      message: createAssistantMessage({ content: [{ type: 'tool-call', callId: `${name}-${turn}`, name, arguments: '{}' }] }),
      stream: [],
    }, { surfaceOp: 'append' })
    session.append('tool/result', { turn, step, message: createToolResultMessage({ callId: `${name}-${turn}`, isError: false, content: [{ type: 'text', text: 'done' }] }) }, { surfaceOp: 'append', sourceEventSeqs: [callSeq] })
    session.append('step/end', { turn, step })
    return callSeq
  }
  const open = () => { turn += 1; session.append('turn/start', { turn }) }
  const close = () => session.append('turn/end', { turn, reason: { kind: 'completed' } })
  return { session, said, answer, call, open, close, turn: () => turn }
}

function fakeAgent(session) {
  const agent = {
    id: session.id,
    session,
    status: 'idle',
    cancelled: [],
    inbox: { nextStep: [], nextTurn: [], remove() { return false }, prepend() {} },
    send() {},
    cancel(cause, options) { agent.cancelled.push({ cause, options }); agent.status = 'idle' },
    async whenIdle() {},
    async runMaintenance(task) { return task(new AbortController().signal) },
  }
  return agent
}

async function team(t, session, { services = {} } = {}) {
  const home = mkdtempSync(join(tmpdir(), 'dsb-recall-'))
  writeFileSync(join(home, 'state.json'), JSON.stringify(TEAM))
  const ctx = fakeContext({ services })
  ctx.sessions = { flush: async () => {} }
  const register = ctx.connection.fetch.register
  ctx.connection.fetch.register = (route) => { ctx.route = route; return register(route) }
  const rt = createRuntime(ctx, { home })
  const agent = fakeAgent(session)
  rt.resolveAgent = async id => (id === session.id ? agent : fakeAgent(Session.create(id)))
  t.after(async () => { await ctx.dispose(); rmSync(home, { recursive: true, force: true, maxRetries: 5 }) })
  const call = async (endpoint, payload = {}) => (await ctx.route.fetch(new Request('http://localhost/api/bot', { method: 'POST', body: JSON.stringify({ endpoint, payload }) }))).json()
  return { home, rt, agent, call }
}

const texts = session => session.deriveMessages().map(message => message.content.filter(block => block.type === 'text').map(block => block.text).join(''))

test('a recall takes the message and everything after it out of the Bot\'s context', async (t) => {
  const c = chat()
  c.open(); c.said('first question'); c.answer('first answer'); c.close()
  c.open(); const asked = c.said('second question'); c.answer('second answer'); c.close()
  c.open(); c.said('third question'); c.answer('third answer'); c.close()
  const { call, home, rt } = await team(t, c.session)
  await call('state')
  const result = await call('recall', { botId: 'w1', sessionId: 'w2', seq: asked })
  assert.equal(result.ok, true, JSON.stringify(result))
  assert.equal(result.value.text, 'second question')
  assert.deepEqual(texts(c.session), ['first question', 'first answer', RECALL_NOTE])
  const placeholder = c.session.eventAt(result.value.until)
  assert.equal(placeholder.data.source.kind, RECALL_KIND)
  // The log keeps every event; only the model's view changed.
  assert.equal(c.session.eventAt(asked).data.content[0].text, 'second question')
  const saved = JSON.parse(readFileSync(join(home, 'state.json'), 'utf8')).recalls.w2
  assert.deepEqual(saved.map(({ at, ...entry }) => entry), [{ seq: asked, until: result.value.until, turn: 2, opened: true, last: 3 }])
  assert.equal(rt.recalledAt('w2', asked), 'message')
  assert.equal(rt.recalledAt('w2', asked + 1), 'cut')
  assert.equal(rt.recalledAt('w2', asked - 1), undefined)
})

test('a recall right after another leaves the Bot one note', async (t) => {
  const c = chat()
  c.open(); c.said('first question'); c.answer('first answer'); c.close()
  c.open(); const one = c.said('take this back'); c.answer('ok'); c.close()
  const { call } = await team(t, c.session)
  await call('state')
  assert.equal((await call('recall', { botId: 'w1', sessionId: 'w2', seq: one })).ok, true)
  c.open(); const two = c.said('and this one'); c.answer('fine'); c.close()
  assert.equal((await call('recall', { botId: 'w1', sessionId: 'w2', seq: two })).ok, true)
  assert.deepEqual(texts(c.session), ['first question', 'first answer', RECALL_NOTE])
})

test('the chat shows one line where the recalled message was and nothing after it', async (t) => {
  const c = chat()
  c.open(); c.said('first question'); c.answer('first answer'); c.close()
  c.open(); const asked = c.said('second question'); c.answer('second answer'); c.close()
  const { call, rt } = await team(t, c.session)
  await call('state')
  await call('recall', { botId: 'w1', sessionId: 'w2', seq: asked })
  c.open(); c.said('second question, again'); c.answer('a new answer'); c.close()
  const events = []
  for (let seq = 0; seq < Number(c.session.seq); seq += 1) events.push(c.session.eventAt(seq))
  const items = rt.displayItems('w2', events, undefined, 0)
  assert.deepEqual(items.map(item => [item.kind, item.text]), [
    ['user', 'first question'],
    ['bot', 'first answer'],
    ['recalled', undefined],
    ['user', 'second question, again'],
    ['bot', 'a new answer'],
  ])
})

test('a message sent while the Bot worked keeps the turn before it', async (t) => {
  const c = chat()
  c.open(); c.said('do the task'); c.call('read')
  const steer = c.said('also check the tests')
  c.answer('done, tests too', 2); c.close()
  const { call, home } = await team(t, c.session)
  await call('state')
  const result = await call('recall', { botId: 'w1', sessionId: 'w2', seq: steer })
  assert.equal(result.ok, true, JSON.stringify(result))
  assert.deepEqual(texts(c.session), ['do the task', '', 'done', RECALL_NOTE])
  const [entry] = JSON.parse(readFileSync(join(home, 'state.json'), 'utf8')).recalls.w2
  assert.equal(entry.opened, false)
  assert.equal(entry.turn, 1)
})

test('context put ahead of the message does not keep it from opening its turn', async (t) => {
  const c = chat()
  c.open(); c.said('hello'); c.answer('hi'); c.close()
  c.open(); c.said('Relevant memory: …', 'memory-recall'); const asked = c.said('what next'); c.answer('this'); c.close()
  const { call, home } = await team(t, c.session)
  await call('state')
  await call('recall', { botId: 'w1', sessionId: 'w2', seq: asked })
  const [entry] = JSON.parse(readFileSync(join(home, 'state.json'), 'utf8')).recalls.w2
  assert.equal(entry.opened, true)
})

test('a working Bot is stopped first and its waiting input is kept', async (t) => {
  const c = chat()
  c.open(); const asked = c.said('long job'); c.call('bash')
  const { call, agent } = await team(t, c.session)
  agent.status = 'running'
  await call('state')
  const result = await call('recall', { botId: 'w1', sessionId: 'w2', seq: asked })
  assert.equal(result.ok, true, JSON.stringify(result))
  assert.deepEqual(agent.cancelled.map(entry => entry.options), [{ keepInbox: true }])
})

test('the check lists the files the turns after the message changed', async (t) => {
  const c = chat()
  c.open(); c.said('hello'); c.answer('hi'); c.close()
  c.open(); const asked = c.said('write the report'); c.call('write')
  const summarySeq = c.session.append('workspace/changes', { turn: c.turn() }).seq
  c.close()
  c.open(); c.said('and the notes'); c.call('edit')
  const summaries = new Map([[summarySeq, { turn: 2, files: [{ path: 'report.md', display: 'report.md' }], total: 3 }]])
  const { call } = await team(t, c.session, { services: { workspaceChanges: { summary: (_id, seq) => summaries.get(seq) } } })
  await call('state')
  const checked = await call('recall-check', { botId: 'w1', sessionId: 'w2', seq: asked })
  assert.deepEqual(checked.value, { files: ['report.md'], count: 3, maybe: false })
})

test('the check is empty when nothing after the message wrote a file', async (t) => {
  const c = chat()
  c.open(); const asked = c.said('what time is it'); c.call('read'); c.answer('noon', 2); c.close()
  const { call } = await team(t, c.session)
  await call('state')
  const checked = await call('recall-check', { botId: 'w1', sessionId: 'w2', seq: asked })
  assert.deepEqual(checked.value, { files: [], count: 0, maybe: false })
})

test('a turn that wrote with no summary yet is reported as maybe', async (t) => {
  const c = chat()
  c.open(); const asked = c.said('fix the bug'); c.call('edit')
  const { call } = await team(t, c.session)
  await call('state')
  const checked = await call('recall-check', { botId: 'w1', sessionId: 'w2', seq: asked })
  assert.deepEqual(checked.value, { files: [], count: 0, maybe: true })
})

test('only the user\'s own messages in the current part, still in context, can be recalled', async (t) => {
  const c = chat()
  c.open(); const mail = c.said('a request from Chief', 'bot'); c.answer('on it'); c.close()
  c.open(); const asked = c.said('mine'); const answered = c.answer('ok'); c.close()
  const { call } = await team(t, c.session)
  await call('state')
  assert.equal((await call('recall', { botId: 'w1', sessionId: 'w2', seq: mail })).error.code, 'bot/invalid')
  assert.equal((await call('recall', { botId: 'w1', sessionId: 'w2', seq: answered })).error.code, 'bot/invalid')
  assert.equal((await call('recall', { botId: 'w1', sessionId: 'w1', seq: asked })).error.code, 'bot/stale')
  // A row of an earlier part names a time this part's message at that seq does not have.
  const time = c.session.eventAt(asked).time
  assert.equal((await call('recall', { botId: 'w1', sessionId: 'w2', seq: asked, time: time - 1 })).error.code, 'bot/stale')
  assert.equal((await call('recall', { botId: 'w1', sessionId: 'w2', seq: asked, time })).ok, true)
  assert.equal((await call('recall', { botId: 'w1', sessionId: 'w2', seq: asked })).error.code, 'bot/stale')
})

test('a message condensed out of the context cannot be recalled', async (t) => {
  const c = chat()
  c.open(); const asked = c.said('old'); const answered = c.answer('old answer'); c.close()
  c.session.append('user/message', createUserMessage({ content: [{ type: 'text', text: 'summary' }], source: { kind: 'compact-checkpoint' } }), {
    surfaceOp: { op: 'replace', startSeq: asked, endSeq: answered },
    sourceEventSeqs: [asked, answered],
  })
  const { call } = await team(t, c.session)
  await call('state')
  assert.equal((await call('recall', { botId: 'w1', sessionId: 'w2', seq: asked })).error.code, 'bot/stale')
})

test('recalledAt names the recalled message and the range after it', () => {
  const recalls = [{ seq: 10, until: 20, turn: 2, opened: true, last: 3 }, { seq: 'bad' }]
  assert.equal(recalledAt(recalls, 9), undefined)
  assert.equal(recalledAt(recalls, 10), 'message')
  assert.equal(recalledAt(recalls, 15), 'cut')
  assert.equal(recalledAt(recalls, 20), 'cut')
  assert.equal(recalledAt(recalls, 21), undefined)
  assert.equal(recalledAt(undefined, 10), undefined)
})
