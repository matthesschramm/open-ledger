export function BrandMark({ size = 32 }: { size?: 28 | 32 }) {
  const box = size === 28 ? 'h-7 w-7 text-[14px]' : 'h-8 w-8 text-[15px]'

  return (
    <span
      aria-hidden
      className={`grid ${box} shrink-0 place-items-center rounded-[7px] bg-primary font-[family-name:var(--serif)] font-medium text-primary-foreground`}
    >
      O
    </span>
  )
}
