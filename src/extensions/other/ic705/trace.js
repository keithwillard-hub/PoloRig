import { IC705 } from '../../../native/IC705RigControl'

function compactValue (value) {
  if (value === null || value === undefined) return ''
  return String(value).replace(/\s+/g, ' ').trim().slice(0, 160)
}

export function traceIC705UI (name, fields = {}) {
  if (!IC705.isAvailable || typeof IC705.logUIEvent !== 'function') return

  const detail = Object.entries(fields)
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => `${key}=${compactValue(value)}`)
    .join(' ')

  IC705.logUIEvent(name, detail).catch(() => {})
}
