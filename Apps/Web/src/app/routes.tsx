import { Navigate, Route, Routes } from "react-router";
import { AuthCallback } from "./AuthCallback";
import { AuthGate } from "./AuthGate";
import { takeReturn, useSession } from "./session";
import { SignIn } from "@/screens/sign-in/SignIn";

function SignInRoute() {
  const { session } = useSession();
  if (session) return <Navigate to={takeReturn()} replace />;
  return <SignIn />;
}

/** Task 7 replaces the placeholder with the app shell. */
function Protected() {
  return <p>Soma Flight</p>;
}

export function AppRoutes() {
  return (
    <Routes>
      <Route path="/sign-in" element={<SignInRoute />} />
      <Route path="/auth/callback" element={<AuthCallback />} />
      <Route
        path="*"
        element={
          <AuthGate>
            <Protected />
          </AuthGate>
        }
      />
    </Routes>
  );
}
