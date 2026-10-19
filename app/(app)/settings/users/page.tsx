'use client'

import { useState, useEffect } from 'react'
import { createClient } from '@/lib/supabase/client'
import { inviteMember } from '@/lib/actions'
import { useRouter } from 'next/navigation'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { UserPlus, Trash2 } from 'lucide-react'

type MembershipRole = 'owner' | 'bookkeeper' | 'read_only'

interface MemberRow {
  id: string
  user_id: string
  role: MembershipRole
  email: string
  status: 'Active' | 'Invited'
  created_at: string
  is_current_user: boolean
}

export default function UsersPage() {
  const router = useRouter()
  const supabase = createClient()
  const [members, setMembers] = useState<MemberRow[]>([])
  const [currentUserId, setCurrentUserId] = useState<string | null>(null)
  const [currentRole, setCurrentRole] = useState<MembershipRole | null>(null)
  const [loading, setLoading] = useState(true)
  const [inviteEmail, setInviteEmail] = useState('')
  const [inviteRole, setInviteRole] = useState<MembershipRole>('bookkeeper')
  const [inviting, setInviting] = useState(false)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)
  const [successMessage, setSuccessMessage] = useState<string | null>(null)

  useEffect(() => {
    loadData()
  }, [])

  async function loadData() {
    const { data: { user } } = await supabase.auth.getUser()
    
    if (!user) {
      router.push('/login')
      return
    }

    setCurrentUserId(user.id)
    await Promise.all([loadMembers(user.id, user.email), loadCurrentRole()])
  }

  async function loadMembers(userId: string, currentUserEmail: string | undefined) {
    const rows: MemberRow[] = []

    // Load active memberships
    const { data: memberships } = await supabase
      .from('memberships')
      .select('*')
      .order('created_at')

    if (memberships) {
      for (const m of memberships) {
        let email: string
        if (m.user_id === userId && currentUserEmail) {
          // Use the current user's email from auth
          email = currentUserEmail
        } else {
          // Fetch email for other users
          const fetchedEmail = await getUserEmail(m.user_id)
          email = fetchedEmail || 'Unknown'
        }
        
        rows.push({
          id: m.id,
          user_id: m.user_id,
          role: m.role as MembershipRole,
          email: email,
          status: 'Active',
          created_at: m.created_at,
          is_current_user: m.user_id === userId
        })
      }
    }

    // Load pending invitations
    const { data: invitations } = await supabase
      .from('invitations')
      .select('*')
      .eq('status', 'pending')
      .order('created_at')

    if (invitations) {
      for (const inv of invitations) {
        rows.push({
          id: inv.id,
          user_id: inv.id,
          role: inv.role as MembershipRole,
          email: inv.email,
          status: 'Invited',
          created_at: inv.created_at,
          is_current_user: false
        })
      }
    }

    setMembers(rows)
    setLoading(false)
  }

  async function getUserEmail(userId: string): Promise<string | null> {
    const { data } = await supabase.rpc('get_user_email', { p_user_id: userId })
    return data
  }

  async function loadCurrentRole() {
    const { data } = await supabase.rpc('current_role')
    if (data) {
      setCurrentRole(data)
    }
  }

  async function handleInvite() {
    if (!inviteEmail.trim()) return
    
    setInviting(true)
    setErrorMessage(null)
    setSuccessMessage(null)

    const trimmedEmail = inviteEmail.trim().toLowerCase()
    const result = await inviteMember(inviteEmail, inviteRole)

    if (!result.success) {
      setErrorMessage(result.error)
    } else if (result.attached) {
      // Existing Auth user was added as a member; optional notify via magic link.
      const { data: emailData, error: emailError } = await supabase.functions.invoke(
        'send-invite-email',
        {
          body: {
            email: trimmedEmail,
            redirectTo: process.env.NEXT_PUBLIC_APP_URL || `${window.location.origin}/set-password`,
          },
        }
      )

      setInviteEmail('')
      if (emailError) {
        setSuccessMessage(`${trimmedEmail} was added to the organization. Notification email could not be sent.`)
      } else if (emailData?.emailed === false) {
        setSuccessMessage(`${trimmedEmail} was added to the organization.`)
      } else {
        setSuccessMessage(`${trimmedEmail} was added and notified by email.`)
      }
    } else {
      const { data: emailData, error: emailError } = await supabase.functions.invoke(
        'send-invite-email',
        {
          body: {
            email: trimmedEmail,
            redirectTo: process.env.NEXT_PUBLIC_APP_URL || `${window.location.origin}/set-password`,
          },
        }
      )

      if (emailError) {
        const detail =
          typeof emailData?.error === 'string' ? emailData.error : emailError.message
        setErrorMessage(`Invitation saved, but the email failed: ${detail}`)
      } else {
        setInviteEmail('')
        setSuccessMessage(
          result.resend
            ? `Invitation email re-sent to ${trimmedEmail}`
            : `Invitation sent to ${trimmedEmail}`
        )
      }
    }
    
    const { data: { user } } = await supabase.auth.getUser()
    if (currentUserId && user?.email) {
      await loadMembers(currentUserId, user.email)
    }
    
    setInviting(false)
  }

  async function handleRemove(membershipId: string, status: 'Active' | 'Invited') {
    setErrorMessage(null)
    
    if (status === 'Active') {
      const { data, error } = await supabase.rpc('remove_member', {
        p_membership_id: membershipId
      })
      
      // Parse data if it's a JSON string
      let parsedData = data
      if (typeof data === 'string') {
        try {
          parsedData = JSON.parse(data)
        } catch {
          parsedData = data
        }
      }
      
      if (error) {
        setErrorMessage(error.message)
      } else if (parsedData && parsedData.success === false) {
        setErrorMessage(parsedData.error || 'Operation failed')
      }
      
      // Always reload to reflect actual database state
      const { data: { user } } = await supabase.auth.getUser()
      if (currentUserId && user?.email) {
        await loadMembers(currentUserId, user.email)
      }
    } else {
      // Remove invitation via RPC (logs audit event)
      const { data, error } = await supabase.rpc('remove_invitation', {
        p_invitation_id: membershipId
      })
      
      // Parse data if it's a JSON string
      let parsedData = data
      if (typeof data === 'string') {
        try {
          parsedData = JSON.parse(data)
        } catch {
          parsedData = data
        }
      }
      
      if (error) {
        setErrorMessage(error.message)
      } else if (parsedData && parsedData.success === false) {
        setErrorMessage(parsedData.error || 'Operation failed')
      }
      
      // Always reload
      const { data: { user } } = await supabase.auth.getUser()
      if (currentUserId && user?.email) {
        await loadMembers(currentUserId, user.email)
      }
    }
  }

  async function handleRoleChange(membershipId: string, newRole: MembershipRole, status: 'Active' | 'Invited') {
    setErrorMessage(null)
    
    if (status === 'Active') {
      const { data, error } = await supabase.rpc('change_member_role', {
        p_membership_id: membershipId,
        p_new_role: newRole
      })
      
      // Parse data if it's a JSON string
      let parsedData = data
      if (typeof data === 'string') {
        try {
          parsedData = JSON.parse(data)
        } catch {
          parsedData = data
        }
      }
      
      if (error) {
        setErrorMessage(error.message)
      } else if (parsedData && parsedData.success === false) {
        setErrorMessage(parsedData.error || 'Operation failed')
      }
      
      // Always reload to reflect actual database state
      await loadCurrentRole()
      const { data: { user } } = await supabase.auth.getUser()
      if (currentUserId && user?.email) {
        await loadMembers(currentUserId, user.email)
      }
    } else {
      // Update invitation role via RPC (logs audit event)
      const { data, error } = await supabase.rpc('change_invitation_role', {
        p_invitation_id: membershipId,
        p_new_role: newRole
      })
      
      // Parse data if it's a JSON string
      let parsedData = data
      if (typeof data === 'string') {
        try {
          parsedData = JSON.parse(data)
        } catch {
          parsedData = data
        }
      }
      
      if (error) {
        setErrorMessage(error.message)
      } else if (parsedData && parsedData.success === false) {
        setErrorMessage(parsedData.error || 'Operation failed')
      }
      
      // Always reload
      const { data: { user } } = await supabase.auth.getUser()
      if (currentUserId && user?.email) {
        await loadMembers(currentUserId, user.email)
      }
    }
  }

  function formatRole(role: MembershipRole): string {
    switch (role) {
      case 'owner': return 'Owner'
      case 'bookkeeper': return 'Bookkeeper'
      case 'read_only': return 'Read only'
      default: return role
    }
  }

  const isOwner = currentRole === 'owner'
  const isSolo = members.length === 1 && members[0]?.is_current_user && isOwner

  if (loading) {
    return (
      <div className="p-8">
        <p className="text-neutral-600">Loading...</p>
      </div>
    )
  }

  return (
    <div className="p-8 space-y-8">
      <div>
        <h1 className="text-3xl font-semibold tracking-tight">Users</h1>
        <p className="text-muted-foreground">Manage team members and their roles</p>
      </div>

      {!isOwner && (
        <Card className="border-yellow-200 bg-yellow-50">
          <CardContent className="pt-6">
            <p className="text-sm text-yellow-800">
              Only the owner can invite people.
            </p>
          </CardContent>
        </Card>
      )}

      {errorMessage && (
        <Card className="border-red-200 bg-red-50">
          <CardContent className="pt-6">
            <p className="text-sm text-red-800">
              {errorMessage}
            </p>
          </CardContent>
        </Card>
      )}

      {successMessage && (
        <Card className="border-green-200 bg-green-50">
          <CardContent className="pt-6">
            <p className="text-sm text-green-800">
              {successMessage}
            </p>
          </CardContent>
        </Card>
      )}

      <Card>
        <CardContent className="pt-6">
          {isSolo && (
            <div className="mb-4 space-y-4">
              <p className="text-sm text-neutral-600">You're the only one here.</p>
              {isOwner && (
                <div className="flex gap-4">
                  <input
                    type="email"
                    value={inviteEmail}
                    onChange={(e) => setInviteEmail(e.target.value)}
                    placeholder="email@example.com"
                    className="flex-1 rounded-md border border-neutral-300 px-3 py-2 text-sm focus:border-neutral-500 focus:outline-none"
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') {
                        handleInvite()
                      }
                    }}
                  />
                  <select
                    value={inviteRole}
                    onChange={(e) => setInviteRole(e.target.value as MembershipRole)}
                    className="rounded-md border border-neutral-300 px-3 py-2 text-sm focus:border-neutral-500 focus:outline-none"
                  >
                    <option value="bookkeeper">Bookkeeper</option>
                    <option value="read_only">Read only</option>
                    <option value="owner">Owner</option>
                  </select>
                  <Button onClick={handleInvite} disabled={inviting || !inviteEmail.trim()}>
                    <UserPlus className="h-4 w-4 mr-2" />
                    Invite
                  </Button>
                </div>
              )}
            </div>
          )}
          {!isSolo && (
            <>
              {isOwner && (
                <div className="mb-4 flex gap-4">
                  <input
                    type="email"
                    value={inviteEmail}
                    onChange={(e) => setInviteEmail(e.target.value)}
                    placeholder="email@example.com"
                    className="flex-1 rounded-md border border-neutral-300 px-3 py-2 text-sm focus:border-neutral-500 focus:outline-none"
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') {
                        handleInvite()
                      }
                    }}
                  />
                  <select
                    value={inviteRole}
                    onChange={(e) => setInviteRole(e.target.value as MembershipRole)}
                    className="rounded-md border border-neutral-300 px-3 py-2 text-sm focus:border-neutral-500 focus:outline-none"
                  >
                    <option value="bookkeeper">Bookkeeper</option>
                    <option value="read_only">Read only</option>
                    <option value="owner">Owner</option>
                  </select>
                  <Button onClick={handleInvite} disabled={inviting || !inviteEmail.trim()}>
                    <UserPlus className="h-4 w-4 mr-2" />
                    Invite
                  </Button>
                </div>
              )}
            </>
          )}
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Email</TableHead>
                <TableHead>Role</TableHead>
                <TableHead>Status</TableHead>
                {isOwner && <TableHead className="text-right">Actions</TableHead>}
              </TableRow>
            </TableHeader>
            <TableBody>
              {members.map((member) => (
                <TableRow key={member.id}>
                  <TableCell>
                    {member.email}
                    {member.is_current_user && <span className="ml-2 text-xs text-neutral-500">(You)</span>}
                  </TableCell>
                  <TableCell>
                    {isOwner && member.status === 'Active' ? (
                      <select
                        value={member.role}
                        onChange={(e) => handleRoleChange(member.id, e.target.value as MembershipRole, member.status)}
                        className="rounded border border-neutral-300 px-2 py-1 text-sm"
                      >
                        <option value="owner">Owner</option>
                        <option value="bookkeeper">Bookkeeper</option>
                        <option value="read_only">Read only</option>
                      </select>
                    ) : isOwner && member.status === 'Invited' ? (
                      <select
                        value={member.role}
                        onChange={(e) => handleRoleChange(member.id, e.target.value as MembershipRole, member.status)}
                        className="rounded border border-neutral-300 px-2 py-1 text-sm"
                      >
                        <option value="owner">Owner</option>
                        <option value="bookkeeper">Bookkeeper</option>
                        <option value="read_only">Read only</option>
                      </select>
                    ) : (
                      formatRole(member.role)
                    )}
                  </TableCell>
                  <TableCell>{member.status}</TableCell>
                  {isOwner && (
                    <TableCell className="text-right">
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => handleRemove(member.id, member.status)}
                      >
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </div>
  )
}
