import { useParams } from "react-router";
import { CardFrame } from "../placeholder";

/** Placeholder until the flight detail task. */
export function FlightCard() {
  const { id } = useParams();
  return (
    <CardFrame title="Flight" testId="flight-card">
      <p className="px-5 text-[15px] text-[var(--sf-secondary)]">{id}</p>
    </CardFrame>
  );
}
