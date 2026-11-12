const COLOR: Record<string, string> = {
  VFR: "var(--sf-vfr)",
  MVFR: "var(--sf-mvfr)",
  IFR: "var(--sf-ifr)",
  LIFR: "var(--sf-lifr)",
};

/** A flight category (VFR, MVFR, IFR, LIFR) in its usual colour, a pill of the colour's own tint. */
export function CategoryChip({ category }: { category: string }) {
  const c = COLOR[category] ?? "var(--sf-secondary)";
  return (
    <span
      className="rounded-full px-1.5 py-0.5 font-mono text-[11px] leading-none font-bold"
      style={{ color: c, background: `color-mix(in srgb, ${c} 16%, transparent)` }}
    >
      {category}
    </span>
  );
}
