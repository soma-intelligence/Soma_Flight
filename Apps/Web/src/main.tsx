import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router";
import "@/ui/index.css";
import { NoServer } from "@/app/NoServer";
import { readConfig } from "@/app/config";
import { AppRoutes } from "@/app/routes";

const config = readConfig(import.meta.env as Record<string, string | undefined>, import.meta.env.PROD);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    {config ? (
      <BrowserRouter>
        <AppRoutes />
      </BrowserRouter>
    ) : (
      <NoServer />
    )}
  </StrictMode>,
);
