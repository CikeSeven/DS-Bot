// Copies what the phone shares with the desktop UI into JSON assets, so the
// Flutter app follows the same themes, inks, characters and Chinese copy:
//   assets/shared/shared.json  themes, inks, character table, IM platforms
//   assets/i18n/zh.json        desktop DICTIONARY.zh + host error patterns + the phone's own copy (tool/phone_zh.mjs)
//   test/fixtures/character_cases.json  default looks for a set of ids, to check the Dart port
// Run from mobile_flutter/ after the desktop files change: node tool/sync_shared.mjs
import { readFileSync, writeFileSync } from 'node:fs'
import { allThemes } from '../../ds-bot/src/client/themes.js'
import { ACCENT_INKS, GRADIENTS, INKS } from '../../ds-bot/src/client/inks.js'
import {
  CHARACTERS,
  CHARACTER_COLORS,
  DEFAULT_COLORS,
  DEFAULT_SHAPES,
  FALLBACK_SHAPE,
  MAIN_LOOK,
  defaultColor,
  defaultShape,
  fnv1a,
  lookOf,
} from '../../ds-bot/src/client/characters.js'
import { DICTIONARY } from '../../ds-bot/src/client/i18n.js'
import { IM_PLATFORMS } from '../../ds-bot/src/shared/im-platforms.js'
import { MOBILE_SENSE, MOBILE_ZH } from './phone_zh.mjs'

const root = new URL('../', import.meta.url)
const write = (path, value) => writeFileSync(new URL(path, root), JSON.stringify(value) + '\n')

// Object or array literal that follows `const NAME... =` in a source file, evaluated as JS.
function literal(file, name) {
  const source = readFileSync(new URL(file, root), 'utf8')
  const start = source.search(new RegExp(`const ${name}\\b[^=]*=\\s*[\\[{]`))
  if (start === -1) throw new Error(`${name} not found in ${file}`)
  const open = source.indexOf('=', start) + 1
  let depth = 0
  let index = open
  let quote = null
  for (; index < source.length; index += 1) {
    const char = source[index]
    if (quote) {
      if (char === '\\') index += 1
      else if (char === quote) quote = null
      continue
    }
    if (char === "'" || char === '"' || char === '`') quote = char
    else if (char === '/' && source[index + 1] === '^') {
      // A regex literal starting /^ ; skip to its closing slash.
      index += 1
      while (source[index] !== '/' || source[index - 1] === '\\') index += 1
    } else if (char === '[' || char === '{') depth += 1
    else if (char === ']' || char === '}') {
      depth -= 1
      if (depth === 0) break
    }
  }
  return new Function(`return ${source.slice(open, index + 1)}`)()
}

const characters = Object.fromEntries(Object.entries(CHARACTERS).map(([id, character]) => [id, {
  label: character.label ?? id[0].toUpperCase() + id.slice(1),
  body: character.body,
  paints: character.paints ?? [],
  shade: character.shade,
  eyes: character.eyes,
}]))

write('assets/shared/shared.json', {
  themes: Object.fromEntries(Object.entries(allThemes()).map(([id, theme]) => [id, { label: theme.label, light: theme.light, dark: theme.dark }])),
  inks: INKS,
  gradients: GRADIENTS,
  accentInks: ACCENT_INKS,
  characterColors: CHARACTER_COLORS,
  defaultColors: DEFAULT_COLORS,
  defaultShapes: DEFAULT_SHAPES,
  fallbackShape: FALLBACK_SHAPE,
  mainLook: MAIN_LOOK,
  characters,
  imPlatforms: IM_PLATFORMS,
})

const hostErrors = literal('../ds-bot/src/client/i18n.js', 'HOST_ERRORS').map(([pattern, template]) => [pattern.source, template])
write('assets/i18n/zh.json', { desktop: DICTIONARY.zh, mobile: MOBILE_ZH, mobileSense: MOBILE_SENSE, hostErrors })

const ids = ['b-chief', 'b-writer', 'b-coder', 'b-researcher', 'b-designer', 'bot-1', 'x', '', '漢字', 'a'.repeat(40), 'b-3kq9z1', 'r-launch']
write('test/fixtures/character_cases.json', ids.map(id => ({
  id,
  fnv1a: fnv1a(id),
  color: id === '' ? null : defaultColor(id),
  shape: id === '' ? null : defaultShape(id),
  look: lookOf(id === '' ? { avatar: {} } : { id, avatar: id === 'bot-1' ? { shape: 'whale' } : {}, color: id === 'x' ? '#123456' : undefined }),
})))

console.log('synced', {
  themes: Object.keys(allThemes()).length,
  characters: Object.keys(characters).length,
  zh: Object.keys(DICTIONARY.zh).length,
  mobileZh: Object.keys(MOBILE_ZH).length,
  hostErrors: hostErrors.length,
  mobileSense: MOBILE_SENSE,
})
