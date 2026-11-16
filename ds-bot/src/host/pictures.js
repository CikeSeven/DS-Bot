// Pictures the user sends from the phone or an IM chat, made ready for the model. The
// type comes from the bytes, and an animated GIF goes as a sheet of its frames.
import { gifSheetImage } from './preview.js'

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

export const sheetNote = (shown, total) =>
  `This picture is an animated GIF, shown as ${shown} of its ${total} frames in order: left to right, then top to bottom.`

/**
 * The message parts for one picture in base64 `data`: an image of the type its bytes
 * have (the declared `mediaType` only when the bytes do not tell), or for an animated
 * GIF a note and one picture of its frames. A GIF that cannot be made into frames
 * goes as it is, and DSH keeps its first frame.
 */
export async function pictureParts({ mediaType, data }) {
  const bytes = Buffer.from(data, 'base64')
  const type = imageTypeOf(bytes) ?? mediaType
  if (type === 'image/gif') {
    const sheet = await gifSheetImage(bytes).catch(() => null)
    if (sheet !== null) {
      return [
        { type: 'text', text: sheetNote(sheet.shown, sheet.total) },
        { type: 'image', mediaType: 'image/jpeg', data: sheet.data.toString('base64') },
      ]
    }
  }
  return [{ type: 'image', mediaType: type, data }]
}
