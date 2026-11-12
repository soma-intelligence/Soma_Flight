// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { useState } from "react";
import { Dialog, dialogOpen } from "./Dialog";

afterEach(cleanup);

function Host({ onClose = () => {} }: { onClose?: () => void }) {
  const [open, setOpen] = useState(true);
  return (
    <div data-testid="transformed" style={{ transform: "translateY(400px)" }}>
      <button type="button">Opener</button>
      {open && (
        <Dialog
          label="Test dialog"
          onClose={() => {
            onClose();
            setOpen(false);
          }}
        >
          <button type="button">One</button>
          <button type="button" data-autofocus>
            Two
          </button>
        </Dialog>
      )}
    </div>
  );
}

describe("Dialog", () => {
  it("renders in document.body, outside a transformed ancestor", () => {
    render(<Host />);
    const dialog = screen.getByRole("dialog", { name: "Test dialog" });
    expect(screen.getByTestId("transformed").contains(dialog)).toBe(false);
    expect(dialog.closest("body")).toBe(document.body);
    expect(dialog.getAttribute("aria-modal")).toBe("true");
  });

  it("focuses the autofocus control and keeps Tab inside", () => {
    render(<Host />);
    expect(document.activeElement?.textContent).toBe("Two");
    fireEvent.keyDown(window, { key: "Tab" });
    expect(document.activeElement?.textContent).toBe("One");
    fireEvent.keyDown(window, { key: "Tab", shiftKey: true });
    expect(document.activeElement?.textContent).toBe("Two");
  });

  it("closes on Escape and stops the key before any other window listener", () => {
    const other = vi.fn();
    window.addEventListener("keydown", other);
    const onClose = vi.fn();
    render(<Host onClose={onClose} />);
    expect(dialogOpen()).toBe(true);
    fireEvent.keyDown(window, { key: "Escape" });
    window.removeEventListener("keydown", other);
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(other).not.toHaveBeenCalled();
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(dialogOpen()).toBe(false);
  });

  it("closes on a backdrop click, not on a click inside", () => {
    const onClose = vi.fn();
    render(<Host onClose={onClose} />);
    fireEvent.click(screen.getByText("One"));
    expect(onClose).not.toHaveBeenCalled();
    fireEvent.click(screen.getByTestId("dialog-backdrop"));
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
