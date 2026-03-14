export function interpolateCWTemplate (template, variables = {}) {
  if (!template) return ''

  return template.replace(/\$([A-Za-z_][A-Za-z0-9_]*)/g, (_match, name) => {
    const value = variables[name]
    return value === undefined || value === null ? '' : String(value).toUpperCase()
  })
}
