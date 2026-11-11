import type { ReactElement } from "react";
import { Navigate, Route, Routes } from "react-router";
import { AirportCard } from "@/screens/airport/AirportCard";
import { AirportsList } from "@/screens/airports/AirportsList";
import { FlightCard } from "@/screens/flight/FlightCard";
import { FriendCard } from "@/screens/friend/FriendCard";
import { Search } from "@/screens/search/Search";
import { Settings } from "@/screens/settings/Settings";
import { SignIn } from "@/screens/sign-in/SignIn";
import { AuthCallback } from "./AuthCallback";
import { AuthGate } from "./AuthGate";
import { takeReturn, useSession } from "./session";
import { Shell } from "./Shell";

function SignInRoute() {
  const { session } = useSession();
  if (session) return <Navigate to={takeReturn()} replace />;
  return <SignIn />;
}

/**
 * The shell as a layout route. The tab roots (`/`, `/friends`, `/passport`) render nothing here: the shell
 * draws the tab's screen itself. Every other child is a card the shell stacks over that tab.
 * `guard` wraps the shell (AuthGate in the app, nothing in tests).
 */
export function shellRoutes(guard: (shell: ReactElement) => ReactElement) {
  return (
    <Route element={guard(<Shell />)}>
      <Route index element={null} />
      <Route path="friends" element={null} />
      <Route path="passport" element={null} />
      <Route path="flight/:id" element={<FlightCard />} />
      <Route path="airport/:code" element={<AirportCard />} />
      <Route path="friend/:id" element={<FriendCard />} />
      <Route path="airports" element={<AirportsList />} />
      <Route path="search" element={<Search />} />
      <Route path="settings/*" element={<Settings />} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Route>
  );
}

export function AppRoutes() {
  return (
    <Routes>
      <Route path="/sign-in" element={<SignInRoute />} />
      <Route path="/auth/callback" element={<AuthCallback />} />
      {shellRoutes((shell) => <AuthGate>{shell}</AuthGate>)}
    </Routes>
  );
}
