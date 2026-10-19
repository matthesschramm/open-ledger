'use client'

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { getAuthHash } from '@/lib/auth-hash'
import { AuthShell } from '@/components/app/auth-shell'
import { SetPasswordForm } from '@/components/set-password-form'

export function InviteLanding() {
  const router = useRouter()
  const [inviteFlow, setInviteFlow] = useState(false)

  useEffect(() => {
    if (getAuthHash() || new URLSearchParams(window.location.search).get('code')) {
      setInviteFlow(true)
      return
    }
    router.replace('/login')
  }, [router])

  if (inviteFlow) {
    return (
      <AuthShell>
        <SetPasswordForm />
      </AuthShell>
    )
  }

  return (
    <AuthShell>
      <p className="text-sm text-muted-foreground">Opening your invite…</p>
    </AuthShell>
  )
}
