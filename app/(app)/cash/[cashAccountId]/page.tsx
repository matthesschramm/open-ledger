import { redirect } from 'next/navigation'

export default async function CashAccountDetailPage({
  params,
}: {
  params: Promise<{ cashAccountId: string }>
}) {
  const { cashAccountId } = await params
  redirect(`/accounts/${cashAccountId}`)
}
