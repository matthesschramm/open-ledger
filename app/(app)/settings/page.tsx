import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import Link from 'next/link'
import { Users, Key, Calendar, FileCheck, Building2, KeyRound } from 'lucide-react'
import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'

const settings = [
  {
    name: 'Account',
    description: 'Change the password on this login',
    href: '/settings/account',
    icon: KeyRound,
    disabled: false,
  },
  {
    name: 'Organization',
    description: 'Name and capitalization threshold',
    href: '/settings/organization',
    icon: Building2,
    disabled: false,
  },
  {
    name: 'Users',
    description: 'Manage user accounts and permissions',
    href: '/settings/users',
    icon: Users,
    disabled: true,
  },
  {
    name: 'API Keys',
    description: 'Generate and manage API keys',
    href: '/settings/api-keys',
    icon: Key,
    disabled: true,
  },
  {
    name: 'Accounting Periods',
    description: 'Configure and manage accounting periods',
    href: '/settings/periods',
    icon: Calendar,
    disabled: true,
  },
  {
    name: 'Audit Log',
    description: 'View system activity and changes',
    href: '/settings/audit',
    icon: FileCheck,
    disabled: true,
  },
]

export default async function SettingsPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (!user) {
    redirect('/login')
  }

  const { data: org } = await supabase
    .from('organizations')
    .select('id, name')
    .single()

  return (
    <div className="p-8">
      <div className="mb-8">
        <p className="page-kicker">Account</p>
        <h1 className="text-3xl font-semibold tracking-tight">Settings</h1>
        <p className="text-muted-foreground">
          System configuration and preferences
        </p>
      </div>

      <Card className="mb-6">
        <CardHeader>
          <CardTitle className="text-base">Tenant Identity</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="space-y-2 text-sm">
            <div>
              <span className="text-ink-soft">Signed in as </span>
              <span className="font-medium">{user.email}</span>
            </div>
            {org && (
              <div>
                <span className="text-ink-soft">Organization </span>
                <span className="font-medium">{org.name}</span>
              </div>
            )}
          </div>
        </CardContent>
      </Card>

      <div className="hairline-grid md:grid-cols-2">
        {settings.map((setting, index) => {
          const Icon = setting.icon
          return (
            <div key={setting.name} className="hairline-cell">
              <div className="mb-8 flex items-start justify-between">
                <span className="font-mono text-[0.62rem] font-semibold tracking-[0.08em] text-coral">
                  {String(index + 1).padStart(2, '0')}
                </span>
                <Icon className="h-5 w-5 text-coral" />
              </div>
              <h2 className="text-[clamp(1.35rem,2.1vw,2rem)]">{setting.name}</h2>
              <p className="mt-2 text-[0.78rem] text-ink-soft">{setting.description}</p>
              <div className="mt-6">
                <Link href={setting.href}>
                  <Button variant="outline">Configure</Button>
                </Link>
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
