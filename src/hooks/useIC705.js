/*
 * React hook for IC-705 rig control state.
 *
 * Subscribes to native module events and provides current radio state.
 * All state updates are driven by events from the Swift native module.
 */

import { useState, useEffect, useCallback } from 'react'
import { IC705 } from '../native/IC705RigControl'

export function useIC705 () {
  const [connectionState, setConnectionState] = useState('disconnected')
  const [connectionDetail, setConnectionDetail] = useState('')
  const [frequency, setFrequency] = useState(0)
  const [frequencyDisplay, setFrequencyDisplay] = useState('')
  const [mode, setMode] = useState(null)
  const [cwSpeed, setCWSpeed] = useState(0)
  const [isSending, setIsSending] = useState(false)
  const [radioName, setRadioName] = useState('')
  const [cwResult, setCWResult] = useState(null)

  const hydrateStatus = useCallback(async () => {
    if (!IC705.isAvailable) return

    try {
      const status = await IC705.getStatus()
      if (!status) return

      setConnectionState(status.isConnected ? 'connected' : 'disconnected')
      setFrequency(status.frequencyHz || 0)
      setFrequencyDisplay(status.frequencyHz ? `${status.frequencyHz / 1000000}` : '')
      setMode(status.mode || null)
      setCWSpeed(status.cwSpeed || 0)
      setIsSending(!!status.isSending)
      setRadioName(status.radioName || '')
    } catch {}
  }, [])

  useEffect(() => {
    if (!IC705.isAvailable) return

    hydrateStatus()

    const subs = [
      IC705.onConnectionStateChanged(e => {
        setConnectionState(e.state)
        setConnectionDetail(e.detail || '')
        if (e.state === 'connected') {
          hydrateStatus()
        }
      }),
      IC705.onFrequencyChanged(e => {
        setFrequency(e.frequencyHz)
        setFrequencyDisplay(e.display)
      }),
      IC705.onModeChanged(e => setMode(e.mode)),
      IC705.onCWSpeedChanged(e => setCWSpeed(e.wpm)),
      IC705.onSendingStateChanged(e => setIsSending(e.isSending)),
      IC705.onRadioNameChanged(e => setRadioName(e.name)),
      IC705.onCWResult(e => setCWResult(e))
    ].filter(Boolean)

    return () => subs.forEach(s => s.remove())
  }, [hydrateStatus])

  const connect = useCallback(async (host, username, password) => {
    const timeoutMs = 14000
    let timeoutId

    try {
      return await Promise.race([
        IC705.connect(host, username, password),
        new Promise((_, reject) => {
          timeoutId = setTimeout(() => reject(new Error('IC-705 connection timed out')), timeoutMs)
        })
      ])
    } catch (error) {
      try {
        await IC705.disconnect()
      } catch {}
      throw error
    } finally {
      if (timeoutId) clearTimeout(timeoutId)
    }
  }, [])

  const disconnect = useCallback(() => {
    return IC705.disconnect()
  }, [])

  return {
    // State
    connectionState,
    connectionDetail,
    isConnected: connectionState === 'connected',
    isConnecting: connectionState === 'connecting',
    frequency,
    frequencyDisplay,
    mode,
    cwSpeed,
    isSending,
    radioName,
    cwResult,

    // Actions
    connect,
    disconnect,
    sendCW: IC705.sendCW,
    sendTemplatedCW: IC705.sendTemplatedCW,
    setCWSpeed: IC705.setCWSpeed,
    cancelCW: IC705.cancelCW,
    getStatus: IC705.getStatus,
    refreshStatus: IC705.refreshStatus,

    // Availability
    isAvailable: IC705.isAvailable
  }
}
