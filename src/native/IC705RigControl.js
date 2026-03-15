/*
 * IC-705 Rig Control — React Native NativeModules wrapper
 *
 * Exposes the Swift IC705RigControl native module to JavaScript
 * with promise-based methods and event subscriptions.
 */

import { NativeEventEmitter, Platform, TurboModuleRegistry } from 'react-native'

const NativeIC705 = Platform.OS === 'ios' ? TurboModuleRegistry.get('IC705RigControl') : null
const emitter = NativeIC705 ? new NativeEventEmitter(NativeIC705) : null

function nativeMethodNames () {
  if (!NativeIC705) return []
  return Object.keys(NativeIC705).filter(key => typeof NativeIC705[key] === 'function').sort()
}

export const IC705 = {
  /** Connect to IC-705 via WiFi. Returns { radioName }. */
  connect: (host, username, password) =>
    NativeIC705?.connect(host, username, password) ?? Promise.reject(new Error('iOS only')),

  /** Disconnect from IC-705. */
  disconnect: () =>
    NativeIC705?.disconnect() ?? Promise.resolve(),

  /** Send raw CW text (max 30 chars per CI-V command). */
  sendCW: (text) => {
    console.log('[IC705] wrapper.sendCW', {
      text,
      hasNative: !!NativeIC705,
      methods: nativeMethodNames()
    })
    if (!NativeIC705?.sendCW) {
      return Promise.reject(new Error('iOS only'))
    }
    return NativeIC705.sendCW(text)
  },

  /**
   * Send templated CW with $variable interpolation + {MACRO} expansion.
   * @param {string} template - e.g. "$callsign DE $mycall K"
   * @param {Object} variables - e.g. { callsign: 'W1AW', mycall: 'AC0VW' }
   */
  sendTemplatedCW: (template, variables) =>
    NativeIC705?.sendTemplatedCW(template, variables) ?? Promise.reject(new Error('iOS only')),

  /** Set CW keying speed in WPM (6-48). */
  setCWSpeed: (wpm) =>
    NativeIC705?.setCWSpeed(wpm) ?? Promise.reject(new Error('iOS only')),

  /** Cancel CW transmission in progress. */
  cancelCW: () =>
    NativeIC705?.cancelCW(),

  /** Get current status. Returns { isConnected, frequencyHz, mode, cwSpeed, isSending, radioName }. */
  getStatus: () =>
    NativeIC705?.getStatus() ?? Promise.resolve({ isConnected: false }),

  /** Refresh status through a direct one-shot radio query. */
  refreshStatus: () =>
    NativeIC705?.refreshStatus() ?? Promise.resolve({ isConnected: false }),

  /** Write a UI trace marker into the native iOS log stream. */
  logUIEvent: (name, detail = '') =>
    typeof NativeIC705?.logUIEvent === 'function'
      ? NativeIC705.logUIEvent(name, detail)
      : Promise.resolve(),

  /** @returns {EmitterSubscription} */
  onConnectionStateChanged: (cb) =>
    emitter?.addListener('onConnectionStateChanged', cb),

  /** @returns {EmitterSubscription} */
  onFrequencyChanged: (cb) =>
    emitter?.addListener('onFrequencyChanged', cb),

  /** @returns {EmitterSubscription} */
  onModeChanged: (cb) =>
    emitter?.addListener('onModeChanged', cb),

  /** @returns {EmitterSubscription} */
  onCWSpeedChanged: (cb) =>
    emitter?.addListener('onCWSpeedChanged', cb),

  /** @returns {EmitterSubscription} */
  onSendingStateChanged: (cb) =>
    emitter?.addListener('onSendingStateChanged', cb),

  /** @returns {EmitterSubscription} */
  onRadioNameChanged: (cb) =>
    emitter?.addListener('onRadioNameChanged', cb),

  /** @returns {EmitterSubscription} */
  onCWResult: (cb) =>
    emitter?.addListener('onCWResult', cb),

  /** Whether the native module is available (iOS only). */
  isAvailable: !!NativeIC705,
  debugNativeMethods: () => nativeMethodNames()
}
