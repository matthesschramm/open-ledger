'use client'

import { useEffect, useState } from 'react'
import { signIn } from '@/lib/actions'
import { getAuthHash } from '@/lib/auth-hash'
import { SetPasswordForm } from '@/components/set-password-form'
import { AuthBrand, AuthShell } from '@/components/app/auth-shell'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Button } from '@/components/ui/button'
import Link from 'next/link'

const LOGIN_ERRORS: Record<string, string> = {
  missing_credentials: 'Email and password are required',
  invalid_credentials: 'Invalid email or password',
}

export function LoginScreen({ error }: { error?: string }) {
  const [inviteFlow, setInviteFlow] = useState(false)
  const formError = error ? LOGIN_ERRORS[error] ?? 'Could not sign in' : null

  useEffect(() => {
    if (getAuthHash() || new URLSearchParams(window.location.search).get('code')) {
      setInviteFlow(true)
    }
  }, [])

  if (inviteFlow) {
    return (
      <AuthShell>
        <SetPasswordForm />
      </AuthShell>
    )
  }

  return (
    <AuthShell>
      <Card className="w-full max-w-md">
        <CardHeader className="space-y-3">
          <AuthBrand />
          <CardTitle className="text-[clamp(1.9rem,3vw,2.9rem)]">Open Ledger</CardTitle>
          <CardDescription>Sign in to your account</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <form action={signIn} className="space-y-4">
            {formError && (
              <div className="rounded-md bg-destructive/15 px-3 py-2 text-sm text-destructive">
                {formError}
              </div>
            )}
            <div className="space-y-2">
              <Label htmlFor="email">Email</Label>
              <Input
                id="email"
                name="email"
                type="email"
                placeholder="you@example.com"
                required
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="password">Password</Label>
              <Input
                id="password"
                name="password"
                type="password"
                placeholder="••••••••"
                required
              />
            </div>
            <Button type="submit" className="w-full">
              Sign In
            </Button>
          </form>
          <div className="flex flex-col gap-2 text-center text-sm">
            <Link
              href="/forgot-password"
              className="text-muted-foreground hover:text-foreground"
            >
              Forgot your password?
            </Link>
            <Link
              href="/signup"
              className="text-muted-foreground hover:text-foreground"
            >
              Create account
            </Link>
            <p className="text-xs text-muted-foreground">
              Invited? Open the link in your email to set a password.
            </p>
          </div>
        </CardContent>
      </Card>
      <p className="mt-6 text-center font-mono text-[0.58rem] font-semibold uppercase tracking-[0.08em] text-muted-foreground">
        <Link href="/docs" className="underline underline-offset-4 hover:text-foreground">
          API and MCP documentation
        </Link>
      </p>
    </AuthShell>
  )
}
