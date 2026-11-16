import assert from 'node:assert/strict'
import { test } from 'node:test'
import jpeg from 'jpeg-js'
import omggif from 'omggif'
import { gifSheet, pickFrames } from '../src/host/gif-sheet.js'
import { imageTypeOf, pictureParts, sheetNote } from '../src/host/pictures.js'

const PALETTE = [0xffffff, 0xff0000, 0x00ff00, 0x0000ff]

// A size x size GIF with one frame per entry, each frame filled with that palette index.
// `frames` entries are either an index or { fill, x, y, size, disposal, transparent }.
function makeGif(frames, size = 8) {
  const buf = Buffer.alloc(4096 + frames.length * size * size * 2)
  const writer = new omggif.GifWriter(buf, size, size, { palette: PALETTE, loop: 0 })
  for (const entry of frames) {
    const frame = typeof entry === 'number' ? { fill: entry } : entry
    const side = frame.size ?? size
    writer.addFrame(frame.x ?? 0, frame.y ?? 0, side, side, Array.from({ length: side * side }, () => frame.fill), {
      delay: 10,
      ...(frame.disposal === undefined ? {} : { disposal: frame.disposal }),
      ...(frame.transparent === undefined ? {} : { transparent: frame.transparent }),
    })
  }
  return buf.subarray(0, writer.end())
}

const pixelAt = (image, x, y) => {
  const at = (y * image.width + x) * 4
  return [image.data[at], image.data[at + 1], image.data[at + 2]]
}
const near = (actual, expected) => actual.every((value, k) => Math.abs(value - expected[k]) < 40)

test('imageTypeOf reads the type from the bytes', () => {
  assert.equal(imageTypeOf(Buffer.from('89504e470d0a1a0a0000', 'hex')), 'image/png')
  assert.equal(imageTypeOf(Buffer.from('ffd8ffe000104a464946', 'hex')), 'image/jpeg')
  assert.equal(imageTypeOf(Buffer.from('GIF89a\x01\x00', 'latin1')), 'image/gif')
  assert.equal(imageTypeOf(Buffer.from('RIFF\x00\x00\x00\x00WEBPVP8 ', 'latin1')), 'image/webp')
  assert.equal(imageTypeOf(Buffer.from('<html></html>')), undefined)
})

test('pickFrames spreads the frames from the first to the last', () => {
  assert.deepEqual(pickFrames(1), [0])
  assert.deepEqual(pickFrames(3), [0, 1, 2])
  assert.deepEqual(pickFrames(4), [0, 1, 2, 3])
  assert.deepEqual(pickFrames(10), [0, 3, 6, 9])
  assert.deepEqual(pickFrames(100), [0, 33, 66, 99])
})

test('gifSheet lays four frames of an animated GIF out in a 2 x 2 grid', () => {
  const sheet = gifSheet(makeGif([1, 2, 3, 0, 0, 0, 1]))
  assert.equal(sheet.shown, 4)
  assert.equal(sheet.total, 7)
  const image = jpeg.decode(sheet.data, { useTArray: true })
  // Two 8 px cells and a 6 px gap each way.
  assert.equal(image.width, 22)
  assert.equal(image.height, 22)
  // Frames 0, 2, 4, 6: red, blue, white, red.
  assert.ok(near(pixelAt(image, 3, 3), [255, 0, 0]))
  assert.ok(near(pixelAt(image, 17, 3), [0, 0, 255]))
  assert.ok(near(pixelAt(image, 3, 17), [255, 255, 255]))
  assert.ok(near(pixelAt(image, 17, 17), [255, 0, 0]))
})

test('gifSheet shows two frames side by side and keeps a still GIF out', () => {
  const sheet = gifSheet(makeGif([1, 3]))
  assert.equal(sheet.shown, 2)
  const image = jpeg.decode(sheet.data, { useTArray: true })
  assert.equal(image.width, 22)
  assert.equal(image.height, 8)
  assert.equal(gifSheet(makeGif([1])), null)
  assert.equal(gifSheet(Buffer.from('GIF89a broken')), null)
})

test('gifSheet draws each frame over the ones before it, as the GIF disposes them', () => {
  const sheet = gifSheet(makeGif([
    1,
    // A blue corner over the red frame, then put back to red (disposal 3).
    { fill: 3, size: 4, disposal: 3 },
    // A transparent green frame: what shows through is red again.
    { fill: 2, transparent: 2 },
    // A white corner that is cleared afterwards (disposal 2): transparent, shown as white.
    { fill: 0, size: 4, disposal: 2 },
  ]))
  assert.equal(sheet.shown, 4)
  const image = jpeg.decode(sheet.data, { useTArray: true })
  assert.ok(near(pixelAt(image, 1, 1), [255, 0, 0]))
  assert.ok(near(pixelAt(image, 15, 1), [0, 0, 255]))
  assert.ok(near(pixelAt(image, 20, 6), [255, 0, 0]))
  assert.ok(near(pixelAt(image, 1, 15), [255, 0, 0]))
  assert.ok(near(pixelAt(image, 15, 15), [255, 255, 255]))
  assert.ok(near(pixelAt(image, 20, 20), [255, 0, 0]))
})

test('pictureParts trusts the bytes over the declared type and turns an animated GIF into a sheet', async () => {
  const photo = Buffer.from('ffd8ffe000104a464946', 'hex').toString('base64')
  assert.deepEqual(await pictureParts({ mediaType: 'image/gif', data: photo }), [{ type: 'image', mediaType: 'image/jpeg', data: photo }])
  const still = makeGif([2]).toString('base64')
  assert.deepEqual(await pictureParts({ mediaType: 'image/jpeg', data: still }), [{ type: 'image', mediaType: 'image/gif', data: still }])
  const unknown = Buffer.from('not an image').toString('base64')
  assert.deepEqual(await pictureParts({ mediaType: 'image/png', data: unknown }), [{ type: 'image', mediaType: 'image/png', data: unknown }])
  const parts = await pictureParts({ mediaType: 'image/jpeg', data: makeGif([1, 2, 3]).toString('base64') })
  assert.deepEqual(parts[0], { type: 'text', text: sheetNote(3, 3) })
  assert.equal(parts[1].type, 'image')
  assert.equal(parts[1].mediaType, 'image/jpeg')
  assert.equal(imageTypeOf(Buffer.from(parts[1].data, 'base64')), 'image/jpeg')
})
