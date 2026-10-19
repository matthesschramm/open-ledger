import type { SupabaseClient } from '@supabase/supabase-js'

/**
 * Type for tracking inserted rows that need cleanup on failure
 */
type InsertedRow = {
  table: string
  id: string
}

/**
 * Guarded posting helper that checks period lock before any inserts,
 * tracks all inserted rows, and cleans them up on any failure.
 * 
 * Usage:
 * ```typescript
 * await guardedPost(supabase, orgId, entryDate, async (track) => {
 *   const { data: doc } = await supabase.from('bills').insert({...}).select().single()
 *   track('bills', doc.id)
 *   
 *   const { data: journal } = await supabase.from('journals').insert({...}).select().single()
 *   track('journals', journal.id)
 *   
 *   // ... more inserts
 *   
 *   // Post journal (this may fail with period lock error)
 *   const { data: result, error } = await supabase.rpc('post_journal', {...})
 *   if (error) throw error
 *   if (!result?.success) throw new Error(result?.error || 'Post failed')
 * })
 * ```
 * 
 * @param supabase - Supabase client (client or service)
 * @param organizationId - Organization UUID
 * @param date - Entry date to check (YYYY-MM-DD)
 * @param userId - Optional user ID (for service role calls)
 * @param steps - Async function that performs the inserts and post
 * @throws Error with server message if period is locked or any step fails
 */
export async function guardedPost(
  supabase: SupabaseClient,
  organizationId: string,
  date: string,
  userId: string | null | undefined,
  steps: (track: (table: string, id: string) => void) => Promise<void>
): Promise<void> {
  const inserted: InsertedRow[] = []

  // Check period lock BEFORE any inserts
  const { data: checkResult, error: checkError } = await supabase.rpc('check_period_open', {
    p_organization_id: organizationId,
    p_date: date,
    p_user_id: userId || null,
  })

  if (checkError) {
    throw new Error(checkError.message || 'Failed to check period')
  }

  if (!checkResult?.ok) {
    // Period is locked - throw error with server message
    throw new Error(checkResult?.message || 'This date is in a locked period.')
  }

  // Track function that records inserted rows
  const track = (table: string, id: string) => {
    inserted.push({ table, id })
  }

  try {
    // Execute the posting steps
    await steps(track)
  } catch (error: any) {
    // On any failure, clean up all inserted rows in reverse order
    // But ONLY if they're still in Draft status (haven't been posted yet)
    
    if (inserted.length > 0) {
      for (let i = inserted.length - 1; i >= 0; i--) {
        const row = inserted[i]
        try {
          // For journals, only delete if still Draft (not Posted)
          if (row.table === 'journals') {
            const { data: journal } = await supabase
              .from('journals')
              .select('status')
              .eq('id', row.id)
              .single()
            
            if (journal?.status === 'Draft') {
              const { error: deleteError } = await supabase
                .from(row.table)
                .delete()
                .eq('id', row.id)
              
              if (deleteError) {
                console.error(`Failed to cleanup ${row.table} ${row.id}:`, deleteError.message)
              }
            }
          } else if (row.table === 'bills') {
            // For bills, only delete if still Draft (not Posted/Paid)
            const { data: bill } = await supabase
              .from('bills')
              .select('status')
              .eq('id', row.id)
              .single()
            
            if (bill?.status === 'Draft') {
              const { error: deleteError } = await supabase
                .from(row.table)
                .delete()
                .eq('id', row.id)
              
              if (deleteError) {
                console.error(`Failed to cleanup ${row.table} ${row.id}:`, deleteError.message)
              }
            }
          } else {
            // For non-journal rows (lines, etc), attempt cleanup
            const { error: deleteError} = await supabase
              .from(row.table)
              .delete()
              .eq('id', row.id)
            
            if (deleteError) {
              console.error(`Failed to cleanup ${row.table} ${row.id}:`, deleteError.message)
            }
          }
        } catch (cleanupError: any) {
          console.error(`Failed to cleanup ${row.table} ${row.id}:`, cleanupError.message || cleanupError)
        }
      }
    }

    // Re-throw with user-friendly message
    // For lock errors, show only the lock message; for others, generic message
    if (error.message?.includes('locked period') || error.message?.includes('PERIOD_LOCKED')) {
      throw new Error(error.message)
    } else {
      console.error('Post error:', error.message)
      throw new Error('Couldn\'t post. Some draft rows may need tidying.')
    }
  }
}
