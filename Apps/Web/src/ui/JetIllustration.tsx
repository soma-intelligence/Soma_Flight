/**
 * The empty state's climbing white trijet, redrawn as SVG after EmptyStateIllustration (variant climb):
 * seen three-quarters from the front, climbing to the right, a soft shadow under it, floating gently
 * (still under Reduce Motion). Decorative: the text under it speaks.
 */
export function JetIllustration({ width = 240 }: { width?: number }) {
  return (
    <svg
      data-testid="empty-jet"
      aria-hidden
      viewBox="0 0 300 143"
      width={width}
      height={Math.round((width * 143) / 300)}
      className="sf-jet-float mx-auto block"
      style={{ filter: "drop-shadow(0 12px 14px var(--sf-jet-shadow, rgba(0,0,0,0.14)))", overflow: "visible" }}
    >
      <style>{`
        .sf-jet-float { animation: sf-jet-float 3.2s ease-in-out infinite alternate; }
        @keyframes sf-jet-float { from { transform: translateY(4px); } to { transform: translateY(-4px); } }
        @media (prefers-reduced-motion: reduce) { .sf-jet-float { animation: none; } }
        @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) .sf-jet-float { --sf-jet-shadow: rgba(0,0,0,0.5); } }
        :root[data-theme="dark"] .sf-jet-float { --sf-jet-shadow: rgba(0,0,0,0.5); }
      `}</style>
      <defs>
        <linearGradient id="sf-jet-body" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#FFFFFF" />
          <stop offset="0.55" stopColor="#F1F2F5" />
          <stop offset="1" stopColor="#C9CCD3" />
        </linearGradient>
        <linearGradient id="sf-jet-wing" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#F4F5F8" />
          <stop offset="1" stopColor="#BFC3CB" />
        </linearGradient>
        <linearGradient id="sf-jet-engine" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#FFFFFF" />
          <stop offset="1" stopColor="#B9BDC6" />
        </linearGradient>
      </defs>
      {/* Far wing, mostly behind the body. */}
      <path d="M150 55 L118 40 L126 40 L170 50 Z" fill="#D5D8DE" />
      {/* Fin and tailplane. */}
      <path d="M66 66 L46 6 Q47 3 51 3 L62 4 L100 58 Z" fill="url(#sf-jet-wing)" />
      <path d="M62 56 L14 60 Q10 62 14 65 L74 66 Z" fill="#D9DCE2" />
      {/* Fuselage, climbing to the nose. */}
      <path
        d="M60 72 C90 58 196 30 258 21 C276 18 293 22 294 29 C294 36 278 42 256 47 C198 60 112 84 76 90 C62 92 52 82 60 72 Z"
        fill="url(#sf-jet-body)"
      />
      {/* Near wing, swept down toward the viewer. */}
      <path d="M156 64 L40 132 Q36 137 44 138 L58 138 L196 74 Z" fill="url(#sf-jet-wing)" />
      <path d="M40 132 L34 124 L42 124 L48 128 Z" fill="#C3C7CF" />
      {/* Rear engines. */}
      <g transform="rotate(-14 98 46)">
        <ellipse cx="98" cy="46" rx="19" ry="9" fill="url(#sf-jet-engine)" />
        <ellipse cx="116" cy="46" rx="3.5" ry="8" fill="#3A3D44" />
      </g>
      <g transform="rotate(-14 116 70)">
        <ellipse cx="116" cy="70" rx="21" ry="10.5" fill="url(#sf-jet-engine)" />
        <ellipse cx="136" cy="70" rx="4" ry="9.5" fill="#33363C" />
      </g>
      {/* Cabin windows and the cockpit. */}
      <g fill="#4A4E57">
        {Array.from({ length: 11 }, (_, i) => {
          const x = 150 + i * 9;
          const y = 61.5 - i * 2.05;
          return <ellipse key={i} cx={x} cy={y} rx="2" ry="2.6" transform={`rotate(-14 ${x} ${y})`} />;
        })}
      </g>
      <path d="M262 25 L280 22 Q284 23 282 27 L264 31 Z" fill="#2E3138" />
    </svg>
  );
}
