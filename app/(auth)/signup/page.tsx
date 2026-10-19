import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { AuthBrand, AuthShell } from '@/components/app/auth-shell'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Button } from '@/components/ui/button'
import Link from 'next/link'
import { signUp } from '@/lib/actions'
import { TimezoneSelect } from './timezone-select'

type SearchParams = Promise<{ error?: string; success?: string }>

export default async function SignupPage(props: { searchParams: SearchParams }) {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (user) {
    redirect('/')
  }

  const searchParams = await props.searchParams
  const error = searchParams.error
  const success = searchParams.success

  const errorMessages: Record<string, string> = {
    missing_fields: 'Please fill in all required fields',
    invalid_email: 'Invalid email address',
    rate_limited: 'Too many attempts. Please try again later.',
    signup_failed: "Couldn't create the account. Try again.",
  }

  const successMessages: Record<string, string> = {
    confirm_email: 'Check your email to confirm your account.',
  }

  return (
    <AuthShell>
      <Card className="w-full max-w-md">
        <CardHeader className="space-y-3">
          <AuthBrand />
          <CardTitle className="text-[clamp(1.9rem,3vw,2.9rem)]">Open Ledger</CardTitle>
          <CardDescription>Create account</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {success && (
            <div className="rounded-md bg-green-50 px-3 py-2 text-sm text-green-800 border border-green-200">
              {successMessages[success] || 'Success'}
            </div>
          )}
          {error && (
            <div className="rounded-md bg-destructive/15 px-3 py-2 text-sm text-destructive">
              {errorMessages[error] || 'An error occurred. Please try again.'}
            </div>
          )}
          <form action={signUp} className="space-y-4">
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
            <div className="space-y-2">
              <Label htmlFor="company_name">Organization name</Label>
              <Input
                id="company_name"
                name="company_name"
                type="text"
                placeholder="Acme Inc"
                required
              />
            </div>
            <TimezoneSelect />
            <Button type="submit" className="w-full">
              Create account
            </Button>
          </form>
          <div className="text-center text-sm">
            <Link
              href="/login"
              className="text-muted-foreground hover:text-foreground"
            >
              Already have an account? Sign in
            </Link>
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
