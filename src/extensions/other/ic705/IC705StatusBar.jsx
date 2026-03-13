/*
 * IC-705 Status Bar — compact radio status display for the logging panel.
 *
 * Shows: connection indicator, frequency, mode, CW speed, sending indicator.
 * Only renders when IC-705 native module is available.
 */

import React from 'react'
import { View } from 'react-native'
import { Text } from 'react-native-paper'

import { useThemedStyles } from '../../../styles/tools/useThemedStyles'
import { useIC705 } from '../../../hooks/useIC705'

function prepareStyles (baseStyles) {
  return {
    ...baseStyles,
    container: {
      flexDirection: 'row',
      alignItems: 'center',
      paddingHorizontal: baseStyles.oneSpace,
      paddingVertical: baseStyles.halfSpace / 2,
      gap: baseStyles.oneSpace
    },
    dot: {
      width: 8,
      height: 8,
      borderRadius: 4
    },
    freqText: {
      fontFamily: 'Roboto Mono',
      fontSize: baseStyles.normalFontSize * 0.85,
      fontWeight: '600'
    },
    modeText: {
      fontSize: baseStyles.normalFontSize * 0.8,
      fontWeight: '500'
    },
    speedText: {
      fontSize: baseStyles.normalFontSize * 0.75,
      opacity: 0.7
    },
    sendingText: {
      fontSize: baseStyles.normalFontSize * 0.75,
      fontWeight: '700'
    },
    cwResultText: {
      fontSize: baseStyles.normalFontSize * 0.72,
      fontWeight: '600'
    }
  }
}

export default function IC705StatusBar () {
  const styles = useThemedStyles(prepareStyles)
  const { isConnected, frequencyDisplay, mode, cwSpeed, isSending, cwResult, isAvailable } = useIC705()

  if (!isAvailable) return null
  if (!isConnected) return null

  return (
    <View style={styles.container}>
      {/* Connection indicator */}
      <View style={[
        styles.dot,
        { backgroundColor: isConnected ? '#4CAF50' : '#9E9E9E' }
      ]} />

      {/* Frequency */}
      <Text style={[styles.freqText, { color: styles.theme.colors.onSurface }]}>
        {frequencyDisplay || '---'}
      </Text>

      {/* Mode */}
      {mode && (
        <Text style={[styles.modeText, { color: styles.theme.colors.primary }]}>
          {mode}
        </Text>
      )}

      {/* CW Speed */}
      {cwSpeed > 0 && (
        <Text style={[styles.speedText, { color: styles.theme.colors.onSurfaceVariant }]}>
          {cwSpeed}wpm
        </Text>
      )}

      {/* Sending indicator */}
      {isSending && (
        <Text style={[styles.sendingText, { color: '#FF9800' }]}>
          TX
        </Text>
      )}

      {cwResult?.text && (
        <Text style={[styles.cwResultText, { color: cwResult.success ? '#4CAF50' : '#F44336' }]}>
          {cwResult.success ? `CW OK: ${cwResult.text}` : `CW FAIL: ${cwResult.text}`}
        </Text>
      )}
    </View>
  )
}
