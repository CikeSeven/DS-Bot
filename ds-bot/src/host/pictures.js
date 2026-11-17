// Pictures the user sends from the phone or an IM chat, made ready for the model. The
// type comes from the bytes, and an animated GIF goes as a sheet of its frames, with the
// GIF itself as a file the Bot can open.
import { gifSheetImage } from './preview.js'
import { sentBlocks, sheetNote } from '../shared/sent-gif.js'

export { sheetNote }

const GIF_NAME = 'animated.gif'
// A larger GIF shows as its sheet on the phone: a link message carries about 3 MB.
const GIF_SHOWN_MAX = 2 * 1024 * 1024

const ascii = (bytes, start, end) => Buffer.from(bytes.subarray(start, end)).toString('latin1')

// The real format, from the bytes themselves: an extension, a Content-Type header, or
// the mime in a data URL can all be wrong, and DSH refuses an image whose declared
// type differs from its bytes.
export function imageTypeOf(bytes) {
  if (bytes.length >= 8 && ascii(bytes, 0, 8) === '\x89PNG\r\n\x1a\n') return 'image/png'
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg'
  if (bytes.length >= 6 && /^GIF8[79]a$/.test(ascii(bytes, 0, 6))) return 'image/gif'
  if (bytes.length >= 12 && ascii(bytes, 0, 4) === 'RIFF' && ascii(bytes, 8, 12) === 'WEBP') return 'image/webp'
  return undefined
}

/**
 * The message parts for one picture in base64 `data`: an image of the type its bytes
 * have (the declared `mediaType` only when the bytes do not tell), or for an animated
 * GIF one `{ type: 'gif' }` part that promptParts turns into what DSH takes. A GIF that
 * cannot be made into frames goes as it is, and DSH keeps its first frame.
 */
export async function pictureParts({ mediaType, data }) {
  const bytes = Buffer.from(data, 'base64')
  const type = imageTypeOf(bytes) ?? mediaType
  if (type === 'image/gif') {
    const sheet = await gifSheetImage(bytes).catch(() => null)
    if (sheet !== null) return [{ type: 'gif', bytes, sheet: sheet.data.toString('base64'), shown: sheet.shown, total: sheet.total }]
  }
  return [{ type: 'image', mediaType: type, data }]
}

/**
 * The prompt parts DSH takes for `content`: each animated GIF from pictureParts becomes a
 * note, the sheet of its frames and the GIF itself as a file. `upload(bytes, name)`
 * answers with the stored file's receipt id, or undefined when the file could not be
 * kept; the GIF then goes as its sheet alone.
 */
export async function promptParts(content, upload) {
  const parts = []
  for (const block of content) {
    if (block?.type !== 'gif') {
      parts.push(block)
      continue
    }
    const receiptId = await upload(block.bytes, GIF_NAME)
    parts.push(
      { type: 'text', text: sheetNote(block.shown, block.total, receiptId !== undefined) },
      { type: 'image', mediaType: 'image/jpeg', data: block.sheet },
      ...(receiptId === undefined ? [] : [{ type: 'file', receiptId }]),
    )
  }
  return parts
}

// A user message's blocks as the phone draws them: an animated GIF as the GIF itself, a
// picture, unless it is too large for the link.
export const phoneBlocks = content => sentBlocks(content, (file, sheet) => (file.attachment.bytes <= GIF_SHOWN_MAX
  ? { type: 'image', attachment: { ...file.attachment, mediaType: 'image/gif' } }
  : sheet))
