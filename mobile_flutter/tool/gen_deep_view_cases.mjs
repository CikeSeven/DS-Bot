// Writes input/output pairs from deep-view/core so the Dart port can be checked
// against it. Pass the deep-view package folder, or install ds-bot's dependencies:
//   node tool/gen_deep_view_cases.mjs [path/to/deep-view]
import { writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

const root = process.argv[2] ?? new URL('../../ds-bot/node_modules/deep-view', import.meta.url).pathname
const core = await import(pathToFileURL(`${root}/src/core/index.js`).href)

const inputs = { price: 12.5, qty: 3, rate: 0.075, name: 'Ada', on: true, off: false, zero: 0, neg: -2.5, big: 1234567.891, text: '42', blank: '' }
const formulas = [
  'price * qty', 'price * qty * (1 + rate)', 'round(price * qty * (1 + rate), 2)', 'fixed(price / 3, 4)', 'format(big, 2)', 'format(-big)',
  'percent(rate, 1)', 'percent(0.5)', 'min(price, qty, 7)', 'max(1, 2, 3)', 'abs(neg)', 'floor(neg)', 'ceil(neg)', 'round(neg)', 'round(2.5)', 'round(-0.5)',
  'sqrt(16)', 'pow(2, 10)', 'clamp(price, 0, 10)', '0.1 + 0.2', '1 / 3', '10 % 3', '-7 % 3', '7 % -3', '1 / 0', '-1 / 0', '0 / 0',
  'qty > 2 ? "many" : "few"', 'on && off', 'on || off', '!on', 'zero || "fallback"', 'blank || "empty"', 'name + " has " + qty', '"a" == "a"', 'qty == 3', 'text == 42',
  'text * 2', 'qty >= 3 && price < 20', '-(-qty)', '+text', '1e3 + .5', '2 * (3 + 4) - 5 / 5', 'fixed(1.005, 2)', 'format(999.995, 2)', 'format(0.001, 2)', 'format(-0.001, 2)',
  'round(1234.5678, 3)', 'pow(10, 21)', 'pow(10, -7)', '1e21', '123456789012345680000', 'big * 1000000', 'percent(-0.0001, 2)',
  'unknownName + 1', 'min()', 'nope(1)', 'round(1, 11)', 'round(1, 1.5)', '"unclosed', 'price *', 'name * 2', '(1 + 2', '1 ? 2', 'a.b',
  'price == price', 'true', 'false + 1', 'on + 1', '"x" + on', 'fixed(2)', 'format(1000)', 'percent(1.23456, 3)',
]
const scopeLookup = core.createScope(new Map(Object.entries(inputs)), new Map([['subtotal', core.compileFormula('price * qty').tree], ['loop', core.compileFormula('loop + 1').tree]]))
const cases = formulas.map(source => {
  const compiled = core.compileFormula(source)
  if (compiled.error !== undefined) return { source, error: compiled.error }
  const result = core.evaluate(compiled.tree, scopeLookup)
  return result.error !== undefined
    ? { source, names: compiled.names, evalError: result.error }
    : { source, names: compiled.names, value: result.value, shown: core.show(result.value) }
})
cases.push(...['subtotal * 2', 'loop'].map(source => {
  const compiled = core.compileFormula(source)
  const result = core.evaluate(compiled.tree, scopeLookup)
  return result.error !== undefined ? { source, names: compiled.names, evalError: result.error } : { source, names: compiled.names, value: result.value, shown: core.show(result.value) }
}))

const view = {
  type: 'stack',
  let: { total: 'qty * 2.5', broken: 'missing + 1' },
  children: [
    { type: 'slider', id: 'qty', label: 'Quantity', min: 1, max: 10, value: 2 },
    { type: 'choice', id: 'size', label: 'Size', options: [{ label: 'Small', value: 's' }, { label: 'Large', value: 'l' }] },
    { type: 'toggle', id: 'gift', label: 'Gift wrap' },
    { type: 'options', id: 'pick', options: [{ label: 'A' }, { label: 'B' }, { label: 'C' }], multi: true },
    { type: 'confirm', id: 'ok', confirmLabel: 'Ship it', cancelLabel: 'Hold' },
    { type: 'form', id: 'f', fields: [{ id: 'note', label: 'Note' }, { id: 'ro', label: 'Fixed', readOnly: true, value: 'v' }] },
    { type: 'submit', id: 'go', label: 'Send' },
  ],
}
const answers = [
  ['pick', { selected: ['B', 'A', 'B', 'Z'] }], ['pick', { selected: [] }], ['ok', { confirmed: true }], ['ok', { confirmed: false }], ['ok', {}],
  ['f', { fields: { note: 'hi', ro: 'changed' } }], ['f', { canceled: true }], ['f', { fields: { other: 'x' } }], ['go', { inputs: { qty: 4, size: 'l', gift: true } }],
  ['go', { inputs: { qty: 40 } }], ['go', { inputs: { size: 'm' } }], ['go', { inputs: { nope: 1 } }], ['missing', {}], ['', {}], ['go', 'notobject'],
]
const answerCases = answers.map(([action, values]) => {
  const checked = core.validateViewAnswer(view, action, values)
  return { action, values, checked, text: checked.error === undefined ? core.viewAnswerText(view, { action, values: checked }) : null }
})
const scope = core.viewScope(view, { qty: 5 })
const resolved = ['total', 'qty', 'size', 'gift', 'broken'].map(name => { try { return { name, value: scope(name) } } catch (error) { return { name, error: error.message } } })

writeFileSync(new URL('../test/fixtures/deep_view_cases.json', import.meta.url), JSON.stringify({ inputs, cases, view, answerCases, resolved }, null, 1) + '\n')
console.log('wrote test/fixtures/deep_view_cases.json', { formulas: cases.length, answers: answerCases.length })
