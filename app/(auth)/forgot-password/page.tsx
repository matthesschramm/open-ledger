import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { AuthBrand, AuthShell } from '@/components/app/auth-shell'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Button } from '@/components/ui/button'
import Link from 'next/link'
import { resetPasswordForEmail } from '@/lib/actions'

type SearchParams = Promise<{ error?: string; success?: string }>

const ERRORS: Record<string, string> = {
  missing_email: 'Enter the email on your account',
  failed: "Couldn't send a reset link. Try again.",
}

export default async function ForgotPasswordPage(props: { searchParams: SearchParams }) {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (user) {
    redirect('/settings/account')
  }

  const searchParams = await props.searchParams
  const error = searchParams.error ? ERRORS[searchParams.error] ?? 'Could not send the reset email' : null
  const sent = searchParams.success === 'true'

  return (
    <AuthShell>
      <Card className="w-full max-w-md">
        <CardHeader className="space-y-3">
          <AuthBrand />
          <CardTitle className="text-[clamp(1.9rem,3vw,2.9rem)]">Reset your password</CardTitle>
          <CardDescription>
            We will email a link to choose a new password
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {sent && (
            <div className="rounded-md bg-green-50 px-3 py-2 text-sm text-green-800 border border-green-200">
              Check your email for a reset link.
            </div>
          )}
          {error && (
            <div className="rounded-md bg-destructive/15 px-3 py-2 text-sm text-destructive">
              {error}
            </div>
          )}
          <form action={resetPasswordForEmail} className="space-y-4">
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
            <Button type="submit" className="w-full">
              Send reset link
            </Button>
          </form>
          <div className="text-center text-sm">
            <Link
              href="/login"
              className="text-muted-foreground hover:text-foreground"
            >
              Back to login
            </Link>
          </div>
        </CardContent>
      </Card>
    </AuthShell>
  )
}
