import Config from 'react-native-config'

function envString (value, fallback = '') {
  return value === undefined || value === null || value === '' ? fallback : value
}

function envNumber (value, fallback) {
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : fallback
}

function envBoolean (value, fallback) {
  if (value === undefined || value === null || value === '') return fallback
  return ['1', 'true', 'yes', 'on'].includes(String(value).toLowerCase())
}

export const IC705_DEFAULTS = {
  wifiMode: envString(Config.IC705_DEFAULT_WIFI_MODE, 'homeLAN'),
  homeLAN: {
    description: 'Home LAN - IC-705 connected to your home WiFi',
    radioIPAddress: envString(Config.IC705_HOME_IP_ADDRESS),
    username: envString(Config.IC705_HOME_USERNAME),
    password: envString(Config.IC705_HOME_PASSWORD),
    controlPort: envNumber(Config.IC705_CONTROL_PORT, 50001),
    serialPort: envNumber(Config.IC705_SERIAL_PORT, 50002)
  },
  fieldAP: {
    description: 'Field AP - IC-705 as WiFi access point (192.168.59.1)',
    ssid: envString(Config.IC705_FIELD_SSID, 'IC-705'),
    radioIPAddress: envString(Config.IC705_FIELD_IP_ADDRESS, '192.168.59.1'),
    username: envString(Config.IC705_FIELD_USERNAME),
    password: envString(Config.IC705_FIELD_PASSWORD),
    controlPort: envNumber(Config.IC705_CONTROL_PORT, 50001),
    serialPort: envNumber(Config.IC705_SERIAL_PORT, 50002)
  },
  cwTemplate: envString(Config.IC705_CW_TEMPLATE, '$callsign?'),
  autoSendCWOnMiss: envBoolean(Config.IC705_AUTO_SEND_CW_ON_MISS, true),
  sidetoneEnabled: envBoolean(Config.IC705_SIDETONE_ENABLED, true),
  civ: {
    radioAddress: envString(Config.IC705_RADIO_ADDRESS, '0xA4'),
    controllerAddress: envString(Config.IC705_CONTROLLER_ADDRESS, '0xE0')
  }
}

export function withIC705Defaults (ic705 = {}) {
  const homeLAN = {
    ...IC705_DEFAULTS.homeLAN,
    ...ic705.homeLAN
  }
  const fieldAP = {
    ...IC705_DEFAULTS.fieldAP,
    ...ic705.fieldAP
  }

  return {
    ...IC705_DEFAULTS,
    ...ic705,
    homeLAN: {
      ...homeLAN,
      radioIPAddress: envString(homeLAN.radioIPAddress || ic705.homeLAN?.ip, IC705_DEFAULTS.homeLAN.radioIPAddress),
      username: envString(homeLAN.username, IC705_DEFAULTS.homeLAN.username),
      password: envString(homeLAN.password, IC705_DEFAULTS.homeLAN.password)
    },
    fieldAP: {
      ...fieldAP,
      radioIPAddress: envString(fieldAP.radioIPAddress || ic705.fieldAP?.ip, IC705_DEFAULTS.fieldAP.radioIPAddress),
      username: envString(fieldAP.username, IC705_DEFAULTS.fieldAP.username),
      password: envString(fieldAP.password, IC705_DEFAULTS.fieldAP.password)
    },
    civ: {
      ...IC705_DEFAULTS.civ,
      ...ic705.civ
    },
    autoSendCWOnMiss: ic705.autoSendCWOnMiss ?? ic705.autoSendCWOnQRZMiss ?? IC705_DEFAULTS.autoSendCWOnMiss,
    cwTemplate: ic705.cwTemplate ?? IC705_DEFAULTS.cwTemplate,
    sidetoneEnabled: ic705.sidetoneEnabled ?? IC705_DEFAULTS.sidetoneEnabled
  }
}
