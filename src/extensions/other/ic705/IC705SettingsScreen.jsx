/*
 * IC-705 Rig Control Settings Screen
 *
 * Configures WiFi connection (per-mode IP/credentials),
 * CW template, auto-send behavior, and sidetone toggle.
 */

import React, { useCallback, useMemo, useState } from 'react'
import { ScrollView, View, TextInput } from 'react-native'
import { Button, Text } from 'react-native-paper'
import { useDispatch, useSelector } from 'react-redux'
import { useSafeAreaInsets } from 'react-native-safe-area-context'

import { useThemedStyles } from '../../../styles/tools/useThemedStyles'
import { selectSettings, setSettings } from '../../../store/settings'
import ScreenContainer from '../../../screens/components/ScreenContainer'
import { H2kListItem, H2kListSection, H2kListSubheader } from '../../../ui'
import { useIC705 } from '../../../hooks/useIC705'
import { withIC705Defaults } from './defaults'

function prepareStyles (baseStyles) {
  return {
    ...baseStyles,
    input: {
      backgroundColor: baseStyles.theme.colors.background,
      color: baseStyles.theme.colors.onBackground,
      borderWidth: 1,
      borderColor: baseStyles.theme.colors.outline,
      borderRadius: 8,
      padding: baseStyles.oneSpace,
      marginHorizontal: baseStyles.oneSpace * 2,
      marginBottom: baseStyles.halfSpace,
      fontSize: baseStyles.normalFontSize
    },
    statusText: {
      paddingHorizontal: baseStyles.oneSpace * 2,
      paddingVertical: baseStyles.halfSpace,
      fontSize: baseStyles.normalFontSize
    }
  }
}

export default function IC705SettingsScreen ({ navigation, splitView }) {
  const dispatch = useDispatch()
  const styles = useThemedStyles(prepareStyles)
  const safeAreaInsets = useSafeAreaInsets()
  const settings = useSelector(selectSettings)
  const [connectError, setConnectError] = useState('')

  const ic705Settings = useMemo(() => withIC705Defaults(settings?.ic705), [settings?.ic705])
  const wifiMode = ic705Settings.wifiMode || 'homeLAN'
  const modeConfig = ic705Settings[wifiMode] || {}

  const {
    connectionState, isConnected, isConnecting,
    connectionDetail,
    cwResult,
    radioName, frequency, frequencyDisplay, mode, cwSpeed,
    connect, disconnect, isAvailable
  } = useIC705()

  const updateIC705Setting = useCallback((key, value) => {
    dispatch(setSettings({
      ic705: { ...ic705Settings, [key]: value }
    }))
  }, [dispatch, ic705Settings])

  const updateModeConfig = useCallback((key, value) => {
    dispatch(setSettings({
      ic705: {
        ...ic705Settings,
        [wifiMode]: { ...modeConfig, [key]: value }
      }
    }))
  }, [dispatch, ic705Settings, wifiMode, modeConfig])

  const handleConnect = useCallback(async () => {
    if (isConnected) {
      setConnectError('')
      await disconnect()
    } else {
      const ip = modeConfig.radioIPAddress || modeConfig.ip || ''
      const user = modeConfig.username || ''
      const pass = modeConfig.password || ''
      if (!ip) return
      try {
        setConnectError('')
        await connect(ip, user, pass)
      } catch (e) {
        console.warn('IC-705 connect failed:', e)
        const detail = connectionDetail ? ` - ${connectionDetail}` : ''
        setConnectError(`${e?.message || 'Connection failed'}${detail}`)
      }
    }
  }, [isConnected, disconnect, connect, modeConfig, wifiMode, connectionDetail])

  if (!isAvailable) {
    return (
      <ScreenContainer>
        <View style={{ flex: 1, justifyContent: 'center', alignItems: 'center' }}>
          <Text>IC-705 Rig Control is only available on iOS.</Text>
        </View>
      </ScreenContainer>
    )
  }

  return (
    <ScreenContainer>
      <ScrollView style={{ flex: 1, marginLeft: splitView ? 0 : safeAreaInsets.left, marginRight: safeAreaInsets.right }}>

        {/* Connection Status */}
        <H2kListSection>
          <H2kListSubheader>Connection</H2kListSubheader>

          {isConnected && (
            <H2kListItem
              title={radioName || 'IC-705'}
              description={`${frequencyDisplay || '---'} | ${mode || '---'} | ${cwSpeed} WPM`}
              leftIcon="radio-handheld"
              leftIconColor={styles.theme.colors.primary}
            />
          )}

          <View style={{ paddingHorizontal: styles.oneSpace * 2, paddingVertical: styles.halfSpace }}>
            <Button
              mode={isConnected ? 'outlined' : 'contained'}
              onPress={handleConnect}
              loading={isConnecting}
              disabled={isConnecting}
              icon={isConnected ? 'lan-disconnect' : 'lan-connect'}
            >
              {isConnected ? 'Disconnect' : 'Connect'}
            </Button>
          </View>

          <Text style={[styles.statusText, { color: connectError ? styles.theme.colors.error : styles.theme.colors.onSurfaceVariant }]}>
            {connectError || `Status: ${connectionState}${connectionDetail ? ` - ${connectionDetail}` : ''}`}
          </Text>
          {!!cwResult && (
            <Text style={[styles.statusText, { color: cwResult.success ? styles.theme.colors.primary : styles.theme.colors.error }]}>
              {`CW ${cwResult.success ? 'ACK' : 'NAK'} (${cwResult.source}): ${cwResult.text}`}
            </Text>
          )}
        </H2kListSection>

        {/* WiFi Mode */}
        <H2kListSection>
          <H2kListSubheader>WiFi Mode</H2kListSubheader>

          <H2kListItem
            title="Home LAN"
            description="IC-705 connected to your home WiFi"
            leftIcon="home"
            rightSwitchValue={wifiMode === 'homeLAN'}
            rightSwitchOnValueChange={() => updateIC705Setting('wifiMode', 'homeLAN')}
            onPress={() => updateIC705Setting('wifiMode', 'homeLAN')}
          />
          <H2kListItem
            title="Field AP"
            description="IC-705 as WiFi access point (192.168.59.1)"
            leftIcon="antenna"
            rightSwitchValue={wifiMode === 'fieldAP'}
            rightSwitchOnValueChange={() => updateIC705Setting('wifiMode', 'fieldAP')}
            onPress={() => updateIC705Setting('wifiMode', 'fieldAP')}
          />
        </H2kListSection>

        {/* Connection Settings */}
        <H2kListSection>
          <H2kListSubheader>{wifiMode === 'homeLAN' ? 'Home LAN' : 'Field AP'} Settings</H2kListSubheader>

          <Text style={[styles.statusText, { color: styles.theme.colors.onSurfaceVariant }]}>Radio IP Address</Text>
          <TextInput
            style={styles.input}
            value={modeConfig.radioIPAddress || modeConfig.ip || ''}
            onChangeText={(text) => updateModeConfig('radioIPAddress', text)}
            placeholder={wifiMode === 'fieldAP' ? '192.168.59.1' : '192.168.2.144'}
            placeholderTextColor={styles.theme.colors.outline}
            keyboardType="numeric"
            autoCapitalize="none"
            autoCorrect={false}
          />

          <Text style={[styles.statusText, { color: styles.theme.colors.onSurfaceVariant }]}>Username</Text>
          <TextInput
            style={styles.input}
            value={modeConfig.username || ''}
            onChangeText={(text) => updateModeConfig('username', text)}
            placeholder="kew"
            placeholderTextColor={styles.theme.colors.outline}
            autoCapitalize="none"
            autoCorrect={false}
          />

          <Text style={[styles.statusText, { color: styles.theme.colors.onSurfaceVariant }]}>Password</Text>
          <TextInput
            style={styles.input}
            value={modeConfig.password || ''}
            onChangeText={(text) => updateModeConfig('password', text)}
            placeholder="••••••••"
            placeholderTextColor={styles.theme.colors.outline}
            secureTextEntry={true}
            autoCapitalize="none"
            autoCorrect={false}
          />
        </H2kListSection>

        {/* CW Settings */}
        <H2kListSection>
          <H2kListSubheader>CW Settings</H2kListSubheader>

          <Text style={[styles.statusText, { color: styles.theme.colors.onSurfaceVariant }]}>CW Template (sent on QRZ miss)</Text>
          <TextInput
            style={styles.input}
            value={ic705Settings.cwTemplate || '$callsign?'}
            onChangeText={(text) => updateIC705Setting('cwTemplate', text)}
            placeholder="$callsign?"
            placeholderTextColor={styles.theme.colors.outline}
            autoCapitalize="characters"
            autoCorrect={false}
          />

          <H2kListItem
            title="Auto-send CW on QRZ miss"
            description="Automatically send CW query when callsign lookup fails"
            leftIcon="send"
            rightSwitchValue={ic705Settings.autoSendCWOnMiss ?? true}
            rightSwitchOnValueChange={(value) => updateIC705Setting('autoSendCWOnMiss', value)}
            onPress={() => updateIC705Setting('autoSendCWOnMiss', !(ic705Settings.autoSendCWOnMiss ?? true))}
          />

          <H2kListItem
            title="CW Sidetone"
            description="Local audio feedback during CW transmission"
            leftIcon="volume-high"
            rightSwitchValue={ic705Settings.sidetoneEnabled ?? true}
            rightSwitchOnValueChange={(value) => updateIC705Setting('sidetoneEnabled', value)}
            onPress={() => updateIC705Setting('sidetoneEnabled', !(ic705Settings.sidetoneEnabled ?? true))}
          />
        </H2kListSection>

        <View style={{ height: safeAreaInsets.bottom + styles.oneSpace * 4 }} />
      </ScrollView>
    </ScreenContainer>
  )
}
