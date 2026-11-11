export type Config = { url: string; key: string };

const LOCAL_HTTP = /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?(\/|$)/;

/** Fail closed: in production anything short of https URL plus key is null. */
export function readConfig(
  env: Record<string, string | undefined>,
  prod: boolean,
): Config | null {
  const url = env.VITE_SUPABASE_URL?.trim();
  const key = env.VITE_SUPABASE_PUBLISHABLE_KEY?.trim();
  if (!url || !key) return null;
  if (url.startsWith("https://")) return { url, key };
  if (!prod && LOCAL_HTTP.test(url)) return { url, key };
  return null;
}
