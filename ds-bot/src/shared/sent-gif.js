// An animated GIF the user sends from the phone or an IM chat reaches the model as a
// note, one picture of a few of its frames and, when DSH could keep it, the GIF itself
// as a file (host/pictures.js). What the user sees of their own message leaves out what
// was written for the model.
const NOTE = /^This picture is an animated GIF, shown as \d+ of its \d+ frames in order: left to right, then top to bottom\.(?: The GIF itself is the file after it\.)?$/

export const sheetNote = (shown, total, file = false) =>
  `This picture is an animated GIF, shown as ${shown} of its ${total} frames in order: left to right, then top to bottom.${file ? ' The GIF itself is the file after it.' : ''}`

const isNote = block => block?.type === 'text' && typeof block.text === 'string' && NOTE.test(block.text.trim())
const isGifFile = block => block?.type === 'file' && /\.gif$/i.test(String(block.attachment?.name ?? ''))

/**
 * A user message's blocks as the user sees them: without the notes, and where the GIF
 * itself follows its sheet of frames, `gif(file, sheet)` in place of the two (the file
 * by default). Content without a note comes back as it is.
 */
export function sentBlocks(content, gif = file => file) {
  const blocks = Array.isArray(content) ? content : []
  if (!blocks.some(isNote)) return blocks
  const shown = []
  for (let at = 0; at < blocks.length; at += 1) {
    const block = blocks[at]
    if (!isNote(block)) shown.push(block)
    else if (blocks[at + 1]?.type === 'image' && isGifFile(blocks[at + 2])) {
      shown.push(gif(blocks[at + 2], blocks[at + 1]))
      at += 2
    }
  }
  return shown
}

// A message's joined text as the user sees it; each note is a block, so a line, of its own.
export const sentText = text => String(text ?? '').split('\n').filter(line => !NOTE.test(line.trim())).join('\n').trim()
