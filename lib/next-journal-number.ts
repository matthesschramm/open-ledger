/**
 * Next JE-YYYY-NNNN for an organization. Prefer max sequence over count so
 * REV/DEP/custom numbers and gaps do not collide with an existing JE number.
 */
export function formatJournalNumber(year: number, sequence: number): string {
  return `JE-${year}-${String(sequence).padStart(4, '0')}`
}

export function nextSequenceFromNumbers(numbers: string[], year: number): number {
  const prefix = `JE-${year}-`
  let max = 0
  for (const number of numbers) {
    if (!number.startsWith(prefix)) continue
    const seq = Number.parseInt(number.slice(prefix.length), 10)
    if (Number.isFinite(seq) && seq > max) max = seq
  }
  return max + 1
}
