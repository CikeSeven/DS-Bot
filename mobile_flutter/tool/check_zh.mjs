// Lists interface copy in lib/ that has no Chinese yet: every t('…') key that is
// in neither the shared dictionary (assets/i18n/zh.json) nor lib/ui/app_zh.dart.
// Run from mobile_flutter/: node tool/check_zh.mjs
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'

const zh = JSON.parse(readFileSync('assets/i18n/zh.json', 'utf8'))
const app = readFileSync('lib/ui/app_zh.dart', 'utf8')
const known = new Set([...Object.keys(zh.desktop), ...Object.keys(zh.mobile)])
for (const [, key] of app.matchAll(/^\s*'((?:[^'\\]|\\.)*)':/gm)) known.add(key.replace(/\\'/g, "'"))
for (const [, key] of app.matchAll(/^\s*"((?:[^"\\]|\\.)*)":/gm)) known.add(key.replace(/\\"/g, '"'))

const files = []
const walk = dir => { for (const name of readdirSync(dir)) { const path = join(dir, name); statSync(path).isDirectory() ? walk(path) : path.endsWith('.dart') && files.push(path) } }
walk('lib')
const missing = new Map()
for (const file of files) {
  const source = readFileSync(file, 'utf8')
  for (const [, quote, raw] of source.matchAll(/\bt\(\s*(['"])((?:(?!\1)[^\\]|\\.)*)\1/g)) {
    const key = raw.replace(/\\(['"$\\])/g, '$1')
    if (!known.has(key)) missing.set(key, file)
  }
}
for (const [key, file] of [...missing].sort()) console.log(`${JSON.stringify(key)}  // ${file}`)
console.error(`${missing.size} missing`)
