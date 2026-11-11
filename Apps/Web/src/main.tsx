import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@/ui/index.css";
import { NoServer } from "@/app/NoServer";
import { readConfig } from "@/app/config";

const config = readConfig(import.meta.env as Record<string, string | undefined>, import.meta.env.PROD);

createRoot(document.getElementById("root")!).render(
  <StrictMode>{config ? <p>Soma Flight</p> : <NoServer />}</StrictMode>,
);
