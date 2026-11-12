import { useEffect, useState } from "react";

/** The current time, ticking every `everyMs` (the app's ClockView), so countdowns move on their own. */
export function useNow(everyMs = 30_000): Date {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), everyMs);
    return () => clearInterval(t);
  }, [everyMs]);
  return now;
}
