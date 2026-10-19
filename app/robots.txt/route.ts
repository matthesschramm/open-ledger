import { getPublicOrigin } from '@/lib/agent-docs'

export async function GET() {
  const origin = await getPublicOrigin()
  const body = `User-agent: *
Allow: /docs
Allow: /docs.md
Allow: /llms.txt
Allow: /login
Allow: /signup

Sitemap: ${origin}/llms.txt
`
  return new Response(body, {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'public, max-age=3600',
    },
  })
}
