import Config from 'react-native-config'

function envString (value, fallback = '') {
  return value === undefined || value === null || value === '' ? fallback : value
}

function envBoolean (value, fallback = false) {
  if (value === undefined || value === null || value === '') return fallback
  return ['1', 'true', 'yes', 'on'].includes(String(value).toLowerCase())
}

export const DEVELOPMENT_DEFAULTS = {
  operatorCall: envString(Config.DEV_DEFAULT_OPERATOR_CALL),
  qrz: {
    login: envString(Config.DEV_DEFAULT_QRZ_LOGIN),
    password: envString(Config.DEV_DEFAULT_QRZ_PASSWORD)
  },
  operationGrid: envString(Config.DEV_DEFAULT_OPERATION_GRID),
  skipOnboarding: envBoolean(Config.DEV_SKIP_ONBOARDING, false)
}

export function withDevelopmentSettingsDefaults (settings = {}) {
  const merged = { ...settings }

  if (!merged.operatorCall && DEVELOPMENT_DEFAULTS.operatorCall) {
    merged.operatorCall = DEVELOPMENT_DEFAULTS.operatorCall
  }

  if (DEVELOPMENT_DEFAULTS.qrz.login || DEVELOPMENT_DEFAULTS.qrz.password) {
    merged.accounts = {
      ...(merged.accounts || {}),
      qrz: {
        ...(merged.accounts?.qrz || {}),
        login: merged.accounts?.qrz?.login || DEVELOPMENT_DEFAULTS.qrz.login,
        password: merged.accounts?.qrz?.password || DEVELOPMENT_DEFAULTS.qrz.password
      }
    }
  }

  return merged
}
