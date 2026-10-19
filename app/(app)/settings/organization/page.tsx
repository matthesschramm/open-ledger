'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Label } from '@/components/ui/label'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'
import { CompanySwitcher } from '@/components/app/company-switcher'
import { TimezoneEditor } from './timezone-editor'

type Company = {
  organization_id: string
  organization_name: string
  role: string
  is_active: boolean
}

export default function OrganizationSettingsPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [org, setOrg] = useState<any>(null)
  const [role, setRole] = useState<string | null>(null)
  const [companies, setCompanies] = useState<Company[]>([])
  const [name, setName] = useState('')
  const [originalName, setOriginalName] = useState('')
  const [threshold, setThreshold] = useState('1000.00')
  const [originalThreshold, setOriginalThreshold] = useState('1000.00')
  const [legalName, setLegalName] = useState('')
  const [registrationId, setRegistrationId] = useState('')
  const [address, setAddress] = useState('')
  const [email, setEmail] = useState('')
  const [phone, setPhone] = useState('')
  const [paymentDetails, setPaymentDetails] = useState('')
  const [originalPdfFields, setOriginalPdfFields] = useState<any>({})
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [savingThreshold, setSavingThreshold] = useState(false)
  const [savingPdfFields, setSavingPdfFields] = useState(false)

  useEffect(() => {
    loadData()
  }, [])

  async function loadData() {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }

    const { data: orgData } = await supabase
      .from('organizations')
      .select('id, name, currency_code, timezone, fiscal_year_end_month, fiscal_year_end_day, capitalization_threshold_cents, legal_name, registration_id, address, email, phone, payment_details')
      .single()

    const { data: roleData } = await supabase.rpc('current_role')
    
    // Try get_user_companies RPC with error handling
    const { data: companiesData, error: rpcError } = await supabase.rpc('get_user_companies') as { data: Company[] | null, error: any }
    
    let companiesList: Company[] = []
    if (rpcError || !companiesData) {
      console.error('get_user_companies RPC failed in settings, falling back to direct query:', rpcError)
      
      // Fallback: query memberships join organizations directly
      const { data: fallbackData } = await supabase
        .from('memberships')
        .select(`
          organization_id,
          role,
          organizations:organization_id (
            id,
            name
          )
        `)
        .eq('user_id', user.id)
      
      if (fallbackData) {
        // Get active company from user_settings
        const { data: settings } = await supabase
          .from('user_settings')
          .select('active_company_id')
          .eq('user_id', user.id)
          .single()
        
        const activeCompanyId = settings?.active_company_id

        companiesList = fallbackData.map((m: any) => ({
          organization_id: m.organization_id,
          organization_name: m.organizations?.name || 'Unknown Company',
          role: m.role,
          is_active: m.organization_id === activeCompanyId,
        }))
      }
    } else {
      companiesList = companiesData
    }

    if (orgData) {
      setOrg(orgData)
      setName(orgData.name || '')
      setOriginalName(orgData.name || '')
      const thresholdDisplay = ((orgData.capitalization_threshold_cents ?? 100000) / 100).toFixed(2)
      setThreshold(thresholdDisplay)
      setOriginalThreshold(thresholdDisplay)
      
      const pdfFields = {
        legal_name: orgData.legal_name || '',
        registration_id: orgData.registration_id || '',
        address: orgData.address || '',
        email: orgData.email || '',
        phone: orgData.phone || '',
        payment_details: orgData.payment_details || '',
      }
      setLegalName(pdfFields.legal_name)
      setRegistrationId(pdfFields.registration_id)
      setAddress(pdfFields.address)
      setEmail(pdfFields.email)
      setPhone(pdfFields.phone)
      setPaymentDetails(pdfFields.payment_details)
      setOriginalPdfFields(pdfFields)
    }
    setRole(roleData)
    setCompanies(companiesList)
    setLoading(false)
  }

  async function handleSave() {
    const trimmedName = name.trim()
    
    if (!trimmedName) {
      alert('Company name is required')
      return
    }

    setSaving(true)
    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) throw new Error('Not authenticated')

      const { data: orgId } = await supabase.rpc('current_org_id')
      if (!orgId) throw new Error('Company not found')

      const { data: userRole } = await supabase.rpc('current_role')
      if (userRole !== 'owner') throw new Error('Only owners can change the company name')

      const { error } = await supabase
        .from('organizations')
        .update({ name: trimmedName })
        .eq('id', orgId)

      if (error) throw error

      setOriginalName(trimmedName)
      alert('Company name updated successfully')
      router.refresh()
    } catch (error: any) {
      alert(`Error: ${error.message}`)
    } finally {
      setSaving(false)
    }
  }

  async function handleSaveThreshold() {
    const cents = Math.round(parseFloat(threshold) * 100)
    if (!Number.isFinite(cents) || cents < 0) {
      alert('Capitalization threshold must be zero or greater')
      return
    }

    setSavingThreshold(true)
    try {
      const { data: orgId } = await supabase.rpc('current_org_id')
      if (!orgId) throw new Error('Company not found')

      const { data: userRole } = await supabase.rpc('current_role')
      if (userRole !== 'owner') throw new Error('Only owners can change the capitalization threshold')

      const { error } = await supabase
        .from('organizations')
        .update({ capitalization_threshold_cents: cents })
        .eq('id', orgId)

      if (error) throw error
      setOriginalThreshold((cents / 100).toFixed(2))
      setThreshold((cents / 100).toFixed(2))
    } catch (error: any) {
      alert(`Error: ${error.message}`)
    } finally {
      setSavingThreshold(false)
    }
  }

  async function handleSavePdfFields() {
    setSavingPdfFields(true)
    try {
      const { data: orgId } = await supabase.rpc('current_org_id')
      if (!orgId) throw new Error('Company not found')

      const { data: userRole } = await supabase.rpc('current_role')
      if (userRole !== 'owner' && userRole !== 'bookkeeper') {
        throw new Error('Only owners and bookkeepers can update organization details')
      }

      const { error } = await supabase
        .from('organizations')
        .update({
          legal_name: legalName.trim() || null,
          registration_id: registrationId.trim() || null,
          address: address.trim() || null,
          email: email.trim() || null,
          phone: phone.trim() || null,
          payment_details: paymentDetails.trim() || null,
        })
        .eq('id', orgId)

      if (error) throw error

      const newPdfFields = {
        legal_name: legalName.trim(),
        registration_id: registrationId.trim(),
        address: address.trim(),
        email: email.trim(),
        phone: phone.trim(),
        payment_details: paymentDetails.trim(),
      }
      setOriginalPdfFields(newPdfFields)
      alert('Organization details updated successfully')
    } catch (error: any) {
      alert(`Error: ${error.message}`)
    } finally {
      setSavingPdfFields(false)
    }
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
  }

  const isOwner = role === 'owner'
  const isSaveDisabled = !isOwner || saving || name.trim() === originalName

  const companiesList = companies.map((c) => ({
    id: c.organization_id,
    name: c.organization_name,
    role: c.role,
    isActive: c.is_active,
  }))

  const currentCompany = companiesList.find((c) => c.isActive) || companiesList[0] || null

  return (
    <div className="p-8">
      <div className="mb-8">
        <h1 className="text-3xl font-semibold tracking-tight">Company</h1>
        <p className="text-muted-foreground">
          Company identity and settings
        </p>
      </div>

      <div className="max-w-2xl space-y-6">
        <Card>
          <CardHeader>
            <CardTitle>Active Company</CardTitle>
            <CardDescription>
              Switch between companies or create a new one. Each company has separate books.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="max-w-xs">
              <CompanySwitcher companies={companiesList} currentCompany={currentCompany} />
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Company Name</CardTitle>
            <CardDescription>
              The display name for your company. This appears throughout the application.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="name">Company Name</Label>
                <Input
                  id="name"
                  name="name"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  disabled={!isOwner}
                  required
                />
                {!isOwner && (
                  <p className="text-sm text-muted-foreground">
                    Only company owners can change the company name.
                  </p>
                )}
              </div>
              {isOwner && (
                <Button onClick={handleSave} disabled={isSaveDisabled}>
                  {saving ? 'Saving...' : 'Save Changes'}
                </Button>
              )}
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Time zone</CardTitle>
            <CardDescription>
              Changing the time zone never rewrites journal dates or moves journals between periods. It only affects posting time display and what counts as today.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <TimezoneEditor 
              initialTimezone={org?.timezone || 'America/New_York'}
              isOwner={isOwner}
            />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Capitalization threshold</CardTitle>
            <CardDescription>
              Agents must expense purchases below this amount. The default is $1,000.00.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="threshold">Threshold</Label>
                <Input
                  id="threshold"
                  inputMode="decimal"
                  value={threshold}
                  onChange={(e) => setThreshold(e.target.value)}
                  disabled={!isOwner}
                />
              </div>
              {isOwner && (
                <Button
                  onClick={handleSaveThreshold}
                  disabled={savingThreshold || threshold === originalThreshold}
                >
                  {savingThreshold ? 'Saving...' : 'Save threshold'}
                </Button>
              )}
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Invoice Email Sender</CardTitle>
            <CardDescription>
              How invoice and reminder emails are sent from this company. Managed by platform administrators.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="space-y-2">
              <Label>Emails send as</Label>
              <div className="rounded-md border border-neutral-300 bg-neutral-50 px-3 py-2 text-sm text-neutral-700">
                {name || 'Company Name'} &lt;{process.env.RESEND_PLATFORM_FROM || 'invoices@example.com'}&gt;
              </div>
              <p className="text-sm text-muted-foreground">
                Display name uses your company name. Reply-To uses your contact email when set below.
              </p>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Organization Details</CardTitle>
            <CardDescription>
              Information shown on invoice PDFs. Legal name defaults to company name if not set.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="legalName">Legal name</Label>
                <Input
                  id="legalName"
                  value={legalName}
                  onChange={(e) => setLegalName(e.target.value)}
                  placeholder={name || 'Company legal name'}
                  disabled={!isOwner && role !== 'bookkeeper'}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="registrationId">Registration / tax ID</Label>
                <Input
                  id="registrationId"
                  value={registrationId}
                  onChange={(e) => setRegistrationId(e.target.value)}
                  placeholder="Tax ID or registration number"
                  disabled={!isOwner && role !== 'bookkeeper'}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="address">Address</Label>
                <textarea
                  id="address"
                  value={address}
                  onChange={(e) => setAddress(e.target.value)}
                  placeholder="123 Main St&#10;City, State 12345"
                  disabled={!isOwner && role !== 'bookkeeper'}
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm min-h-[80px] disabled:bg-neutral-50 disabled:text-neutral-500"
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="orgEmail">Email</Label>
                <Input
                  id="orgEmail"
                  type="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  placeholder="contact@company.com"
                  disabled={!isOwner && role !== 'bookkeeper'}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="phone">Phone</Label>
                <Input
                  id="phone"
                  value={phone}
                  onChange={(e) => setPhone(e.target.value)}
                  placeholder="+1 555-123-4567"
                  disabled={!isOwner && role !== 'bookkeeper'}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="paymentDetails">Payment details</Label>
                <textarea
                  id="paymentDetails"
                  value={paymentDetails}
                  onChange={(e) => setPaymentDetails(e.target.value)}
                  placeholder="Bank name: Example Bank&#10;Account number: 1234567890&#10;Routing number: 987654321"
                  disabled={!isOwner && role !== 'bookkeeper'}
                  className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm min-h-[100px] disabled:bg-neutral-50 disabled:text-neutral-500"
                />
                <p className="text-sm text-muted-foreground">
                  Shown on invoice PDFs so customers can pay outside Open Ledger.
                </p>
              </div>
              {(isOwner || role === 'bookkeeper') && (
                <Button
                  onClick={handleSavePdfFields}
                  disabled={
                    savingPdfFields ||
                    (legalName.trim() === originalPdfFields.legal_name &&
                      registrationId.trim() === originalPdfFields.registration_id &&
                      address.trim() === originalPdfFields.address &&
                      email.trim() === originalPdfFields.email &&
                      phone.trim() === originalPdfFields.phone &&
                      paymentDetails.trim() === originalPdfFields.payment_details)
                  }
                >
                  {savingPdfFields ? 'Saving...' : 'Save changes'}
                </Button>
              )}
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Company Details</CardTitle>
            <CardDescription>
              Read-only company configuration
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="space-y-4">
              <div className="space-y-2">
                <Label>Currency</Label>
                <Input value={org?.currency_code || 'USD'} disabled />
              </div>
              <div className="space-y-2">
                <Label>Time zone</Label>
                <Input value={org?.timezone || 'America/New_York'} disabled />
              </div>
              <div className="space-y-2">
                <Label>Fiscal Year End</Label>
                <Input
                  value={`${org?.fiscal_year_end_month || 12}/${org?.fiscal_year_end_day || 31}`}
                  disabled
                />
              </div>
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
