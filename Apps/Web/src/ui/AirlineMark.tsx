/**
 * A neutral monogram where the app draws the airline's logo: the airline's code in a grey disc. No airline
 * marks are borrowed; logos come later, if ever, from our own set.
 */
export function AirlineMark({ code, size }: { code: string; size: number }) {
  return (
    <span
      aria-hidden
      className="inline-flex shrink-0 items-center justify-center rounded-full bg-[var(--sf-pill)] font-semibold text-[var(--sf-secondary)]"
      style={{ width: size, height: size, fontSize: Math.round(size * (code.length > 2 ? 0.3 : 0.38)) }}
    >
      {code}
    </span>
  );
}
