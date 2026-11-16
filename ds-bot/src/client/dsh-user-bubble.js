import { createElement as h } from 'react'
import { freePriority } from './surface.js'

// A DSH without the text projection (canDrawUserMessages) draws the user's bubble
// itself. DS Bot still needs a seat on it, for the recall button in its action row:
// its entry borrows the DSH entry's declarations (locale, children) and inject, as the
// header does (header-navigation.js), and draws DSH's own component inside its own.
const NAME = 'conversation.chat.node'

// One wrapper per DSH component, so a refresh that finds the same entry keeps the
// same component and the rows do not remount.
const wrappers = new WeakMap()
const ours = new WeakSet()
function wrapperFor(Original, Wrapper) {
  let component = wrappers.get(Original)
  if (component === undefined) {
    component = props => h(Wrapper, { ...props, Original })
    wrappers.set(Original, component)
    ours.add(component)
  }
  return component
}

// The registration fields that make the slot hand DS Bot's entry the props it hands
// the DSH entry, with DS Bot's own face on top. A child slot has one owner, and the
// DSH entry keeps it: its message-source seat (only the liveshare plugin fills it) stays
// empty in a Bot chat, as DSH's own steering rows leave it.
export function borrowedEntry(source, face) {
  return {
    ...(source.locale === undefined ? {} : { locale: source.locale }),
    inject: (...args) => {
      const borrowed = source.inject?.(...args) ?? {}
      const own = face()
      return { ...(source.children === undefined ? {} : { renderSlotChain: () => null }), ...borrowed, ...own, hooks: { ...borrowed.hooks, ...own.hooks } }
    },
  }
}

// The entry DS Bot's stands in for: the one that wins without it, lowest priority first.
export const sourceEntry = entries => [...entries]
  .filter(entry => !ours.has(entry.component))
  .sort((a, b) => (a.options?.priority ?? 0) - (b.options?.priority ?? 0))[0]

export function installDshUserBubble(slots, face, Wrapper, priority) {
  const offs = ['user', 'steering'].map((key) => {
    let source
    let dispose
    const refresh = () => {
      const entries = slots.entries(NAME).filter(entry => entry.options?.key === key)
      const next = sourceEntry(entries)
      if (dispose && source === next) return
      dispose?.()
      dispose = undefined
      source = next
      if (source === undefined) return
      dispose = slots.register({
        name: NAME,
        key,
        priority: freePriority(entries.filter(entry => !ours.has(entry.component)), { priority, key }),
        ...borrowedEntry(source, face),
      }, wrapperFor(source.component, Wrapper))
    }
    // The DSH entry may register after DS Bot; follow it, and later host reloads.
    const unsubscribe = slots.subscribe(NAME, refresh)
    try { refresh() } catch (error) { unsubscribe(); throw error }
    return () => { unsubscribe(); dispose?.() }
  })
  return () => { for (const off of offs) off() }
}
