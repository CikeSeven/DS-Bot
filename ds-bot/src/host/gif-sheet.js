// An animated GIF as one still picture of a few of its frames, for a model that takes
// stills only: DSH keeps a single frame of every GIF, so the motion is lost without it.
// Pure JS, so it runs in the preview worker and needs nothing built.
import omggif from 'omggif'
import jpeg from 'jpeg-js'

export const SHEET_FRAMES = 4
// Long side of one frame in the sheet: a 2 x 2 sheet stays inside what DSH keeps.
const CELL_EDGE = 768
const GAP = 6
const GAP_SHADE = 200
const QUALITY = 85
// Every frame up to the last one shown is decoded; past these the GIF stays as it is.
const MAX_CANVAS_PIXELS = 4096 * 4096
const MAX_DECODED_PIXELS = 300_000_000

/** Frame numbers spread evenly from the first frame to the last. */
export function pickFrames(total, count = SHEET_FRAMES) {
  if (total <= count) return Array.from({ length: total }, (_, index) => index)
  return Array.from({ length: count }, (_, k) => Math.round((k * (total - 1)) / (count - 1)))
}

// The full canvas after each wanted frame, with the GIF's disposal rules applied
// between frames: 2 clears the frame's area, 3 puts back what was there before it.
function composite(reader, wanted) {
  const { width, height } = reader
  const canvas = new Uint8Array(width * height * 4)
  const shots = new Map()
  const last = Math.max(...wanted)
  for (let index = 0; index <= last; index += 1) {
    const frame = reader.frameInfo(index)
    const before = frame.disposal === 3 ? canvas.slice() : undefined
    reader.decodeAndBlitFrameRGBA(index, canvas)
    if (wanted.includes(index)) shots.set(index, canvas.slice())
    if (frame.disposal === 2) {
      for (let y = frame.y; y < Math.min(height, frame.y + frame.height); y += 1) {
        canvas.fill(0, (y * width + frame.x) * 4, (y * width + Math.min(width, frame.x + frame.width)) * 4)
      }
    } else if (before !== undefined) {
      canvas.set(before)
    }
  }
  return wanted.map(index => shots.get(index))
}

// Area average of one RGBA frame into a w x h cell of the sheet, over white where it
// is transparent.
function drawCell(sheet, sheetWidth, left, top, frame, width, height, w, h) {
  const sums = new Float64Array(w * h * 3)
  const counts = new Uint32Array(w * h)
  for (let y = 0; y < height; y += 1) {
    const row = Math.min(h - 1, Math.floor((y * h) / height)) * w
    for (let x = 0; x < width; x += 1) {
      const at = (y * width + x) * 4
      const cell = row + Math.min(w - 1, Math.floor((x * w) / width))
      const alpha = frame[at + 3] / 255
      const white = 255 * (1 - alpha)
      sums[cell * 3] += frame[at] * alpha + white
      sums[cell * 3 + 1] += frame[at + 1] * alpha + white
      sums[cell * 3 + 2] += frame[at + 2] * alpha + white
      counts[cell] += 1
    }
  }
  for (let y = 0; y < h; y += 1) {
    for (let x = 0; x < w; x += 1) {
      const cell = y * w + x
      const count = counts[cell] || 1
      const at = ((top + y) * sheetWidth + left + x) * 4
      sheet[at] = sums[cell * 3] / count
      sheet[at + 1] = sums[cell * 3 + 1] / count
      sheet[at + 2] = sums[cell * 3 + 2] / count
    }
  }
}

/**
 * A JPEG of up to SHEET_FRAMES frames of an animated GIF in a grid, read left to right
 * and then top to bottom, with how many frames it shows of how many. Null for a still
 * GIF, one that does not decode, or one too large to decode here.
 */
export function gifSheet(bytes) {
  let reader
  try {
    reader = new omggif.GifReader(bytes)
  } catch {
    return null
  }
  const { width, height } = reader
  const total = reader.numFrames()
  if (total < 2 || width * height > MAX_CANVAS_PIXELS || total * width * height > MAX_DECODED_PIXELS) return null
  const wanted = pickFrames(total)
  let frames
  try {
    frames = composite(reader, wanted)
  } catch {
    return null
  }
  const scale = Math.min(1, CELL_EDGE / Math.max(width, height))
  const w = Math.max(1, Math.round(width * scale))
  const h = Math.max(1, Math.round(height * scale))
  const columns = Math.ceil(Math.sqrt(frames.length))
  const rows = Math.ceil(frames.length / columns)
  const sheetWidth = columns * w + (columns - 1) * GAP
  const sheetHeight = rows * h + (rows - 1) * GAP
  const sheet = Buffer.alloc(sheetWidth * sheetHeight * 4, GAP_SHADE)
  frames.forEach((frame, k) => {
    drawCell(sheet, sheetWidth, (k % columns) * (w + GAP), Math.floor(k / columns) * (h + GAP), frame, width, height, w, h)
  })
  for (let at = 3; at < sheet.length; at += 4) sheet[at] = 255
  return { data: jpeg.encode({ data: sheet, width: sheetWidth, height: sheetHeight }, QUALITY).data, shown: frames.length, total }
}
