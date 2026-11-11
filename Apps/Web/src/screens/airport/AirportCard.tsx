import { useParams } from "react-router";
import { CardFrame } from "../placeholder";

/** Placeholder until the airport task. */
export function AirportCard() {
  const { code } = useParams();
  return <CardFrame title={(code ?? "").toUpperCase()} testId="airport-card" />;
}
