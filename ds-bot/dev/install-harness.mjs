import { spawnSync } from 'node:child_process'
import manifest from './harness/package.json' with { type: 'json' }

const args = process.argv.slice(2)
const cli = '@deepseek-ai/dsh'
const requested = args.findLast(arg => arg.startsWith(cli + '@'))?.slice(cli.length + 1)
const version = requested ?? manifest.dependencies[cli]

// This DSH release reads Cordis service records through impl.fiber. Its
// published ranges also accept the next Cordis prerelease, which moved it.
const companions = version === '0.2.2-alpha.2' ? [
  '@deepseek-ai/cordis@4.0.6-alpha.1',
  '@deepseek-ai/cordis-plugin-group@1.0.6-alpha.1',
  '@deepseek-ai/cordis-plugin-include@1.0.11-alpha.1',
  '@deepseek-ai/cordis-plugin-loader@1.0.7-alpha.1',
  '@deepseek-ai/cordis-plugin-timer@1.1.8-alpha.1',
  '@deepseek-ai/cosmokit@1.8.7-alpha.1',
  '@deepseek-ai/schemastery@3.18.6-alpha.1',
] : []

const result = spawnSync(process.execPath, [process.env.npm_execpath, 'install', '--prefix', 'dev/harness',
  '--legacy-peer-deps=false', '--no-save', '--no-package-lock', '--no-fund', '--no-audit', ...companions, ...args], { stdio: 'inherit' })
if (result.error) throw result.error
process.exitCode = result.status ?? 1
