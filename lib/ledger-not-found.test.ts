import { describe, it, expect, mock, beforeEach } from 'bun:test'
import { NextRequest } from 'next/server'

// Mock the ledger functions before importing
const mockGetJournal = mock()
const mockGetAccount = mock()
const mockGetInvoice = mock()
const mockGetFixedAsset = mock()
const mockDeleteJournal = mock()
const mockDeleteAccount = mock()

// Mock the validation/auth functions
const mockValidateAPIKey = mock(() => ({
  organizationId: 'test-org-id',
  userId: 'test-user-id',
  canRead: true,
  canWrite: false,
  canPost: false,
  keyId: 'test-key-id',
}))
const mockCheckPermission = mock(() => null)
const mockLogAPIUsage = mock(async () => {})

mock.module('@/lib/ledger', () => ({
  getJournal: mockGetJournal,
  getAccount: mockGetAccount,
  getInvoice: mockGetInvoice,
  getFixedAsset: mockGetFixedAsset,
  deleteJournal: mockDeleteJournal,
  deleteAccount: mockDeleteAccount,
}))

mock.module('@/lib/api-auth', () => ({
  validateAPIKey: mockValidateAPIKey,
  checkPermission: mockCheckPermission,
  errorResponse: (error: any, status: number) => 
    Response.json(error, { status }),
  logAPIUsage: mockLogAPIUsage,
}))

describe('GET-by-id not found error handling', () => {
  beforeEach(() => {
    mockGetJournal.mockReset()
    mockGetAccount.mockReset()
    mockGetInvoice.mockReset()
    mockGetFixedAsset.mockReset()
    mockValidateAPIKey.mockReset()
    mockCheckPermission.mockReset()
    mockLogAPIUsage.mockReset()
    
    // Reset to default behavior
    mockValidateAPIKey.mockImplementation(() => ({
      organizationId: 'test-org-id',
      userId: 'test-user-id',
      canRead: true,
      canWrite: false,
      canPost: false,
      keyId: 'test-key-id',
    }))
    mockCheckPermission.mockImplementation(() => null)
    mockLogAPIUsage.mockImplementation(async () => {})
  })

  it('GET /api/v1/journals/:id returns 404 for missing journal', async () => {
    // Mock getJournal to throw "Journal not found"
    mockGetJournal.mockImplementation(async () => {
      throw new Error('Journal not found')
    })

    const { GET } = await import('@/app/api/v1/journals/[id]/route')
    
    const validUuid = '00000000-0000-0000-0000-000000000000'
    const request = new NextRequest(`http://localhost:3000/api/v1/journals/${validUuid}`, {
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await GET(request, {
      params: Promise.resolve({ id: validUuid }),
    })

    expect(response.status).toBe(404)
    const data = await response.json()
    expect(data.error.code).toBe('not_found')
    expect(data.error.message).toBe('Journal not found')
  })

  it('GET /api/v1/journals/:id returns 500 for database errors', async () => {
    // Mock getJournal to throw a different error (not "Journal not found")
    mockGetJournal.mockImplementation(async () => {
      throw new Error('Database connection failed')
    })

    const { GET } = await import('@/app/api/v1/journals/[id]/route')
    
    const validUuid = '00000000-0000-0000-0000-000000000001'
    const request = new NextRequest(`http://localhost:3000/api/v1/journals/${validUuid}`, {
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await GET(request, {
      params: Promise.resolve({ id: validUuid }),
    })

    expect(response.status).toBe(500)
    const data = await response.json()
    expect(data.error.code).toBe('internal_error')
    expect(data.error.message).toBe('Database error')
  })

  it('GET /api/v1/accounts/:id returns 404 for missing account', async () => {
    mockGetAccount.mockImplementation(async () => {
      throw new Error('Account not found')
    })

    const { GET } = await import('@/app/api/v1/accounts/[id]/route')
    
    const validUuid = '00000000-0000-0000-0000-000000000002'
    const request = new NextRequest(`http://localhost:3000/api/v1/accounts/${validUuid}`, {
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await GET(request, {
      params: Promise.resolve({ id: validUuid }),
    })

    expect(response.status).toBe(404)
    const data = await response.json()
    expect(data.error.code).toBe('not_found')
    expect(data.error.message).toBe('Account not found')
  })

  it('GET /api/v1/accounts/:id returns 500 for database errors', async () => {
    mockGetAccount.mockImplementation(async () => {
      throw new Error('Connection timeout')
    })

    const { GET } = await import('@/app/api/v1/accounts/[id]/route')
    
    const validUuid = '00000000-0000-0000-0000-000000000003'
    const request = new NextRequest(`http://localhost:3000/api/v1/accounts/${validUuid}`, {
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await GET(request, {
      params: Promise.resolve({ id: validUuid }),
    })

    expect(response.status).toBe(500)
    const data = await response.json()
    expect(data.error.code).toBe('internal_error')
    expect(data.error.message).toBe('Database error')
  })

  it('GET /api/v1/invoices/:id returns 404 for missing invoice', async () => {
    mockGetInvoice.mockImplementation(async () => {
      throw new Error('Invoice not found')
    })

    const { GET } = await import('@/app/api/v1/invoices/[id]/route')
    
    const validUuid = '00000000-0000-0000-0000-000000000004'
    const request = new NextRequest(`http://localhost:3000/api/v1/invoices/${validUuid}`, {
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await GET(request, {
      params: Promise.resolve({ id: validUuid }),
    })

    expect(response.status).toBe(404)
    const data = await response.json()
    expect(data.error.code).toBe('not_found')
    expect(data.error.message).toBe('Invoice not found')
  })

  it('GET /api/v1/invoices/:id returns 500 for database errors', async () => {
    mockGetInvoice.mockImplementation(async () => {
      throw new Error('Query execution failed')
    })

    const { GET } = await import('@/app/api/v1/invoices/[id]/route')
    
    const validUuid = '00000000-0000-0000-0000-000000000005'
    const request = new NextRequest(`http://localhost:3000/api/v1/invoices/${validUuid}`, {
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await GET(request, {
      params: Promise.resolve({ id: validUuid }),
    })

    expect(response.status).toBe(500)
    const data = await response.json()
    expect(data.error.code).toBe('internal_error')
    expect(data.error.message).toBe('Database error')
  })

  it('GET /api/v1/fixed-assets/:id returns 404 for missing asset', async () => {
    mockGetFixedAsset.mockImplementation(async () => {
      throw new Error('Fixed asset not found')
    })

    const { GET } = await import('@/app/api/v1/fixed-assets/[id]/route')
    
    const validUuid = '00000000-0000-0000-0000-000000000006'
    const request = new NextRequest(`http://localhost:3000/api/v1/fixed-assets/${validUuid}`, {
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await GET(request, {
      params: Promise.resolve({ id: validUuid }),
    })

    expect(response.status).toBe(404)
    const data = await response.json()
    expect(data.error.code).toBe('not_found')
    expect(data.error.message).toBe('Fixed asset not found')
  })

  it('GET /api/v1/fixed-assets/:id returns 500 for database errors', async () => {
    mockGetFixedAsset.mockImplementation(async () => {
      throw new Error('Unexpected database error')
    })

    const { GET } = await import('@/app/api/v1/fixed-assets/[id]/route')
    
    const validUuid = '00000000-0000-0000-0000-000000000007'
    const request = new NextRequest(`http://localhost:3000/api/v1/fixed-assets/${validUuid}`, {
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await GET(request, {
      params: Promise.resolve({ id: validUuid }),
    })

    expect(response.status).toBe(500)
    const data = await response.json()
    expect(data.error.code).toBe('internal_error')
    expect(data.error.message).toBe('Database error')
  })
})

describe('UUID validation', () => {
  beforeEach(() => {
    mockValidateAPIKey.mockReset()
    mockCheckPermission.mockReset()
    mockLogAPIUsage.mockReset()
    
    mockValidateAPIKey.mockImplementation(() => ({
      organizationId: 'test-org-id',
      userId: 'test-user-id',
      canRead: true,
      canWrite: true,
      canPost: false,
      keyId: 'test-key-id',
    }))
    mockCheckPermission.mockImplementation(() => null)
    mockLogAPIUsage.mockImplementation(async () => {})
  })

  it('GET /api/v1/journals/not-a-uuid returns 400 invalid_journal_id', async () => {
    const { GET } = await import('@/app/api/v1/journals/[id]/route')
    
    const request = new NextRequest('http://localhost:3000/api/v1/journals/not-a-uuid', {
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await GET(request, {
      params: Promise.resolve({ id: 'not-a-uuid' }),
    })

    expect(response.status).toBe(400)
    const data = await response.json()
    expect(data.error.code).toBe('invalid_journal_id')
    expect(data.error.message).toContain('journal_id must be a UUID')
  })

  it('GET /api/v1/accounts/not-a-uuid returns 400 invalid_account_id', async () => {
    const { GET } = await import('@/app/api/v1/accounts/[id]/route')
    
    const request = new NextRequest('http://localhost:3000/api/v1/accounts/not-a-uuid', {
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await GET(request, {
      params: Promise.resolve({ id: 'not-a-uuid' }),
    })

    expect(response.status).toBe(400)
    const data = await response.json()
    expect(data.error.code).toBe('invalid_account_id')
    expect(data.error.message).toContain('account_id must be a UUID')
  })

  it('GET /api/v1/invoices/not-a-uuid returns 400 invalid_invoice_id', async () => {
    const { GET } = await import('@/app/api/v1/invoices/[id]/route')
    
    const request = new NextRequest('http://localhost:3000/api/v1/invoices/not-a-uuid', {
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await GET(request, {
      params: Promise.resolve({ id: 'not-a-uuid' }),
    })

    expect(response.status).toBe(400)
    const data = await response.json()
    expect(data.error.code).toBe('invalid_invoice_id')
    expect(data.error.message).toContain('invoice_id must be a UUID')
  })

  it('GET /api/v1/fixed-assets/not-a-uuid returns 400 invalid_fixed_asset_id', async () => {
    const { GET } = await import('@/app/api/v1/fixed-assets/[id]/route')
    
    const request = new NextRequest('http://localhost:3000/api/v1/fixed-assets/not-a-uuid', {
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await GET(request, {
      params: Promise.resolve({ id: 'not-a-uuid' }),
    })

    expect(response.status).toBe(400)
    const data = await response.json()
    expect(data.error.code).toBe('invalid_fixed_asset_id')
    expect(data.error.message).toContain('fixed_asset_id must be a UUID')
  })

  it('DELETE /api/v1/journals/not-a-uuid returns 400 invalid_journal_id', async () => {
    const { DELETE } = await import('@/app/api/v1/journals/[id]/route')
    
    const request = new NextRequest('http://localhost:3000/api/v1/journals/not-a-uuid', {
      method: 'DELETE',
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await DELETE(request, {
      params: Promise.resolve({ id: 'not-a-uuid' }),
    })

    expect(response.status).toBe(400)
    const data = await response.json()
    expect(data.error.code).toBe('invalid_journal_id')
    expect(data.error.message).toContain('journal_id must be a UUID')
  })
})

describe('DELETE journal error handling', () => {
  beforeEach(() => {
    mockDeleteJournal.mockReset()
    mockValidateAPIKey.mockReset()
    mockCheckPermission.mockReset()
    mockLogAPIUsage.mockReset()
    
    mockValidateAPIKey.mockImplementation(() => ({
      organizationId: 'test-org-id',
      userId: 'test-user-id',
      canRead: true,
      canWrite: true,
      canPost: false,
      keyId: 'test-key-id',
    }))
    mockCheckPermission.mockImplementation(() => null)
    mockLogAPIUsage.mockImplementation(async () => {})
  })

  it('DELETE /api/v1/journals/:id returns 404 for missing journal', async () => {
    mockDeleteJournal.mockImplementation(async () => {
      throw new Error('Journal not found')
    })

    const { DELETE } = await import('@/app/api/v1/journals/[id]/route')
    
    const validUuid = '00000000-0000-0000-0000-000000000000'
    const request = new NextRequest(`http://localhost:3000/api/v1/journals/${validUuid}`, {
      method: 'DELETE',
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await DELETE(request, {
      params: Promise.resolve({ id: validUuid }),
    })

    expect(response.status).toBe(404)
    const data = await response.json()
    expect(data.error.code).toBe('not_found')
    expect(data.error.message).toBe('Journal not found.')
  })

  it('DELETE /api/v1/journals/:id returns 409 for posted journal', async () => {
    mockDeleteJournal.mockImplementation(async () => {
      throw new Error('Only drafts can be deleted')
    })

    const { DELETE } = await import('@/app/api/v1/journals/[id]/route')
    
    const validUuid = '00000000-0000-0000-0000-000000000001'
    const request = new NextRequest(`http://localhost:3000/api/v1/journals/${validUuid}`, {
      method: 'DELETE',
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await DELETE(request, {
      params: Promise.resolve({ id: validUuid }),
    })

    expect(response.status).toBe(409)
    const data = await response.json()
    expect(data.error.code).toBe('not_draft')
    expect(data.error.message).toBe('Only drafts can be deleted.')
  })

  it('DELETE /api/v1/journals/:id returns 500 for other database errors', async () => {
    mockDeleteJournal.mockImplementation(async () => {
      throw new Error('Unexpected database error')
    })

    const { DELETE } = await import('@/app/api/v1/journals/[id]/route')
    
    const validUuid = '00000000-0000-0000-0000-000000000002'
    const request = new NextRequest(`http://localhost:3000/api/v1/journals/${validUuid}`, {
      method: 'DELETE',
      headers: { authorization: 'Bearer test-key' },
    })
    
    const response = await DELETE(request, {
      params: Promise.resolve({ id: validUuid }),
    })

    expect(response.status).toBe(500)
    const data = await response.json()
    expect(data.error.code).toBe('internal_error')
    expect(data.error.message).toBe('Database error')
  })
})
