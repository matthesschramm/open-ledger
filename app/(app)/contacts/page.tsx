'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import Link from 'next/link'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { EmptyState } from '@/components/app/empty-state'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Label } from '@/components/ui/label'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Users, Plus } from 'lucide-react'

export default function ContactsPage() {
  const router = useRouter()
  const supabase = createClient()
  
  const [contacts, setContacts] = useState<any[]>([])
  const [orgId, setOrgId] = useState<string | null>(null)
  const [currentRole, setCurrentRole] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [dialogOpen, setDialogOpen] = useState(false)
  const [saving, setSaving] = useState(false)
  
  const [formData, setFormData] = useState({
    type: 'Vendor' as 'Vendor' | 'Customer' | 'Other' | 'Parent',
    name: '',
    email: '',
    phone: '',
    address: '',
    notes: '',
  })
  const [emailError, setEmailError] = useState('')
  const [saveError, setSaveError] = useState('')

  useEffect(() => {
    loadData()
  }, [])

  async function loadData() {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/login')
      return
    }

    const { data: orgData } = await supabase.rpc('current_org_id')
    const { data: roleData } = await supabase.rpc('current_role')
    setOrgId(orgData)
    setCurrentRole(roleData)

    const { data: contactsData } = await supabase
      .from('contacts')
      .select('*')
      .eq('is_active', true)
      .in('type', ['Vendor', 'Customer', 'Other', 'Parent'])
      .order('name')

    if (contactsData) setContacts(contactsData)
    setLoading(false)
  }

  function validateEmail(email: string): boolean {
    if (!email) return true
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
    return emailRegex.test(email)
  }

  async function handleCreate() {
    setSaveError('')
    
    if (!formData.name.trim()) {
      setSaveError('Name is required')
      return
    }

    if (formData.email && !validateEmail(formData.email)) {
      setEmailError('Please enter a valid email address')
      return
    }

    if (!orgId) {
      setSaveError('Unable to determine your organization. Please refresh the page.')
      return
    }

    setSaving(true)
    try {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) throw new Error('Not authenticated')

      const { data, error } = await supabase
        .from('contacts')
        .insert({
          organization_id: orgId,
          type: formData.type,
          name: formData.name.trim(),
          email: formData.email.trim() || null,
          phone: formData.phone.trim() || null,
          address: formData.address.trim() || null,
          notes: formData.notes.trim() || null,
          is_active: true,
        })
        .select()

      if (error) {
        console.error('Contact creation error:', error)
        throw new Error(
          error.message.includes('permission') || error.message.includes('policy')
            ? 'You do not have permission to add contacts. Please contact your organization owner.'
            : `Failed to create contact: ${error.message}`
        )
      }

      setDialogOpen(false)
      setFormData({
        type: 'Vendor',
        name: '',
        email: '',
        phone: '',
        address: '',
        notes: '',
      })
      setEmailError('')
      setSaveError('')
      await loadData()
    } catch (error: any) {
      console.error('Contact creation failed:', error)
      setSaveError(error.message || 'Failed to create contact. Please try again.')
    } finally {
      setSaving(false)
    }
  }

  if (loading) {
    return <div className="p-8">Loading...</div>
  }

  const canCreate = currentRole && ['owner', 'bookkeeper'].includes(currentRole)

  if (contacts.length === 0) {
    return (
      <>
        <div className="p-8">
          <div className="mb-8 flex items-center justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Contacts</h1>
              <p className="text-muted-foreground">Vendors and other contacts</p>
            </div>
            {canCreate && (
              <Button onClick={() => setDialogOpen(true)}>
                <Plus className="h-4 w-4 mr-2" />
                Add Contact
              </Button>
            )}
          </div>
          <EmptyState
            icon={<Users className="h-8 w-8 text-coral" />}
            title="No contacts yet"
            description="Add customers for invoices, vendors for bills, or add the parent company for intercompany transactions."
            actions={
              canCreate
                ? [
                    {
                      label: 'Add contact',
                      onClick: () => setDialogOpen(true),
                    },
                  ]
                : []
            }
          />
        </div>
        <AddContactDialog
          open={dialogOpen}
          onOpenChange={setDialogOpen}
          formData={formData}
          setFormData={setFormData}
          emailError={emailError}
          setEmailError={setEmailError}
          saveError={saveError}
          setSaveError={setSaveError}
          saving={saving}
          onSave={handleCreate}
        />
      </>
    )
  }

  const customers = contacts.filter(c => c.type === 'Customer')
  const vendors = contacts.filter(c => c.type === 'Vendor')
  const parents = contacts.filter(c => c.type === 'Parent')
  const others = contacts.filter(c => c.type === 'Other')

  return (
    <>
      <div className="p-8">
        <div className="mb-8 flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">Contacts</h1>
            <p className="text-muted-foreground">
              {customers.length} customers, {vendors.length} vendors, {parents.length} parent{parents.length !== 1 ? 's' : ''}, {others.length} other
            </p>
          </div>
          {canCreate && (
            <Button onClick={() => setDialogOpen(true)}>
              <Plus className="h-4 w-4 mr-2" />
              Add Contact
            </Button>
          )}
        </div>

        <Card>
          <CardHeader>
            <CardTitle>All Contacts</CardTitle>
            <CardDescription>{contacts.length} contacts</CardDescription>
          </CardHeader>
          <CardContent>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Type</TableHead>
                  <TableHead>Email</TableHead>
                  <TableHead>Phone</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {contacts.map((contact) => (
                  <TableRow key={contact.id} className="cursor-pointer hover:bg-muted/50">
                    <TableCell className="font-medium">
                      <Link href={`/contacts/${contact.id}`} className="block">
                        {contact.name}
                      </Link>
                    </TableCell>
                    <TableCell>
                      <Link href={`/contacts/${contact.id}`} className="block">
                        <Badge variant="outline">{contact.type}</Badge>
                      </Link>
                    </TableCell>
                    <TableCell className="text-muted-foreground text-sm">
                      <Link href={`/contacts/${contact.id}`} className="block">
                        {contact.email || '—'}
                      </Link>
                    </TableCell>
                    <TableCell className="text-muted-foreground text-sm">
                      <Link href={`/contacts/${contact.id}`} className="block">
                        {contact.phone || '—'}
                      </Link>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      </div>
        <AddContactDialog
          open={dialogOpen}
          onOpenChange={setDialogOpen}
          formData={formData}
          setFormData={setFormData}
          emailError={emailError}
          setEmailError={setEmailError}
          saveError={saveError}
          setSaveError={setSaveError}
          saving={saving}
          onSave={handleCreate}
        />
    </>
  )
}

function AddContactDialog({
  open,
  onOpenChange,
  formData,
  setFormData,
  emailError,
  setEmailError,
  saveError,
  setSaveError,
  saving,
  onSave,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  formData: {
    type: 'Vendor' | 'Customer' | 'Other' | 'Parent'
    name: string
    email: string
    phone: string
    address: string
    notes: string
  }
  setFormData: (data: any) => void
  emailError: string
  setEmailError: (error: string) => void
  saveError: string
  setSaveError: (error: string) => void
  saving: boolean
  onSave: () => void
}) {
  function validateEmail(email: string): boolean {
    if (!email) return true
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
    return emailRegex.test(email)
  }

  function handleEmailChange(email: string) {
    setFormData({ ...formData, email })
    if (email && !validateEmail(email)) {
      setEmailError('Please enter a valid email address')
    } else {
      setEmailError('')
    }
  }
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[525px]">
        <DialogHeader>
          <DialogTitle>Add Contact</DialogTitle>
          <DialogDescription>
            Add a customer for invoices, a vendor for bills, or the parent company for intercompany transactions.
          </DialogDescription>
        </DialogHeader>
        <div className="grid gap-4 py-4">
          {saveError && (
            <div className="p-3 rounded-md bg-red-50 text-red-800 border border-red-200">
              <p className="text-sm">{saveError}</p>
            </div>
          )}
          <div className="grid gap-2">
            <Label htmlFor="type">Type</Label>
            <select
              id="type"
              value={formData.type}
              onChange={(e) =>
                setFormData({ ...formData, type: e.target.value as 'Vendor' | 'Customer' | 'Other' | 'Parent' })
              }
              className="w-full rounded-md border border-neutral-300 px-3 py-2 text-sm"
            >
              <option value="Customer">Customer</option>
              <option value="Vendor">Vendor</option>
              <option value="Parent">Parent</option>
              <option value="Other">Other</option>
            </select>
          </div>
          <div className="grid gap-2">
            <Label htmlFor="name">Name *</Label>
            <Input
              id="name"
              value={formData.name}
              onChange={(e) => setFormData({ ...formData, name: e.target.value })}
              placeholder="Contact name"
            />
          </div>
          <div className="grid gap-2">
            <Label htmlFor="email">Email</Label>
            <Input
              id="email"
              type="email"
              value={formData.email}
              onChange={(e) => handleEmailChange(e.target.value)}
              placeholder="contact@example.com"
              className={emailError ? 'border-red-500' : ''}
            />
            {emailError && (
              <p className="text-sm text-red-600">{emailError}</p>
            )}
          </div>
          <div className="grid gap-2">
            <Label htmlFor="phone">Phone</Label>
            <Input
              id="phone"
              value={formData.phone}
              onChange={(e) => setFormData({ ...formData, phone: e.target.value })}
              placeholder="(555) 123-4567"
            />
          </div>
          <div className="grid gap-2">
            <Label htmlFor="address">Address</Label>
            <Textarea
              id="address"
              value={formData.address}
              onChange={(e) => setFormData({ ...formData, address: e.target.value })}
              placeholder="Full address"
              rows={2}
            />
          </div>
          <div className="grid gap-2">
            <Label htmlFor="notes">Notes</Label>
            <Textarea
              id="notes"
              value={formData.notes}
              onChange={(e) => setFormData({ ...formData, notes: e.target.value })}
              placeholder="Optional notes"
              rows={2}
            />
          </div>
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)} disabled={saving}>
            Cancel
          </Button>
          <Button onClick={onSave} disabled={saving || !formData.name.trim() || !!emailError}>
            {saving ? 'Saving...' : 'Add Contact'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
