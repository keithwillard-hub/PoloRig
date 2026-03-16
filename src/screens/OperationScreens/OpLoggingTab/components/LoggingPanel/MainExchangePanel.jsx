/*
 * Copyright ©️ 2024-2025 Sebastian Delmont <sd@ham2k.com>
 *
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
 * If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import React, { useCallback, useMemo, useRef, useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'

import { Image, Pressable, View, findNodeHandle } from 'react-native'
import { findRef } from '../../../../../tools/refTools'
import { findHooks } from '../../../../../extensions/registry'
import { H2kCallsignInput, H2kGridInput, H2kRSTInput, H2kTextInput } from '../../../../../ui'
import { expandRSTValues } from '../../../../../tools/callsignTools'
import { valueOrFunction } from '../../../../../tools/valueOrFunction'
import { IC705 } from '../../../../../native/IC705RigControl'
import { useIC705 } from '../../../../../hooks/useIC705'
import { Text } from 'react-native-paper'
import { traceIC705UI } from '../../../../../extensions/other/ic705/trace'
import { interpolateCWTemplate } from '../../../../../extensions/other/ic705/interpolateCWTemplate'

export const MainExchangePanel = ({
  qso, qsos, operation, vfo, settings, style, styles, themeColor, disabled,
  onSubmitEditing, handleFieldChange, setQSO, updateQSO, mainFieldRef, focusedRef,
  allowSpacesInCallField, onCallCommitted
}) => {
  const { t } = useTranslation()
  const { cwResult, isConnected, connectionState } = useIC705()
  const [cwSending, setCwSending] = useState(false)

  // Debug logging
  useEffect(() => {
    console.log('[IC705 Debug] connectionState:', connectionState, 'isConnected:', isConnected)
  }, [connectionState, isConnected])

  // We need to pre-allocate a ref for the main field, in case `mainFieldRef` is not provided
  // but since hooks cannot be called conditionally, we just need to create it whether we need it or not
  const alternateCallFieldRef = useRef()

  // the first ref will correspond to the call field
  const ref0 = mainFieldRef || alternateCallFieldRef
  // Add enough refs for whatever fields might get added
  const ref1 = useRef()
  const ref2 = useRef()
  const ref3 = useRef()
  const ref4 = useRef()
  const ref5 = useRef()
  const ref6 = useRef()
  const ref7 = useRef()
  const ref8 = useRef()
  const ref9 = useRef()
  const refs = useMemo(() => ([ref0, ref1, ref2, ref3, ref4, ref5, ref6, ref7, ref8, ref9]), [ref0, ref1, ref2, ref3, ref4, ref5, ref6, ref7, ref8, ref9])

  // Make a copy since `refStack` will be used to distribute refs to each component and it gets modified
  const refStack = [...refs]

  // Switch between fields with the space key
  const spaceHandler = useCallback((event) => {
    const { nativeEvent: { key, target } } = event
    if (key === ' ') {
      const renderedRefs = refs.filter(x => x?.current)
      const pos = renderedRefs.map(r => findNodeHandle(r.current)).indexOf(target)

      if (pos >= 0) {
        const next = (pos + 1) % renderedRefs.length
        setTimeout(() => {
          renderedRefs[next]?.current?.focus()
        }, 100)
      }
    }
  }, [refs])

  const rstLength = useMemo(() => {
    if (qso?.mode === 'CW' || qso?.mode === 'RTTY') return 3
    if (qso?.mode === 'FT8' || qso?.mode === 'FT4') return 3
    return 2
  }, [qso?.mode])

  // For RST fields, switch to the next field after a full signal report is entered
  const handleRSTChange = useCallback((event) => {
    const value = event?.value || event?.nativeEvent?.text

    handleFieldChange && handleFieldChange(event)
    if (settings.jumpAfterRST) {
      if (value.length >= rstLength) {
        spaceHandler && spaceHandler({ nativeEvent: { key: ' ', target: event?.nativeEvent?.target } })
      }
    }
  }, [handleFieldChange, spaceHandler, rstLength, settings])

  const handleRSTBlur = useCallback((event) => {
    const text = event?.value || event?.nativeEvent?.text || ''
    const mode = qso?.mode ?? vfo?.mode ?? 'SSB'
    if (text.trim().length === 1 || text.trim().length === 2) {
      const expanded = expandRSTValues(text, mode, { settings })
      if (expanded !== text) {
        handleFieldChange && handleFieldChange({ ...event, value: expanded, nativeEvent: { ...event?.nativeEvent, text } })
      }
    }

    return true
  }, [handleFieldChange, qso, vfo?.mode, settings])

  const handleCallBlur = useCallback(() => {
    const call = qso?.their?.call?.trim()
    console.log('[IC705] callCommit blur:', call, 'guess:', qso?.their?.guess?.name)
    onCallCommitted && onCallCommitted()
    if (!call || call.length < 3) return
    traceIC705UI('ui.logging.call.commit', {
      call,
      guessedName: qso?.their?.guess?.name ? 'yes' : 'no'
    })

    const callCommitHooks = findHooks('callCommit')
    for (const hook of callCommitHooks) {
      if (hook?.onCallCommit) {
        hook.onCallCommit({
          call,
          lookupStatus: { guess: qso?.their?.guess, lookup: qso?.their?.lookup },
          settings
        })
      }
    }
  }, [qso?.their?.call, qso?.their?.guess, qso?.their?.lookup, settings, onCallCommitted])

  let fields = []
  fields.push(
    <H2kCallsignInput
      key="call"
      innerRef={refStack.shift()}
      themeColor={themeColor}
      style={[styles.input, { minWidth: styles.oneSpace * 10, flex: 10 }]}
      value={qso?.their?.call ?? ''}
      label={t('screens.opLoggingTab.theirCallLabel', 'Their Call')}
      placeholder=""
      onChange={handleFieldChange}
      onSubmitEditing={() => { handleCallBlur(); onSubmitEditing && onSubmitEditing() }}
      onBlur={handleCallBlur}
      fieldId={'theirCall'}
      noSpaces={!allowSpacesInCallField}
      onSpace={spaceHandler}
      focusedRef={focusedRef}
      allowMultiple={true}
      allowStack={true}
      disabled={disabled}
    />
  )

  if (IC705.isAvailable && (qso?.their?.call?.trim()?.length ?? 0) >= 3) {
    const sendCWQuery = async () => {
      if (cwSending) {
        console.log('[IC705] sendCWQuery ignored: already sending')
        return
      }

      const call = qso?.their?.call?.trim()
      if (!call || call.length < 3) return

      if (!isConnected) {
        console.log('[IC705] sendCWQuery warning: not connected, attempting anyway')
      }

      const template = settings?.ic705?.cwTemplate || '$callsign?'
      const text = interpolateCWTemplate(template, {
        callsign: call,
        mycall: settings.operatorCall || ''
      })

      console.log('[IC705] sendCWQuery starting', { call, template, text })
      traceIC705UI('ui.logging.cw.manual.tap', {
        call,
        template,
        text
      })

      setCwSending(true)

      try {
        await IC705.sendCW(text)
        console.log('[IC705] sendCWQuery succeeded')
      } catch (e) {
        console.warn('[IC705] sendCWQuery failed', e)
        traceIC705UI('ui.logging.cw.manual.fail', {
          call,
          text,
          error: e?.message || 'send failed'
        })
      } finally {
        // Keep sending state for a short delay to prevent rapid clicks
        setTimeout(() => {
          setCwSending(false)
        }, 500)
      }
    }

    const keySize = styles.oneSpace * 4
    const cwButtonDisabled = disabled || cwSending

    fields.push(
      <View key="cw-query" style={{ alignItems: 'center', justifyContent: 'center' }}>
        <Pressable
          onPress={sendCWQuery}
          disabled={cwButtonDisabled}
          accessibilityLabel={t('screens.opLoggingTab.sendCW', 'Send CW Query')}
          style={({ pressed }) => ({
            opacity: cwButtonDisabled ? 0.3 : pressed ? 0.5 : 1,
            justifyContent: 'center',
            alignItems: 'center',
            width: keySize,
            height: keySize
          })}
        >
          <Image
            source={require('../../../../../../assets/telegraph-key.png')}
            style={{ width: keySize, height: keySize, borderRadius: 4 }}
            resizeMode="contain"
          />
        </Pressable>
        {(cwSending || cwResult?.text) && (
          <Text style={{
            fontSize: styles.normalFontSize * 0.55,
            color: cwSending ? '#FFC107' : (cwResult?.success ? '#4CAF50' : '#F44336'),
            marginTop: styles.halfSpace / 2
          }}>
            {cwSending ? 'SENDING...' : (cwResult?.success ? 'CW OK' : 'CW FAIL')}
          </Text>
        )}
      </View>
    )
  }

  if (settings.showRSTFields !== false) {
    const rstFieldRefs = [refStack.shift(), refStack.shift()]
    if (settings.switchSentRcvd) rstFieldRefs.reverse()
    const rstFieldProps = {
      themeColor,
      style: [styles?.text?.numbers, { minWidth: styles.oneSpace * 5.7, flex: 1 }],
      onChange: handleRSTChange,
      onBlur: handleRSTBlur,
      onSubmitEditing,
      onSpace: spaceHandler,
      focusedRef,
      radioMode: qso?.mode ?? vfo?.mode ?? 'SSB'
    }

    const rstFields = [
      <H2kRSTInput
        {...rstFieldProps}
        key="sent"
        innerRef={rstFieldRefs.shift()}
        value={qso?.our?.sent ?? ''}
        label={t('screens.opLoggingTab.ourSentLabel', 'Sent')}
        fieldId={'ourSent'}
        disabled={disabled}
        settings={settings}
      />,
      <H2kRSTInput
        {...rstFieldProps}
        key="received"
        innerRef={rstFieldRefs.shift()}
        value={qso?.their?.sent || ''}
        label={t('screens.opLoggingTab.theirSentLabel', 'Rcvd')}
        accessibiltyLabel={t('screens.opLoggingTab.theirSentLabel-a11y', 'Received')}
        fieldId={'theirSent'}
        disabled={disabled}
        settings={settings}
      />
    ]
    if (settings.switchSentRcvd) rstFields.reverse()
    fields = fields.concat(rstFields)
  }

  const extraFields = {
    state: false,
    grid: false
  }
  findHooks('activity').filter(activity => activity.standardExchangeFields).forEach(activity => {
    const requestedFields = valueOrFunction(activity.standardExchangeFields, { qso, operation, vfo, settings })
    for (const field of Object.keys(requestedFields)) {
      extraFields[field] = extraFields[field] || requestedFields[field]
    }
  })
  if (settings.showStateField === true || settings.showStateField === false) {
    extraFields.state = settings.showStateField
  }
  if (settings.showGridField === true || settings.showGridField === false) {
    extraFields.grid = settings.showGridField
  }

  findHooks('activity').filter(activity => activity.mainExchangeForOperation && findRef(operation, activity.key)).forEach(activity => {
    fields = fields.concat(
      activity.mainExchangeForOperation(
        { qso, qsos, operation, vfo, settings, styles, themeColor, disabled, onSubmitEditing, setQSO, updateQSO, onSpace: spaceHandler, refStack, focusedRef }
      ) || []
    )
  })
  findHooks('activity').filter(activity => activity.mainExchangeForQSO).forEach(activity => {
    if (activity) {
      fields = fields.concat(
        activity.mainExchangeForQSO(
          { qso, operation, vfo, settings, styles, themeColor, disabled, onSubmitEditing, setQSO, updateQSO, onSpace: spaceHandler, refStack, focusedRef }
        ) || []
      )
    }
  })

  if (extraFields.grid) {
    fields.push(
      <H2kGridInput
        key="grid"
        innerRef={refStack.shift()}
        themeColor={themeColor}
        style={[styles.input, { minWidth: styles.oneSpace * 8.5, flex: 1 }]}
        value={qso?.their?.grid ?? ''}
        label={t('screens.opLoggingTab.gridLabel', 'Grid')}
        placeholder={qso?.their?.guess?.grid ?? ''}
        onChange={handleFieldChange}
        onSubmitEditing={onSubmitEditing}
        fieldId={'grid'}
        onSpace={spaceHandler}
        focusedRef={focusedRef}
        disabled={disabled}
      />
    )
  }

  if (extraFields.state) {
    fields.push(
      <H2kTextInput
        key="state"
        innerRef={refStack.shift()}
        themeColor={themeColor}
        style={[styles.input, { minWidth: styles.oneSpace * 5.7, flex: 1 }]}
        value={qso?.their?.state ?? ''}
        label={t('screens.opLoggingTab.stateLabel', 'State')}
        placeholder={qso?.their?.guess?.state ?? ''}
        uppercase={true}
        noSpaces={true}
        onChange={handleFieldChange}
        onSubmitEditing={onSubmitEditing}
        fieldId={'state'}
        onSpace={spaceHandler}
        keyboard={'dumb'}
        maxLength={5}
        focusedRef={focusedRef}
        disabled={disabled}
      />
    )
  }

  return (
    <View style={styles.mainExchangePanel.container}>
      {fields}
    </View>
  )
}
