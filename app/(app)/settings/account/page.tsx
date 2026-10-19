import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Button } from '@/components/ui/button'
import { updatePassword } from '@/lib/actions'
import Link from 'next/link'

type SearchParams = Promise<{ error?: string; success?: string }>

const ERRORS: Record<string, string> = {
  short_password: 'Password must be at least 6 characters',
  mismatch: 'Passwords do not match',
  failed: "Couldn't update the password. Try again.",
}

export default async function AccountSettingsPage(props: { searchParams: SearchParams }) {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (!user) {
    redirect('/login')
  }

  const searchParams = await props.searchParams
  const error = searchParams.error ? ERRORS[searchParams.error] ?? 'Could not update the password' : null
  const saved = searchParams.success === 'true'

  return (
    <div className="p-8 max-w-xl">
      <div className="mb-8">
        <h1 className="text-3xl font-semibold tracking-tight">Account</h1>
        <p className="text-muted-foreground">{user.email}</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Change password</CardTitle>
          <CardDescription>
            Use this when you already know your current password. If you forgot it, sign out and use Forgot your password.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          {saved && (
            <div className="rounded-md bg-green-50 px-3 py-2 text-sm text-green-800 border border-green-200">
              Password updated.
            </div>
          )}
          {error && (
            <div className="rounded-md bg-destructive/15 px-3 py-2 text-sm text-destructive">
              {error}
            </div>
          )}
          <form action={updatePassword} className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="password">New password</Label>
              <Input
                id="password"
                name="password"
                type="password"
                autoComplete="new-password"
                required
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="confirm_password">Confirm new password</Label>
              <Input
                id="confirm_password"
                name="confirm_password"
                type="password"
                autoComplete="new-password"
                required
              />
            </div>
            <Button type="submit">Update password</Button>
          </form>
        </CardContent>
      </Card>

      <div className="mt-6 text-sm">
        <Link href="/settings" className="text-muted-foreground hover:text-foreground">
          Back to settings
        </Link>
      </div>
    </div>
  )
}
