'use client'

import { useEffect, useState, type FormEvent } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { getAuthHash } from '@/lib/auth-hash'
import { AuthBrand } from '@/components/app/auth-shell'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Button } from '@/components/ui/button'
import Link from 'next/link'

export function SetPasswordForm() {
  const router = useRouter()
  const [status, setStatus] = useState<'loading' | 'ready' | 'invalid'>('loading')
  const [mode, setMode] = useState<'create' | 'reset'>('create')
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const supabase = createClient()

    async function establishSession() {
      const params = new URLSearchParams(window.location.search)
      const authHash = getAuthHash()
      const code = params.get('code')
      const hashType = authHash?.type || params.get('type')
      if (hashType === 'recovery') {
        setMode('reset')
      }

      if (code) {
        const { error: exchangeError } = await supabase.auth.exchangeCodeForSession(code)
        if (exchangeError && !cancelled) {
          setStatus('invalid')
          return
        }
      } else if (authHash) {
        const { error: sessionError } = await supabase.auth.setSession({
          access_token: authHash.accessToken,
          refresh_token: authHash.refreshToken,
        })
        if (sessionError && !cancelled) {
          setStatus('invalid')
          return
        }
      }

      const { data: first } = await supabase.auth.getSession()
      if (first.session) {
        await supabase.rpc('accept_pending_invitation')
        if (!cancelled) setStatus('ready')
        return
      }

      await new Promise((resolve) => setTimeout(resolve, 250))
      const { data: second } = await supabase.auth.getSession()
      if (second.session) {
        await supabase.rpc('accept_pending_invitation')
      }
      if (!cancelled) {
        setStatus(second.session ? 'ready' : 'invalid')
      }
    }

    establishSession()
    return () => {
      cancelled = true
    }
  }, [])

  async function handleSubmit(event: FormEvent) {
    event.preventDefault()
    setError(null)

    if (password.length < 6) {
      setError('Password must be at least 6 characters')
      return
    }
    if (password !== confirm) {
      setError('Passwords do not match')
      return
    }

    setSubmitting(true)
    const supabase = createClient()
    const { error: updateError } = await supabase.auth.updateUser({ password })
    if (!updateError) {
      await supabase.rpc('accept_pending_invitation')
    }
    setSubmitting(false)

    if (updateError) {
      setError(updateError.message)
      return
    }

    router.push('/')
    router.refresh()
  }

  return (
    <Card className="w-full max-w-md">
      <CardHeader className="space-y-3">
        <AuthBrand />
        <CardTitle className="text-[clamp(1.9rem,3vw,2.9rem)]">
          {mode === 'reset' ? 'Reset your password' : 'Create your password'}
        </CardTitle>
        <CardDescription>
          {mode === 'reset'
            ? 'Choose a new password for your account'
            : 'Choose a password to finish joining this organization'}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {status === 'loading' && (
          <p className="text-sm text-muted-foreground">Opening your invite…</p>
        )}
        {status === 'invalid' && (
          <div className="space-y-4">
            <div className="rounded-md bg-destructive/15 px-3 py-2 text-sm text-destructive">
              This invite link is invalid or expired. Ask the owner to send it again.
            </div>
            <div className="text-center text-sm">
              <Link href="/login" className="text-muted-foreground hover:text-foreground">
                Back to login
              </Link>
            </div>
          </div>
        )}
        {status === 'ready' && (
          <form onSubmit={handleSubmit} className="space-y-4">
            {error && (
              <div className="rounded-md bg-destructive/15 px-3 py-2 text-sm text-destructive">
                {error}
              </div>
            )}
            <div className="space-y-2">
              <Label htmlFor="password">Password</Label>
              <Input
                id="password"
                type="password"
                autoComplete="new-password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                required
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="confirm_password">Confirm password</Label>
              <Input
                id="confirm_password"
                type="password"
                autoComplete="new-password"
                value={confirm}
                onChange={(event) => setConfirm(event.target.value)}
                required
              />
            </div>
            <Button type="submit" className="w-full" disabled={submitting}>
              {submitting
                ? 'Saving…'
                : mode === 'reset'
                  ? 'Save new password'
                  : 'Create password and continue'}
            </Button>
          </form>
        )}
      </CardContent>
    </Card>
  )
}
