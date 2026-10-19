import { getPublicOrigin, llmsTxt } from '@/lib/agent-docs'

export async function GET() {
  const origin = await getPublicOrigin()
  return new Response(llmsTxt(origin), {
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'public, max-age=300',
    },
  })
}
