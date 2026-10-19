import { createClient as createServerClient } from '@/lib/supabase/server'
import { APIKeysPageClient } from './page-client'

export default async function APIKeysPage() {
  const supabase = await createServerClient()
  
  const { data: orgData } = await supabase
    .from('organizations')
    .select('id, name')
    .single()
  
  const currentOrgId = orgData?.id || null
  const currentOrgName = orgData?.name || ''
  
  return <APIKeysPageClient currentOrgId={currentOrgId} currentOrgName={currentOrgName} />
}
