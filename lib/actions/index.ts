'use server'

import { createClient } from '@/lib/supabase/server'
import { generateAPIKey, hashAPIKey } from '@/lib/api-auth'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { headers } from 'next/headers'
import { isValidTimeZone } from '../timezone-validation'

type MembershipRole = 'owner' | 'bookkeeper' | 'read_only'

function parseRpcPayload(
  data: unknown
): { success?: boolean; error?: string; attached?: boolean } | null {
  if (data == null) return null
  if (typeof data === 'string') {
    try {
      return JSON.parse(data)
    } catch {
      return null
    }
  }
  if (typeof data === 'object') {
    return data as { success?: boolean; error?: string; attached?: boolean }
  }
  return null
}

async function requestOrigin() {
  const headersList = await headers()
  const host = headersList.get('x-forwarded-host') || headersList.get('host') || 'localhost:3000'
  const protocol = headersList.get('x-forwarded-proto') || 'http'
  return `${protocol}://${host}`
}

export async function signIn(formData: FormData) {
  const email = formData.get('email') as string
  const password = formData.get('password') as string

  if (!email || !password) {
    redirect('/login?error=missing_credentials')
  }

  const supabase = await createClient()
  const { error } = await supabase.auth.signInWithPassword({
    email,
    password,
  })

  if (error) {
    redirect('/login?error=invalid_credentials')
  }

  redirect('/')
}

export async function signOut() {
  const supabase = await createClient()
  await supabase.auth.signOut()
  redirect('/login')
}

export async function resetPasswordForEmail(formData: FormData) {
  const email = formData.get('email') as string

  if (!email) {
    redirect('/forgot-password?error=missing_email')
  }

  const origin = await requestOrigin()

  const supabase = await createClient()
  const { error } = await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: `${origin}/set-password`,
  })

  if (error) {
    redirect('/forgot-password?error=failed')
  }

  redirect('/forgot-password?success=true')
}

export async function updatePassword(formData: FormData) {
  const password = formData.get('password') as string
  const confirm = formData.get('confirm_password') as string

  if (!password || password.length < 6) {
    redirect('/settings/account?error=short_password')
  }
  if (password !== confirm) {
    redirect('/settings/account?error=mismatch')
  }

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) {
    redirect('/login')
  }

  const { error } = await supabase.auth.updateUser({ password })
  if (error) {
    redirect('/settings/account?error=failed')
  }

  redirect('/settings/account?success=true')
}

export async function inviteMember(
  email: string,
  role: MembershipRole
): Promise<
  | { success: false; error: string }
  | { success: true; attached?: boolean; resend?: boolean }
> {
  const trimmed = email.trim().toLowerCase()
  if (!trimmed) {
    return { success: false, error: 'Email is required' }
  }

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) {
    return { success: false, error: 'Not authenticated' }
  }

  const { data, error } = await supabase.rpc('invite_member', {
    p_email: trimmed,
    p_role: role,
  })

  if (error) {
    return { success: false, error: error.message }
  }

  const parsed = parseRpcPayload(data)
  const alreadyInvited = parsed?.error?.toLowerCase().includes('already been sent')
  if (parsed && parsed.success === false && !alreadyInvited) {
    return { success: false, error: parsed.error || 'Invitation failed' }
  }

  revalidatePath('/settings/users')
  return {
    success: true,
    attached: Boolean(parsed?.attached),
    // Pending invite already exists: still allow the edge function to resend mail.
    resend: Boolean(alreadyInvited),
  }
}

export async function signUp(formData: FormData) {
  const email = formData.get('email') as string
  const password = formData.get('password') as string
  const companyName = formData.get('company_name') as string
  const timezone = formData.get('timezone') as string

  if (!email || !password || !companyName) {
    redirect('/signup?error=missing_fields')
  }

  const supabase = await createClient()
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      data: {
        company_name: companyName.trim(),
        timezone: timezone || 'America/New_York',
      },
    },
  })

  if (error) {
    // Check for specific error types
    if (error.message?.includes('email_address_invalid') || error.message?.includes('invalid email')) {
      redirect('/signup?error=invalid_email')
    }
    if (error.status === 429 || error.message?.includes('rate limit')) {
      redirect('/signup?error=rate_limited')
    }
    // Generic unexpected failure
    redirect('/signup?error=signup_failed')
  }

  // If signup succeeded but no session (email confirmation required)
  if (data.user && !data.session) {
    redirect('/signup?success=confirm_email')
  }

  // Sign in the user immediately after signup (when email confirmation is disabled)
  const { error: signInError } = await supabase.auth.signInWithPassword({
    email,
    password,
  })

  if (signInError) {
    redirect('/login?error=signin_after_signup_failed')
  }

  redirect('/')
}

export async function updateOrganizationName(formData: FormData) {
  const name = formData.get('name') as string

  if (!name || name.trim() === '') {
    redirect('/settings/organization?error=name_required')
  }

  const supabase = await createClient()

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) {
    redirect('/settings/organization?error=not_authenticated')
  }

  const { data: orgId } = await supabase.rpc('current_org_id')
  if (!orgId) {
    redirect('/settings/organization?error=org_not_found')
  }

  const { data: role } = await supabase.rpc('current_role')
  if (role !== 'owner') {
    redirect('/settings/organization?error=not_owner')
  }

  const { error } = await supabase
    .from('organizations')
    .update({ name: name.trim() })
    .eq('id', orgId)

  if (error) {
    redirect('/settings/organization?error=update_failed')
  }

  revalidatePath('/settings/organization')
  revalidatePath('/')

  redirect('/settings/organization?success=true')
}

export async function updateOrganizationTimezone(timezone: string) {
  if (!timezone || timezone.trim() === '') {
    return { success: false, error: 'Time zone is required' }
  }

  if (!isValidTimeZone(timezone)) {
    return { success: false, error: 'Choose a valid time zone.' }
  }

  const supabase = await createClient()

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) {
    return { success: false, error: 'Not authenticated' }
  }

  const { data: orgId } = await supabase.rpc('current_org_id')
  if (!orgId) {
    return { success: false, error: 'Company not found' }
  }

  const { data: role } = await supabase.rpc('current_role')
  if (role !== 'owner') {
    return { success: false, error: 'Only owners can change the time zone' }
  }

  const { error } = await supabase
    .from('organizations')
    .update({ timezone: timezone.trim() })
    .eq('id', orgId)

  if (error) {
    return { success: false, error: error.message }
  }

  revalidatePath('/settings/organization')
  revalidatePath('/')

  return { success: true }
}

export async function createAPIKey(
  name: string,
  permissions?: { can_read?: boolean; can_write?: boolean; can_post?: boolean }
): Promise<{ success: false; error: string } | { success: true; key: string }> {
  if (!name || name.trim() === '') {
    return { success: false, error: 'Key name is required' }
  }

  try {
    const supabase = await createClient()

    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError || !user) {
      return { success: false, error: 'Not authenticated. Please log in.' }
    }

    // Get active company ID directly from user_settings - NO fallback
    const { data: settings, error: settingsError } = await supabase
      .from('user_settings')
      .select('active_company_id')
      .eq('user_id', user.id)
      .single()

    if (settingsError || !settings || !settings.active_company_id) {
      return { success: false, error: 'No active company selected. Please select a company first.' }
    }

    const orgId = settings.active_company_id

    const { data: role, error: roleError } = await supabase.rpc('current_role')
    if (roleError || !role) {
      return { success: false, error: 'Unable to verify permissions. Please try again.' }
    }

    if (role !== 'owner') {
      return { success: false, error: 'Only owners can create API keys' }
    }

    const plainTextKey = generateAPIKey()
    const keyHash = hashAPIKey(plainTextKey)

    const { data: insertedKey, error: insertError } = await supabase
      .from('api_keys')
      .insert({
        organization_id: orgId,
        name: name.trim(),
        key_hash: keyHash,
        created_by: user.id,
        is_active: true,
        can_read: permissions?.can_read ?? true,
        can_write: permissions?.can_write ?? false,
        can_post: permissions?.can_post ?? false,
      })
      .select()
      .single()

    if (insertError) {
      console.error('API key insert error:', insertError)
      return { 
        success: false, 
        error: `Failed to create API key: ${insertError.message || 'Database error'}` 
      }
    }

    if (!insertedKey) {
      return { success: false, error: 'Key was not created. Please try again.' }
    }

    revalidatePath('/settings/api-keys')

    return { success: true, key: plainTextKey }
  } catch (err) {
    console.error('Unexpected error in createAPIKey:', err)
    return { 
      success: false, 
      error: err instanceof Error ? err.message : 'An unexpected error occurred' 
    }
  }
}

export async function switchCompany(companyId: string): Promise<
  | { success: false; error: string }
  | { success: true }
> {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  
  if (!user) {
    return { success: false, error: 'Not authenticated' }
  }

  const { data, error } = await supabase.rpc('switch_company', {
    p_company_id: companyId
  })

  if (error) {
    return { success: false, error: error.message }
  }

  const result = data as { success: boolean; error?: string }
  if (!result.success) {
    return { success: false, error: result.error || 'Failed to switch company' }
  }

  revalidatePath('/', 'layout')
  return { success: true }
}

export async function createCompany(companyName: string): Promise<
  | { success: false; error: string }
  | { success: true; companyId: string }
> {
  const trimmed = companyName.trim()
  
  if (!trimmed) {
    return { success: false, error: 'Company name is required' }
  }

  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()
  
  if (!user) {
    return { success: false, error: 'Not authenticated' }
  }

  const { data, error } = await supabase.rpc('create_company', {
    p_company_name: trimmed
  })

  if (error) {
    console.error('createCompany RPC error:', error)
    return { success: false, error: error.message || 'Failed to call create_company' }
  }

  if (!data) {
    console.error('createCompany returned no data')
    return { success: false, error: 'No response from create_company' }
  }

  const result = data as { success: boolean; error?: string; detail?: string; company_id?: string }
  
  if (!result.success) {
    console.error('createCompany failed:', result)
    const errorMsg = result.detail 
      ? `${result.error}: ${result.detail}` 
      : (result.error || 'Failed to create company')
    return { success: false, error: errorMsg }
  }

  if (!result.company_id) {
    console.error('createCompany succeeded but no company_id returned:', result)
    return { success: false, error: 'Company created but ID not returned' }
  }

  revalidatePath('/', 'layout')
  return { success: true, companyId: result.company_id }
}
