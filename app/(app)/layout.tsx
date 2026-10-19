import { AppChrome } from '@/components/app/app-chrome'
import { AppNav } from '@/components/app/app-nav'
import { createClient } from '@/lib/supabase/server'

type UserCompany = {
  organization_id: string
  organization_name: string
  role: string
  is_active: boolean
}

export default async function AppLayout({
  children,
}: {
  children: React.ReactNode
}) {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (!user) {
    return <>{children}</>
  }

  // Try get_user_companies RPC first
  const { data: companies, error: rpcError } = await supabase.rpc('get_user_companies') as { data: UserCompany[] | null, error: any }

  let companiesList: { id: string; name: string; role: string; isActive: boolean }[] = []

  if (rpcError || !companies) {
    // Log error and fall back to direct query
    console.error('get_user_companies RPC failed, falling back to direct query:', rpcError)
    
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
        id: m.organization_id,
        name: m.organizations?.name || 'Unknown Company',
        role: m.role,
        isActive: m.organization_id === activeCompanyId,
      }))
    }
  } else {
    companiesList = companies.map((c) => ({
      id: c.organization_id,
      name: c.organization_name,
      role: c.role,
      isActive: c.is_active,
    }))
  }

  const currentCompany = companiesList.find((c) => c.isActive) || companiesList[0] || null

  return (
    <div className="flex h-screen bg-background">
      <AppNav companies={companiesList} currentCompany={currentCompany} />
      <AppChrome>{children}</AppChrome>
    </div>
  )
}
