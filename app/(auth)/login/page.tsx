import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { LoginScreen } from '@/components/login-screen'

type SearchParams = Promise<{ error?: string }>

export default async function LoginPage(props: { searchParams: SearchParams }) {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (user) {
    redirect('/')
  }

  const searchParams = await props.searchParams
  return <LoginScreen error={searchParams.error} />
}
