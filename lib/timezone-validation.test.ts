import { describe, it, expect } from 'bun:test'
import { isValidTimeZone } from './timezone-validation'

describe('isValidTimeZone', () => {
  it('returns false for invalid timezone Mars/Olympus', () => {
    expect(isValidTimeZone('Mars/Olympus')).toBe(false)
  })

  it('returns true for valid timezone Pacific/Honolulu', () => {
    expect(isValidTimeZone('Pacific/Honolulu')).toBe(true)
  })

  it('returns true for UTC', () => {
    expect(isValidTimeZone('UTC')).toBe(true)
  })

  it('returns false for empty string', () => {
    expect(isValidTimeZone('')).toBe(false)
  })

  it('returns false for whitespace-only string', () => {
    expect(isValidTimeZone('   ')).toBe(false)
  })

  it('handles trimming correctly', () => {
    expect(isValidTimeZone('  Pacific/Honolulu  ')).toBe(true)
  })
})
