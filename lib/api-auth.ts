// API key authentication and authorization
import { createServerClient } from '@supabase/ssr'
import { createHash } from 'crypto'

export interface APIKeyAuth {
  keyId: string
  organizationId: string
  userId: string
  canRead: boolean
  canWrite: boolean
  canPost: boolean
}

export interface APIError {
  error: {
    code: string
    message: string
  }
}

/**
 * Hash an API key for storage/lookup
 */
export function hashAPIKey(key: string): string {
  return createHash('sha256').update(key).digest('hex')
}

/**
 * Generate a random API key with sk_live_ prefix
 */
export function generateAPIKey(): string {
  const randomBytes = crypto.getRandomValues(new Uint8Array(24))
  const randomString = Array.from(randomBytes)
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
  return `sk_live_${randomString}`
}

/**
 * Validate API key from Authorization header and return auth info
 */
export async function validateAPIKey(authHeader: string | null): Promise<APIKeyAuth | APIError> {
  try {
    if (!authHeader) {
      return {
        error: {
          code: 'missing_auth',
          message: 'Missing Authorization header',
        },
      }
    }

    // Expected format: "Bearer sk_live_..."
    const parts = authHeader.split(' ')
    if (parts.length !== 2 || parts[0] !== 'Bearer') {
      return {
        error: {
          code: 'invalid_auth',
          message: 'Invalid Authorization header format. Expected: Bearer sk_live_...',
        },
      }
    }

    const apiKey = parts[1]
    if (!apiKey.startsWith('sk_live_')) {
      return {
        error: {
          code: 'invalid_key',
          message: 'Invalid API key format',
        },
      }
    }

    const keyHash = hashAPIKey(apiKey)

    // Check for required environment variables
    if (!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
      console.error('Missing required environment variables for API authentication')
      return {
        error: {
          code: 'server_config_error',
          message: 'API authentication is not properly configured',
        },
      }
    }

    // Create a Supabase client with service role to bypass RLS
    const supabase = createServerClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL,
      process.env.SUPABASE_SERVICE_ROLE_KEY,
      {
        cookies: {
          getAll() { return [] },
          setAll() { },
        },
      }
    )

    // Look up API key
    const { data: keyData, error } = await supabase
      .from('api_keys')
      .select('id, organization_id, created_by, can_read, can_write, can_post, is_active, expires_at')
      .eq('key_hash', keyHash)
      .single()

    if (error || !keyData) {
      return {
        error: {
          code: 'invalid_key',
          message: 'Invalid API key',
        },
      }
    }

    // Check if key is active
    if (!keyData.is_active) {
      return {
        error: {
          code: 'key_revoked',
          message: 'API key has been revoked',
        },
      }
    }

    // Check if key is expired
    if (keyData.expires_at && new Date(keyData.expires_at) < new Date()) {
      return {
        error: {
          code: 'key_expired',
          message: 'API key has expired',
        },
      }
    }

    return {
      keyId: keyData.id,
      organizationId: keyData.organization_id,
      userId: keyData.created_by,
      canRead: keyData.can_read,
      canWrite: keyData.can_write,
      canPost: keyData.can_post,
    }
  } catch (err) {
    console.error('Error in validateAPIKey:', err)
    return {
      error: {
        code: 'auth_error',
        message: 'Failed to validate API key',
      },
    }
  }
}

/**
 * Check if auth has required permission
 */
export function checkPermission(auth: APIKeyAuth, permission: 'read' | 'write' | 'post'): APIError | null {
  switch (permission) {
    case 'read':
      if (!auth.canRead) {
        return {
          error: {
            code: 'permission_denied',
            message: 'API key does not have read permission',
          },
        }
      }
      break
    case 'write':
      if (!auth.canWrite) {
        return {
          error: {
            code: 'permission_denied',
            message: 'API key does not have write permission (read_write)',
          },
        }
      }
      break
    case 'post':
      if (!auth.canPost) {
        return {
          error: {
            code: 'permission_denied',
            message: 'API key does not have post permission (can_post)',
          },
        }
      }
      break
  }
  return null
}

/**
 * Create error response
 */
export function errorResponse(error: APIError, status: number = 400): Response {
  return new Response(JSON.stringify(error), {
    status,
    headers: {
      'Content-Type': 'application/json',
    },
  })
}

/**
 * Log API usage for audit
 */
export async function logAPIUsage(
  auth: APIKeyAuth,
  method: string,
  path: string,
  statusCode: number,
  requestId?: string,
  idempotencyKey?: string
): Promise<void> {
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      cookies: {
        getAll() { return [] },
        setAll() { },
      },
    }
  )

  await supabase.from('api_audit_events').insert({
    organization_id: auth.organizationId,
    api_key_id: auth.keyId,
    method,
    path,
    status_code: statusCode,
    request_id: requestId,
    idempotency_key: idempotencyKey,
  })

  // Update last_used_at timestamp
  await supabase.rpc('update_api_key_last_used', {
    p_api_key_id: auth.keyId,
  })
}

/**
 * Check idempotency key and return cached response if exists
 */
export async function checkIdempotency(
  auth: APIKeyAuth,
  idempotencyKey: string,
  method: string,
  path: string
): Promise<Response | null> {
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      cookies: {
        getAll() { return [] },
        setAll() { },
      },
    }
  )

  const { data } = await supabase
    .from('idempotency_keys')
    .select('response_status, response_body')
    .eq('organization_id', auth.organizationId)
    .eq('idempotency_key', idempotencyKey)
    .eq('request_method', method)
    .eq('request_path', path)
    .gt('expires_at', new Date().toISOString())
    .single()

  if (data) {
    return new Response(JSON.stringify(data.response_body), {
      status: data.response_status,
      headers: {
        'Content-Type': 'application/json',
      },
    })
  }

  return null
}

/**
 * Store idempotency key result
 */
export async function storeIdempotency(
  auth: APIKeyAuth,
  idempotencyKey: string,
  method: string,
  path: string,
  status: number,
  body: any
): Promise<void> {
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      cookies: {
        getAll() { return [] },
        setAll() { },
      },
    }
  )

  await supabase.from('idempotency_keys').insert({
    organization_id: auth.organizationId,
    idempotency_key: idempotencyKey,
    request_method: method,
    request_path: path,
    response_status: status,
    response_body: body,
  })
}
