import { friendInitials } from "@/data/friends";

const TONES = ["--sf-friend", "--sf-accent", "--sf-diverted", "--sf-late", "--sf-on-time", "--sf-mvfr"];

/** The same soft colour for a friend on every visit (after FriendAvatarText.tone). */
function toneOf(id: string): string {
  let h = 0;
  for (const c of id) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return `var(${TONES[h % TONES.length]})`;
}

/** A friend's round mark: their emoji, else their initials, on a soft colour of their own. Decorative. */
export function FriendAvatar({ id, name, emoji, size = 46 }: { id: string; name: string | null; emoji: string | null; size?: number }) {
  const tone = toneOf(id);
  return (
    <span
      aria-hidden
      className="flex shrink-0 items-center justify-center rounded-full font-semibold"
      style={{
        width: size,
        height: size,
        background: `color-mix(in srgb, ${tone} 20%, transparent)`,
        color: tone,
        fontSize: Math.round(size * (emoji ? 0.52 : 0.38)),
      }}
    >
      {emoji ? emoji : friendInitials(name)}
    </span>
  );
}
