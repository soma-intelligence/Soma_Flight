import type { ReactNode } from "react";
import { Navigate, useLocation } from "react-router";
import { useFakes } from "@/data/flights";
import { saveReturn, useSession } from "./session";

/** Sends a signed-out visit to /sign-in, remembering the wanted path. Development fakes pass through. */
export function AuthGate({ children }: { children: ReactNode }) {
  const fakes = useFakes();
  if (fakes) return <>{children}</>;
  return <Gate>{children}</Gate>;
}

function Gate({ children }: { children: ReactNode }) {
  const { session, loading } = useSession();
  const location = useLocation();
  if (loading) return <p role="status">Loading</p>;
  if (!session) {
    saveReturn(location.pathname + location.search);
    return <Navigate to="/sign-in" replace />;
  }
  return <>{children}</>;
}
