import { useMutation, useQuery } from "@tanstack/react-query";
import { Check, ChevronRight, Copy, Link as LinkIcon, Send } from "lucide-react";
import { useMemo, useState } from "react";
import { useShellNav } from "@/app/nav";
import {
  createInvite,
  fetchFriendFlights,
  fetchFriends,
  fetchFriendsMe,
  friendFlightsKey,
  friendName,
  friendsKey,
  friendsMeKey,
  spacedCode,
  type Friend,
  type FriendFlight,
} from "@/data/friends";
import { useAirports } from "@/ui/airports";
import { ErrorBanner } from "@/ui/ErrorBanner";
import { errorCode, errorCopy } from "@/ui/errorCopy";
import { JetIllustration } from "@/ui/JetIllustration";
import { useNow } from "@/ui/useNow";
import { TabTitle } from "../placeholder";
import { EMPTY_TEXT, EMPTY_TITLE, SECTION_TITLE, route, sections, since, upcomingFlight, when, type Tone } from "./facts";
import { FriendAvatar } from "./FriendAvatar";

const TONE: Record<Tone, string> = {
  "on-time": "var(--sf-on-time)",
  "very-late": "var(--sf-very-late)",
  diverted: "var(--sf-diverted)",
  secondary: "var(--sf-secondary)",
};

type Copied = "link" | "code" | null;

/**
 * Makes a single-use invitation link and puts it on the clipboard. Where the browser refuses the clipboard
 * the link stays on screen to copy by hand.
 */
function useInviteLink() {
  const [copied, setCopied] = useState<Copied>(null);
  const [shown, setShown] = useState<string | null>(null);
  const m = useMutation({
    mutationFn: async () => {
      const invite = await createInvite();
      setShown(null);
      try {
        await navigator.clipboard.writeText(invite.url);
        setCopied("link");
      } catch {
        setCopied(null);
        setShown(invite.url);
      }
    },
  });
  return { copied, setCopied, shown, make: () => m.mutate(), pending: m.isPending, error: m.error };
}

/** The Friends tab, after FriendsView: the user's friend code and invitation link, then friends in three groups. */
export function Friends() {
  const nav = useShellNav();
  const now = useNow();
  const airport = useAirports();
  const me = useQuery({ queryKey: friendsMeKey, queryFn: fetchFriendsMe });
  const friends = useQuery({ queryKey: friendsKey, queryFn: fetchFriends });
  const flights = useQuery({ queryKey: friendFlightsKey(null), queryFn: () => fetchFriendFlights(null) });
  const invite = useInviteLink();

  const list: Friend[] = friends.data ?? [];
  const all: FriendFlight[] = flights.data ?? [];
  const groups = useMemo(() => sections(list, all), [list, all]);
  const failure = friends.error ?? invite.error;

  async function copyCode() {
    if (!me.data) return;
    try {
      await navigator.clipboard.writeText(me.data.friendCode);
      invite.setCopied("code");
    } catch {
      /* clipboard blocked: the code is on screen */
    }
  }

  return (
    <div>
      <TabTitle>Friends</TabTitle>
      <div className="px-4 pb-6">
        {me.data && (
          <section aria-label="Your friend code" className="mb-[14px] rounded-[18px] bg-[var(--sf-card)] px-4 py-3">
            <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-2.5">
              <div>
                <p className="text-[13px] text-[var(--sf-secondary)] uppercase">Your friend code</p>
                <p aria-label={`Friend code ${me.data.friendCode.split("").join(" ")}`} className="text-[22px] font-semibold tracking-[0.08em] whitespace-nowrap text-[var(--sf-primary)] tabular-nums">
                  {spacedCode(me.data.friendCode)}
                </p>
              </div>
              <div className="flex flex-wrap gap-2">
                <PillButton onClick={() => void copyCode()} icon={invite.copied === "code" ? Check : Copy}>
                  {invite.copied === "code" ? "Copied" : "Copy Code"}
                </PillButton>
                <PillButton onClick={invite.make} icon={invite.copied === "link" ? Check : LinkIcon} disabled={invite.pending}>
                  {invite.copied === "link" ? "Link Copied" : "Copy Invitation Link"}
                </PillButton>
              </div>
            </div>
            <p className="pt-1.5 text-[13px] text-[var(--sf-secondary)]">Each link works once, for 7 days.</p>
            {invite.shown && (
              <p role="status" className="pt-1.5 text-[13px] break-all text-[var(--sf-primary)]">
                Couldn't copy it. Here is your link: {invite.shown}
              </p>
            )}
          </section>
        )}
        <p role="status" aria-live="polite" className="sr-only">
          {invite.copied === "link" ? "Invitation link copied" : invite.copied === "code" ? "Friend code copied" : ""}
        </p>
        {failure != null && (
          <div className="pb-[14px]">
            <ErrorBanner
              message={errorCopy(errorCode(failure))}
              onRetry={friends.error ? () => void friends.refetch() : undefined}
            />
          </div>
        )}
        {friends.isPending ? (
          <div role="status" aria-label="Loading your friends" className="flex min-h-[200px] items-center justify-center">
            <span className="size-6 animate-spin rounded-full border-2 border-[var(--sf-separator)] border-t-[var(--sf-secondary)]" />
          </div>
        ) : list.length === 0 ? (
          friends.error ? null : (
            <div data-testid="friends-empty" className="flex flex-col items-center gap-1.5 py-6 text-center">
              <div className="w-full py-3 pb-[22px]">
                <JetIllustration width={240} />
              </div>
              <h2 className="text-[20px] font-semibold text-[var(--sf-primary)]">{EMPTY_TITLE}</h2>
              <p className="text-[15px] text-[var(--sf-secondary)]">{EMPTY_TEXT}</p>
              <button
                type="button"
                onClick={invite.make}
                disabled={invite.pending}
                className="mt-2.5 flex items-center gap-1.5 rounded-full bg-[var(--sf-accent)] px-5 py-[10px] text-[15px] font-semibold text-white disabled:opacity-60"
              >
                <Send size={15} strokeWidth={2.4} aria-hidden />
                Invite a Friend
              </button>
            </div>
          )
        ) : (
          groups.map((g) => (
            <section key={g.id} aria-label={SECTION_TITLE[g.id]} className="pb-[14px]">
              <h2 className="flex justify-between pt-1.5 pb-1 text-[13px] text-[var(--sf-secondary)] uppercase">
                <span>{SECTION_TITLE[g.id]}</span>
                <span>{g.friends.length === 1 ? "1 friend" : `${g.friends.length} friends`}</span>
              </h2>
              {g.friends.map((f) => {
                const next = upcomingFlight(all, f.id);
                const w = next ? when(next, now) : null;
                return (
                  <button
                    key={f.id}
                    type="button"
                    data-testid="friend-row"
                    onClick={() => nav.open(`/friend/${f.id}`)}
                    className="flex w-full items-center gap-[14px] border-b border-[var(--sf-separator)] py-3 text-left"
                  >
                    <FriendAvatar id={f.id} name={f.displayName} emoji={f.emoji} />
                    <span className="flex min-w-0 flex-1 flex-col gap-[3px]">
                      <span className="truncate text-[17px] font-semibold text-[var(--sf-primary)]">{friendName(f)}</span>
                      {next && w ? (
                        <>
                          <span className="truncate text-[15px] text-[var(--sf-secondary)]">{route(next, airport)}</span>
                          <span className="flex items-center gap-1.5 text-[15px] font-medium" style={{ color: TONE[w.tone] }}>
                            <span aria-hidden className="size-[7px] rounded-full" style={{ background: TONE[w.tone] }} />
                            {w.text}
                          </span>
                        </>
                      ) : (
                        <span className="truncate text-[15px] text-[var(--sf-secondary)]">
                          {f.sharesFlights ? since(f.since) : "Not sharing flights with you"}
                        </span>
                      )}
                    </span>
                    <ChevronRight size={16} strokeWidth={2.4} aria-hidden className="shrink-0 text-[var(--sf-secondary)]" />
                  </button>
                );
              })}
            </section>
          ))
        )}
      </div>
    </div>
  );
}

function PillButton({
  onClick,
  icon: Icon,
  disabled,
  children,
}: {
  onClick: () => void;
  icon: typeof Copy;
  disabled?: boolean;
  children: string;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className="flex items-center gap-1.5 rounded-full bg-[var(--sf-pill)] px-3 py-[7px] text-[14px] font-semibold whitespace-nowrap text-[var(--sf-primary)] disabled:opacity-60"
    >
      <Icon size={14} strokeWidth={2.4} aria-hidden />
      {children}
    </button>
  );
}
