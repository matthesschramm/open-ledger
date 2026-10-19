import Link from 'next/link'
import { BrandMark } from '@/components/app/brand-mark'
import { agentDocsMarkdown, getPublicOrigin } from '@/lib/agent-docs'

export const metadata = {
  title: 'Open Ledger API and MCP',
  description: 'Public API and MCP documentation for Open Ledger agents',
}

function renderMarkdown(markdown: string) {
  const blocks = markdown.trim().split(/\n\n+/)
  return blocks.map((block, i) => {
    if (block.startsWith('```')) {
      const lines = block.split('\n')
      const body = lines.slice(1, lines[lines.length - 1] === '```' ? -1 : undefined).join('\n')
      return (
        <pre key={i} className="overflow-x-auto rounded-[10px] bg-navy px-4 py-3 font-mono text-xs text-paper">
          {body}
        </pre>
      )
    }
    if (block.startsWith('# ')) {
      return (
        <h1 key={i} className="text-[clamp(1.9rem,3vw,2.9rem)]">
          {block.slice(2)}
        </h1>
      )
    }
    if (block.startsWith('## ')) {
      return (
        <h2 key={i} className="mt-10 text-[clamp(1.35rem,2.1vw,2rem)]">
          {block.slice(3)}
        </h2>
      )
    }
    if (block.startsWith('### ')) {
      return (
        <h3 key={i} className="mt-6 text-[1.05rem]">
          {block.slice(4)}
        </h3>
      )
    }
    if (block.startsWith('- ')) {
      return (
        <ul key={i} className="list-disc space-y-1 pl-5 text-sm text-ink-soft">
          {block.split('\n').map((line, j) => (
            <li key={j}>{line.replace(/^- /, '')}</li>
          ))}
        </ul>
      )
    }
    return (
      <p key={i} className="text-sm leading-[1.7] text-ink-soft whitespace-pre-wrap">
        {block}
      </p>
    )
  })
}

export default async function DocsPage() {
  const origin = await getPublicOrigin()
  const markdown = agentDocsMarkdown(origin)

  return (
    <main className="min-h-screen bg-background">
      <div className="mx-auto max-w-[730px] px-6 py-12">
        <div className="mb-8 flex items-center gap-2.5">
          <BrandMark size={28} />
          <p className="font-sans text-[0.95rem] font-semibold tracking-[-0.02em]">Open Ledger</p>
        </div>
        <p className="page-kicker">Reference</p>
        <p className="mb-8 font-mono text-[0.58rem] font-semibold uppercase tracking-[0.08em] text-muted-foreground">
          <Link href="/login" className="hover:text-foreground">
            Sign in
          </Link>
          {' · '}
          <Link href="/docs.md" className="hover:text-foreground">
            Raw markdown
          </Link>
          {' · '}
          <Link href="/llms.txt" className="hover:text-foreground">
            llms.txt
          </Link>
        </p>
        <article className="space-y-4">{renderMarkdown(markdown)}</article>
      </div>
    </main>
  )
}
