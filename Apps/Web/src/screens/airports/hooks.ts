import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { fetchFavorites, favoritesKey, setFavorite } from "@/data/airports";
import { useFakes } from "@/data/flights";

/** The signed-in user's favourite airports (ICAO). A failed read leaves `data` undefined. */
export function useFavorites() {
  const fakes = useFakes();
  return useQuery({
    queryKey: favoritesKey,
    queryFn: fetchFavorites,
    staleTime: fakes ? Number.POSITIVE_INFINITY : 60_000,
  });
}

/** Stars or unstars an airport: the cache changes at once and is put back when the write fails. */
export function useToggleFavorite() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ icao, on }: { icao: string; on: boolean }) => setFavorite(icao, on),
    onMutate: ({ icao, on }) => {
      const before = qc.getQueryData<string[]>(favoritesKey);
      const now = before ?? [];
      qc.setQueryData<string[]>(favoritesKey, on ? (now.includes(icao) ? now : [...now, icao]) : now.filter((c) => c !== icao));
      return { before };
    },
    onError: (_e, _v, ctx) => {
      if (ctx) qc.setQueryData(favoritesKey, ctx.before);
    },
  });
}
