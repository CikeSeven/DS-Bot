// Builds link.js and link.wasm, the phone link that src/host/phone.js runs, from the Rust
// crates and the JavaScript shell in ../link.
//
//   node scripts/build-link.mjs           rebuilds when the sources changed
//   node scripts/build-link.mjs --check   exits 1 when link.js was built from other sources
//
// Both files are committed, so the plugin installs with no dependencies of its own. The
// second line of link.js is a hash of the sources it was built from; while it matches,
// nothing is built, so `npm run build` and the tests need no Rust. A build needs cargo with
// the wasm32-unknown-unknown target and wasm-bindgen 0.2.130 on the PATH.
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { copyFileSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'

const PLUGIN = dirname(dirname(fileURLToPath(import.meta.url)))
const LINK = join(PLUGIN, '..', 'link')
const OUTPUT = join(PLUGIN, 'link.js')
const WASM = join(PLUGIN, 'link.wasm')
const HEADER = '// Generated from ../link by `npm run build` (scripts/build-link.mjs). Do not edit by hand.'
const HASH_LINE = /^\/\/ source-hash: ([0-9a-f]{64})$/m
const CRATES = ['core', 'host', 'client', 'relay', 'wasm']
// Compiled only into the phone's runtime, the Relay Server's binary or tests, never into link.wasm.
const NOT_IN_WASM = /^crates\/(client\/src\/runtime|relay\/src\/(server|main)\.rs)|\/tests?(\.rs|\/)/

const filesIn = dir => readdirSync(dir, { recursive: true, withFileTypes: true })
  .filter(entry => entry.isFile())
  .map(entry => join(entry.parentPath, entry.name))

/** The files link.js and link.wasm are built from, relative to ../link, sorted. */
export function sourceFiles() {
  const files = ['Cargo.lock', 'Cargo.toml', join('.cargo', 'config.toml')].map(name => join(LINK, name))
  for (const crate of CRATES) files.push(join(LINK, 'crates', crate, 'Cargo.toml'), ...filesIn(join(LINK, 'crates', crate, 'src')))
  files.push(...filesIn(join(LINK, 'js')))
  return files.map(file => relative(LINK, file).split(sep).join('/')).filter(file => !NOT_IN_WASM.test(file)).sort()
}

/** Line endings do not count, so a Windows checkout hashes the same. */
export function sourceHash() {
  const hash = createHash('sha256')
  for (const file of sourceFiles()) {
    const text = readFileSync(join(LINK, file), 'utf8').replaceAll('\r\n', '\n')
    hash.update(`${file}\0${Buffer.byteLength(text)}\0`).update(text)
  }
  return hash.digest('hex')
}

/** The hash in link.js's header, or undefined. */
export function builtHash() {
  try {
    return HASH_LINE.exec(readFileSync(OUTPUT, 'utf8').slice(0, 512))?.[1]
  } catch {
    return undefined
  }
}

export async function buildLink() {
  const hash = sourceHash()
  // wasm-bindgen reads the target_features section that the profile's `strip = true`
  // removes; it drops the names section itself.
  run('cargo', ['build', '--release', '-p', 'dsbot-link-wasm', '--target', 'wasm32-unknown-unknown', '--config', 'profile.release.strip="debuginfo"'])
  const target = process.env.CARGO_TARGET_DIR ?? join(LINK, 'target')
  const out = mkdtempSync(join(tmpdir(), 'dsbot-link-'))
  try {
    run('wasm-bindgen', [
      '--target', 'web', '--no-typescript', '--remove-name-section', '--remove-producers-section', '--out-dir', out,
      join(target, 'wasm32-unknown-unknown', 'release', 'dsbot_link_wasm.wasm'),
    ])
    const bundle = await bundleShell(join(out, 'dsbot_link_wasm.js'))
    writeFileSync(OUTPUT, `${HEADER}\n// source-hash: ${hash}\n${bundle}`)
    copyFileSync(join(out, 'dsbot_link_wasm_bg.wasm'), WASM)
  } finally {
    rmSync(out, { recursive: true, force: true })
  }
}

function run(command, args) {
  execFileSync(command, args, { cwd: LINK, stdio: 'inherit' })
}

/** ../link/js with the wasm-bindgen glue in place of its `dsbot-link-wasm` import. */
async function bundleShell(glue) {
  const result = await build({
    absWorkingDir: LINK,
    entryPoints: ['js/index.js'],
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node22',
    charset: 'utf8',
    legalComments: 'inline',
    write: false,
    logLevel: 'silent',
    // A namespace of its own keeps the temporary directory's name out of the bundle.
    plugins: [{
      name: 'wasm-glue',
      setup(builder) {
        builder.onResolve({ filter: /^dsbot-link-wasm$/ }, ({ path }) => ({ path, namespace: 'wasm-bindgen' }))
        builder.onLoad({ filter: /.*/, namespace: 'wasm-bindgen' }, () => ({ contents: readFileSync(glue, 'utf8'), loader: 'js' }))
      },
    }],
  })
  if (result.warnings.length > 0) throw new Error(`esbuild warnings:\n${result.warnings.map(warning => warning.text).join('\n')}`)
  return result.outputFiles[0].text
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const built = builtHash()
  const current = sourceHash()
  if (process.argv.includes('--check')) {
    if (built !== current) {
      console.error('link.js is stale: its sources in ../link changed. Run `npm run build` in ds-bot (it needs Rust) and commit link.js and link.wasm.')
      process.exit(1)
    }
  } else if (built !== current || !existsSync(WASM)) {
    await buildLink()
  }
}
