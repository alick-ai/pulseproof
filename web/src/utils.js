export const PROVIDER_COLORS = {
  vipay: '#18d5ff',
  payflow: '#72f05a',
  quickpay: '#ffb020',
  spacepayments: '#ff5263',
}

export function money(value) {
  return new Intl.NumberFormat('ru-RU', { style: 'currency', currency: 'RUB', maximumFractionDigits: 0 }).format(value)
}

export function compactMoney(value) {
  return new Intl.NumberFormat('ru-RU', { notation: 'compact', maximumFractionDigits: 1 }).format(value)
}

export function shortTime(value) {
  const match = String(value).match(/T(\d{2}:\d{2}:\d{2})/)
  return match ? match[1] : value
}

export function shortHash(value, size = 12) {
  return value ? `${value.slice(0, size)}…` : '—'
}

export function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value))
}

export function uniqueBy(items, key) {
  const seen = new Set()
  return items.filter((item) => {
    const value = key(item)
    if (seen.has(value)) return false
    seen.add(value)
    return true
  })
}
