'use client'

import { useEffect } from 'react'
import { getAuthHash } from '@/lib/auth-hash'

export function AuthHashRedirect() {
  useEffect(() => {
    const authHash = getAuthHash()
    if (!authHash) return
    if (window.location.pathname === '/set-password') return
    window.location.replace(`/set-password${authHash.hash}`)
  }, [])

  return null
}
