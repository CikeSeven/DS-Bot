// Writes the demo team (mobile/src/team/demo-team.ts) and the demo pictures from
// mobile/src/team/demo.ts to assets/demo/team.json, for DSB_DEMO=1 builds.
// Run from mobile_flutter/: node tool/dump_demo_team.mjs
import { readFileSync, writeFileSync } from 'node:fs'
import { demoData } from '../../mobile/src/team/demo-team.ts'

const source = readFileSync(new URL('../../mobile/src/team/demo.ts', import.meta.url), 'utf8')
const images = {}
for (const [, name, data] of source.matchAll(/const (DEMO_IMG_\d) = '([A-Za-z0-9+/=]+)'/g)) {
  images[`demo-img-${name.slice('DEMO_IMG_'.length)}`] = data
}
const data = demoData()
writeFileSync(new URL('../assets/demo/team.json', import.meta.url), JSON.stringify({ ...data, images }) + '\n')
console.log('wrote assets/demo/team.json', { bots: data.state.bots.length, chats: Object.keys(data.chats).length, images: Object.keys(images).length })
