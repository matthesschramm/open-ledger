export const AUTH_HASH_TYPES = new Set([
  'invite',
  'recovery',
  'signup',
  'magiclink',
  'email',
])

export function getAuthHash(hash = typeof window === 'undefined' ? '' : window.location.hash) {
  if (!hash.startsWith('#')) return null
  const params = new URLSearchParams(hash.slice(1))
  const accessToken = params.get('access_token')
  const refreshToken = params.get('refresh_token')
  const type = params.get('type')
  if (!accessToken || !refreshToken || !type || !AUTH_HASH_TYPES.has(type)) {
    return null
  }
  return { accessToken, refreshToken, type, hash }
}

export const AUTH_HASH_REDIRECT_SCRIPT = `(function(){var h=location.hash;if(!h||h.indexOf('access_token=')===-1)return;if(location.pathname==='/set-password')return;var p=new URLSearchParams(h.slice(1));if(!p.get('access_token')||!p.get('type'))return;location.replace('/set-password'+h);})();`
