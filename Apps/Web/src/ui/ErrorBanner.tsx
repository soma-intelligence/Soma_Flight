/** The app's error banner: a red dot, the message, and Try again when there is a retry (ErrorBanner.swift). */
export function ErrorBanner({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div
      role="alert"
      className="flex items-center gap-3 rounded-[18px] border border-[var(--sf-issues-rim)] bg-[var(--sf-issues)] px-[14px] py-3"
    >
      <span aria-hidden className="relative flex size-5 shrink-0 items-center justify-center">
        <span className="absolute inset-0 rounded-full bg-[var(--sf-very-late)] opacity-[0.22]" />
        <span className="size-[9px] rounded-full bg-[var(--sf-very-late)]" />
      </span>
      <p className="min-w-0 flex-1 text-[15px] text-[var(--sf-primary)] opacity-90">{message}</p>
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="shrink-0 rounded-full bg-[color-mix(in_srgb,var(--sf-primary)_12%,transparent)] px-3 py-1.5 text-[15px] font-semibold text-[var(--sf-primary)]"
        >
          Try again
        </button>
      )}
    </div>
  );
}
