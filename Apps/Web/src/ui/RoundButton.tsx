import type { ComponentType } from "react";
import "./shell.css";

type IconProps = { size?: number; strokeWidth?: number; "aria-hidden"?: boolean };

/** A round glass button, after RoundButton in FlightKit: 44 px, the icon at 41% of the side. */
export function RoundButton({
  icon: Icon,
  label,
  onClick,
  side = 44,
  className = "",
}: {
  icon: ComponentType<IconProps>;
  label: string;
  onClick: () => void;
  side?: number;
  className?: string;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      onClick={onClick}
      className={`sf-glass flex items-center justify-center rounded-full text-[var(--sf-primary)] ${className}`}
      style={{ width: side, height: side }}
    >
      <Icon size={Math.round(side * 0.41)} strokeWidth={2.2} aria-hidden />
    </button>
  );
}
