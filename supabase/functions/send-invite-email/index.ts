import 'jsr:@supabase/functions-js/edge-runtime.d.ts'
import { createClient } from 'jsr:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

function isAlreadyRegistered(message: string) {
  const lower = message.toLowerCase()
  return (
    lower.includes('already') ||
    lower.includes('registered') ||
    lower.includes('exists') ||
    lower.includes('duplicate')
  )
}

async function findAuthUserId(
  admin: ReturnType<typeof createClient>,
  email: string
): Promise<string | null> {
  // Paginate a bit; invite volume is small and listUsers has no email filter.
  for (let page = 1; page <= 10; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 })
    if (error) throw error
    const match = data.users.find((u) => (u.email || '').toLowerCase() === email)
    if (match) return match.id
    if (data.users.length < 200) break
  }
  return null
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405)
  }

  const authHeader = req.headers.get('Authorization')
  if (!authHeader) {
    return json({ error: 'Not authenticated' }, 401)
  }

  let payload: { email?: string; redirectTo?: string }
  try {
    payload = await req.json()
  } catch {
    return json({ error: 'Invalid JSON' }, 400)
  }

  const email = payload.email?.trim().toLowerCase()
  if (!email || !email.includes('@')) {
    return json({ error: 'Valid email is required' }, 400)
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json({ error: 'Server is missing Supabase credentials' }, 500)
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  })

  const { data: role, error: roleError } = await userClient.rpc('current_role')
  if (roleError || role !== 'owner') {
    return json({ error: 'Permission denied: owner role required' }, 403)
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })

  const redirectTo =
    payload.redirectTo && !payload.redirectTo.includes('localhost')
      ? payload.redirectTo
      : (Deno.env.get('NEXT_PUBLIC_APP_URL') || 'http://localhost:3000') + '/set-password'

  let existingUserId: string | null = null
  try {
    existingUserId = await findAuthUserId(admin, email)
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Failed to look up user'
    return json({ error: message }, 400)
  }

  // Existing Auth users: do not call inviteUserByEmail (returns non-2xx).
  // Send a magic link to the set-password landing instead.
  if (existingUserId) {
    const { error: otpError } = await admin.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: redirectTo,
        data: { invite_flow: 'create_password' },
      },
    })
    if (otpError) {
      // Membership may already be attached; treat mail failure as soft success
      // so the owner is not stuck on a false "invite failed" after a good attach.
      return json({ success: true, attached: true, emailed: false, warning: otpError.message })
    }
    return json({ success: true, resent: true })
  }

  const { error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
    redirectTo,
    data: { invite_flow: 'create_password' },
  })

  if (!inviteError) {
    return json({ success: true })
  }

  if (!isAlreadyRegistered(inviteError.message)) {
    return json({ error: inviteError.message }, 400)
  }

  // Race: user appeared between lookup and invite. Fall back to magic link.
  const { error: otpError } = await admin.auth.signInWithOtp({
    email,
    options: {
      emailRedirectTo: redirectTo,
      data: { invite_flow: 'create_password' },
    },
  })
  if (otpError) {
    return json({ success: true, attached: true, emailed: false, warning: otpError.message })
  }

  return json({ success: true, resent: true })
})
