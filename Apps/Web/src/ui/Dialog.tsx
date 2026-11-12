import { useEffect, useRef, type ReactNode, type RefObject } from "react";
import { createPortal } from "react-dom";

const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

/** The open dialogs, newest last: only the top one answers the keyboard. */
const stack: object[] = [];

/** True while any dialog is open (the shell's own keys stand down then). */
export function dialogOpen(): boolean {
  return stack.length > 0;
}

function focusables(root: HTMLElement): HTMLElement[] {
  return [...root.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((el) => !el.hasAttribute("inert"));
}

/**
 * A modal dialog over the whole window. It renders in `document.body` (a portal), so a transformed
 * ancestor such as the narrow sheet can never move it off screen, and focusing its fields never scrolls
 * the shell. Focus moves in on open (to `initialFocus`, else the first `autofocus` control, else the first
 * control), stays inside on Tab and returns to where it was on close. Escape closes this dialog only: the
 * key is stopped before the shell sees it, so the card under it stays open. A click on the dim backdrop
 * closes it too unless `dismissOnBackdrop` is false.
 */
export function Dialog({
  role = "dialog",
  label,
  labelledBy,
  describedBy,
  onClose,
  initialFocus,
  dismissOnBackdrop = true,
  align = "bottom",
  className,
  children,
}: {
  role?: "dialog" | "alertdialog";
  label?: string;
  labelledBy?: string;
  describedBy?: string;
  onClose: () => void;
  initialFocus?: RefObject<HTMLElement | null>;
  dismissOnBackdrop?: boolean;
  /** Where the dialog sits in a narrow window; from 640 px it is always centred. */
  align?: "bottom" | "center";
  className?: string;
  children: ReactNode;
}) {
  const panel = useRef<HTMLDivElement>(null);
  const close = useRef(onClose);
  close.current = onClose;

  useEffect(() => {
    const token = {};
    stack.push(token);
    const before = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const root = panel.current!;
    const first =
      initialFocus?.current ?? root.querySelector<HTMLElement>("[autofocus], [data-autofocus]") ?? focusables(root)[0] ?? root;
    first.focus({ preventScroll: true });

    // Capture phase on the window: this runs before any other key listener, so stopping the event here
    // keeps the shell's Escape (close the card) from seeing it.
    function onKey(e: KeyboardEvent) {
      if (stack[stack.length - 1] !== token) return;
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        close.current();
        return;
      }
      if (e.key !== "Tab") return;
      const items = focusables(root);
      if (items.length === 0) {
        e.preventDefault();
        root.focus({ preventScroll: true });
        return;
      }
      const at = document.activeElement;
      const head = items[0];
      const tail = items[items.length - 1];
      if (!root.contains(at)) {
        e.preventDefault();
        (e.shiftKey ? tail : head).focus({ preventScroll: true });
      } else if (e.shiftKey && at === head) {
        e.preventDefault();
        tail.focus({ preventScroll: true });
      } else if (!e.shiftKey && at === tail) {
        e.preventDefault();
        head.focus({ preventScroll: true });
      }
    }
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("keydown", onKey, true);
      const i = stack.indexOf(token);
      if (i >= 0) stack.splice(i, 1);
      if (before && before.isConnected) before.focus({ preventScroll: true });
    };
    // Focus moves once per opening; a new onClose each render must not move it again.
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  return createPortal(
    <div
      data-testid="dialog-backdrop"
      className={`fixed inset-0 z-[1000] flex justify-center overflow-y-auto bg-black/40 p-4 sm:items-center ${
        align === "center" ? "items-center" : "items-end"
      }`}
      onClick={dismissOnBackdrop ? () => close.current() : undefined}
    >
      <div
        ref={panel}
        role={role}
        aria-modal="true"
        aria-label={label}
        aria-labelledby={labelledBy}
        aria-describedby={describedBy}
        tabIndex={-1}
        onClick={(e) => e.stopPropagation()}
        className={`outline-none ${className ?? ""}`}
      >
        {children}
      </div>
    </div>,
    document.body,
  );
}
