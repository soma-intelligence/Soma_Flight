import { QueryClient } from "@tanstack/react-query";

/**
 * The app's TanStack Query client: an in-memory cache only, never persisted (the spec keeps nothing
 * beyond the Supabase session). Lists reload when the window regains focus, as the spec asks; Realtime
 * keeps the followed flights current in between.
 */
export function makeQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: { retry: 1, staleTime: 60_000, refetchOnWindowFocus: true },
      mutations: { retry: false },
    },
  });
}
