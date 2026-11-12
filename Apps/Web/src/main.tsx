import { StrictMode } from "react";
import { QueryClientProvider } from "@tanstack/react-query";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router";
import "@/ui/index.css";
import { NoServer } from "@/app/NoServer";
import { readConfig } from "@/app/config";
import { makeQueryClient } from "@/app/query";
import { AppRoutes } from "@/app/routes";
import { clearCacheOnSignOut } from "@/app/session";
import { applyAppearance } from "@/data/settings";

applyAppearance();

const config = readConfig(import.meta.env as Record<string, string | undefined>, import.meta.env.PROD);
const queryClient = config ? makeQueryClient() : null;
if (queryClient) clearCacheOnSignOut(queryClient);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    {queryClient ? (
      <QueryClientProvider client={queryClient}>
        <BrowserRouter>
          <AppRoutes />
        </BrowserRouter>
      </QueryClientProvider>
    ) : (
      <NoServer />
    )}
  </StrictMode>,
);
