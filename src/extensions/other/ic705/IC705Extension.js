/*
 * IC-705 Rig Control Extension for PoloRig
 *
 * Registers a settings screen for IC-705 WiFi connection configuration
 * and hooks into the logging panel for CW-on-QRZ-miss behavior.
 */

import { IC705 } from '../../../native/IC705RigControl'
import { traceIC705UI } from './trace'
import { interpolateCWTemplate } from './interpolateCWTemplate'

export const Info = {
  key: 'ic705',
  icon: 'radio-handheld',
  name: 'IC-705 Rig Control',
  description: 'WiFi rig control, CW keying, and frequency display for IC-705'
}

const Extension = {
  ...Info,
  category: 'other',
  alwaysEnabled: true,
  onActivation: ({ registerHook }) => {
    registerHook('setting', {
      hook: {
        ...Info,
        category: 'radio',
        SettingItem: undefined, // Uses default list item from Info
        SettingsScreen: undefined // Navigates to ExtensionScreen
      }
    })

    registerHook('callCommit', { hook: CWCallCommitHook })
  }
}
export default Extension

/**
 * CallCommit hook that sends a CW query when the user commits a callsign
 * (leaves the call field via Space/Tab/Enter) and no lookup found a name.
 *
 * Only fires once per callsign until the field is cleared.
 */
const cwSentCalls = new Set()

const CWCallCommitHook = {
  ...Info,
  key: 'ic705-cw-commit',

  onCallCommit: async ({ call, lookupStatus, settings }) => {
    if (!IC705.isAvailable) return
    if (!settings?.ic705?.autoSendCWOnMiss) return
    if (!call || call.length < 3) return

    // Reset tracking when call is cleared (new QSO)
    if (call.length <= 2) {
      cwSentCalls.clear()
      return
    }

    // Only send if the lookup didn't find a name
    if (lookupStatus?.guess?.name) return

    // Don't send CW for the same callsign twice
    if (cwSentCalls.has(call)) return

    // Check if IC-705 is connected
    try {
      const status = await IC705.getStatus()
      if (!status?.isConnected) return
    } catch {
      return
    }

    // Send CW query using configured template (once only)
    cwSentCalls.add(call)
    const template = settings?.ic705?.cwTemplate || '$callsign?'
    const text = interpolateCWTemplate(template, {
      callsign: call,
      mycall: settings.operatorCall || ''
    })
    traceIC705UI('ui.logging.cw.auto.request', {
      call,
      template,
      text
    })
    try {
      await IC705.sendCW(text)
    } catch (e) {
      traceIC705UI('ui.logging.cw.auto.fail', {
        call,
        text,
        error: e?.message || 'send failed'
      })
      console.warn('IC-705 CW query failed:', e)
      cwSentCalls.delete(call) // Allow retry on failure
    }
  }
}

// Export for use when call field is cleared
export function resetCWSentCalls () {
  cwSentCalls.clear()
}
