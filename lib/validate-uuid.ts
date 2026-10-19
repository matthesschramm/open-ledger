// UUID validation utility
// Used by API routes to validate UUID parameters before querying

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function isValidUUID(value: string): boolean {
  return UUID_REGEX.test(value)
}

export function validateUUID(value: string, paramName: string): { valid: true } | { valid: false; error: { code: string; message: string } } {
  if (!isValidUUID(value)) {
    return {
      valid: false,
      error: {
        code: `invalid_${paramName}`,
        message: `${paramName} must be a UUID, like 3f6c1e2a-b4c7-4d8e-9f1a-2b3c4d5e6f7a`,
      },
    }
  }
  return { valid: true }
}
