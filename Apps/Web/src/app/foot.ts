import { createContext, useContext } from "react";

/**
 * Where the window's bottom edge is in the sheet's content, so the pill stays on it while the sheet moves
 * (the iPhone sheet resizes, the pill never leaves the bottom). Null in the panel, whose foot is its own.
 */
export type Foot = { y: number; transition: string };
export const FootContext = createContext<Foot | null>(null);
export const useFoot = () => useContext(FootContext);
