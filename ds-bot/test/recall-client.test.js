import assert from 'node:assert/strict'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { runInNewContext } from 'node:vm'
import { build } from 'esbuild'
import { recallOf, recalledTurns, turnsLeftOut } from '../src/client/text.js'

// The user's bubble needs the DSH platform; only its pure part runs here.
const bundle = await build({
  entryPoints: [fileURLToPath(new URL('../src/client/user-message.js', import.meta.url))],
  bundle: true, format: 'cjs', platform: 'node', write: false,
  external: ['react', 'react-dom', '@deepseek-ai/dsh-client-ui-primitives'],
})
const module = { exports: {} }
runInNewContext(bundle.outputFiles[0].text, {
  module, exports: module.exports,
  require: (name) => {
    const platform = { react: { createContext: initial => ({ value: initial }), useContext: ctx => ctx.value, useMemo: make => make(), useCallback: fn => fn, useSyncExternalStore: (subscribe, getSnapshot) => getSnapshot(), createElement: () => null, Fragment: 'fragment', useState: initial => [initial, () => {}], useEffect: () => {}, useRef: initial => ({ current: initial }), useLayoutEffect: () => {}, useId: () => 'id' }, 'react-dom': {}, '@deepseek-ai/dsh-client-ui-primitives': {} }
    if (!(name in platform)) throw new Error(`no platform module ${name}`)
    return platform[name]
  },
})
const { recallTarget, recallWarning } = module.exports

// Turn 2 opened with the recalled message (seq 10) and the recall reached turn 4; in
// part s2 a message sent mid-turn 7 (seq 40) was recalled, up to turn 8.
const roster = {
  byId: { w: { id: 'w', name: 'Writer', sessionId: 's1' }, s1: { id: 'w', name: 'Writer', sessionId: 's1' }, l: { id: 'l', name: 'Local', sessionId: 'l', engine: 'claude' } },
  roomsById: {},
  exchangeTurns: { s1: [6] },
  recalls: {
    s1: [{ seq: 10, until: 30, turn: 2, opened: true, last: 4 }],
    s2: [{ seq: 40, until: 60, turn: 7, opened: false, last: 8 }],
  },
}

test('a node is placed against the recalls by its anchor seq, else by its turn', () => {
  assert.equal(recallOf(roster, 's1', { anchorSeq: 10 }), 'message')
  assert.equal(recallOf(roster, 's1', { anchorSeq: 10.5 }), 'cut')
  assert.equal(recallOf(roster, 's1', { anchorSeq: 30 }), 'cut')
  assert.equal(recallOf(roster, 's1', { anchorSeq: 31 }), undefined)
  assert.equal(recallOf(roster, 's1', { anchorSeq: 9 }), undefined)
  assert.equal(recallOf(roster, 's1', { data: { seq: 12 } }), 'cut')
  assert.equal(recallOf(roster, 's1', { location: { turn: { turn: 2 } } }), 'cut')
  assert.equal(recallOf(roster, 's1', { data: { turn: 5 } }), undefined)
  // The turn a mid-turn message was sent in keeps what came before it.
  assert.equal(recallOf(roster, 's2', { location: { turn: { turn: 7 } } }), undefined)
  assert.equal(recallOf(roster, 's2', { location: { turn: { turn: 8 } } }), 'cut')
  assert.equal(recallOf(roster, 'other', { anchorSeq: 10 }), undefined)
  assert.equal(recallOf({ recalls: undefined }, 's1', { anchorSeq: 10 }), undefined)
})

test('the turns a recall took away whole leave the lists by turn', () => {
  assert.deepEqual(recalledTurns(roster, 's1'), [2, 3, 4])
  assert.deepEqual(recalledTurns(roster, 's2'), [8])
  assert.deepEqual(turnsLeftOut(roster, 's1'), [6, 2, 3, 4])
  assert.deepEqual(turnsLeftOut({ exchangeTurns: {} }, 's1'), [])
})

test('only the user\'s own message in a Bot\'s current part offers a recall', () => {
  const own = { seq: 3, source: { kind: 'user' } }
  assert.equal(recallTarget(roster, 's1', own)?.id, 'w')
  assert.equal(recallTarget(roster, 's1', { seq: 3, source: { kind: 'bot' } }), undefined)
  assert.equal(recallTarget(roster, 's1', { source: { kind: 'user' } }), undefined)
  assert.equal(recallTarget(roster, 'w-old', own), undefined)
  assert.equal(recallTarget({ ...roster, byId: { ...roster.byId, old: { id: 'w', sessionId: 's1' } } }, 'old', own), undefined)
  assert.equal(recallTarget(roster, 'l', own), undefined)
  assert.equal(recallTarget({ ...roster, roomsById: { s1: {} } }, 's1', own), undefined)
})

test('the warning names the changed files only when there are any', () => {
  assert.equal(recallWarning({ files: [], count: 0, maybe: false }, 'Writer'), '')
  assert.equal(recallWarning({ files: ['a.md'], count: 1, maybe: false }, 'Writer'), 'Writer changed a file after this message. Recalling leaves it as it is.')
  assert.equal(recallWarning({ files: ['a.md'], count: 2, maybe: false }, 'Writer'), 'Writer changed 2 files after this message. Recalling leaves them as they are.')
  assert.equal(recallWarning({ files: [], count: 0, maybe: true }, 'Writer'), 'Writer may have changed files after this message. Recalling leaves them as they are.')
  assert.equal(recallWarning(undefined, 'Writer'), '')
})
