import { agentDocsMarkdown, getPublicOrigin } from '@/lib/agent-docs'

export async function GET() {
  const origin = await getPublicOrigin()
  return new Response(agentDocsMarkdown(origin), {
    headers: {
      'Content-Type': 'text/markdown; charset=utf-8',
      'Cache-Control': 'public, max-age=300',
    },
  })
}
