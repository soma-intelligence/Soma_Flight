import { QueryClient } from "@tanstack/react-query";

/**
 * The app's TanStack Query client: an in-memory cache only, never persisted (the spec keeps nothing
 * beyond the Supabase session). Realtime keeps the followed flights current, so focus does not refetch.
 */
export function makeQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: { retry: 1, staleTime: 60_000, refetchOnWindowFocus: false },
      mutations: { retry: false },
    },
  });
}
