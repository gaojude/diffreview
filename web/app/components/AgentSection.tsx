"use client";

import { useEffect, useRef, useState } from "react";

export default function AgentSection() {
  const ref = useRef<HTMLElement | null>(null);
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    if (typeof IntersectionObserver === "undefined") {
      setVisible(true);
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            setVisible(true);
            io.disconnect();
            break;
          }
        }
      },
      { threshold: 0.15 }
    );
    io.observe(node);
    return () => io.disconnect();
  }, []);

  return (
    <section
      ref={ref}
      aria-labelledby="agent-section-heading"
      className="w-full max-w-2xl mt-28 mx-auto"
    >
      <div className={visible ? "animate-fade-in-up" : "opacity-0"}>
        <div className="flex items-center gap-3">
          <span className="inline-flex items-center px-2 py-0.5 rounded-full text-[10px] font-semibold tracking-wider uppercase border border-[var(--color-accent)] text-[var(--color-accent)] bg-[rgba(255,92,92,0.08)]">
            The loop
          </span>
          <h2
            id="agent-section-heading"
            className="text-xl md:text-2xl font-semibold tracking-tight"
          >
            Close the loop with your coding agent
          </h2>
        </div>

        <p className="mt-4 text-[var(--color-text-dim)] text-sm md:text-base leading-relaxed">
          AI can generate a whole project in one shot — but somebody still has
          to read it. Redline makes the reading round-trip: you review the
          branch, drop comments across as many files as you like, and export
          the whole review as one{" "}
          <span className="text-[var(--color-text)]">prompt-ready block</span>{" "}
          — file paths, line numbers, and the code in question included.
        </p>

        <ol className="mt-8 flex flex-col gap-5">
          <li className="flex gap-4">
            <span
              aria-hidden
              className="flex-shrink-0 w-6 h-6 rounded-full border border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-accent)] text-xs flex items-center justify-center font-semibold"
            >
              1
            </span>
            <div className="text-sm md:text-base leading-relaxed">
              <div className="text-[var(--color-text)]">
                Let your agent build the branch.
              </div>
              <div className="text-[var(--color-text-dim)] mt-1">
                Claude Code (or any coding agent) writes the feature. You
                don&apos;t review streaming tool calls — you review the diff.
              </div>
            </div>
          </li>

          <li className="flex gap-4">
            <span
              aria-hidden
              className="flex-shrink-0 w-6 h-6 rounded-full border border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-accent)] text-xs flex items-center justify-center font-semibold"
            >
              2
            </span>
            <div className="text-sm md:text-base leading-relaxed">
              <div className="text-[var(--color-text)]">
                Run{" "}
                <span className="font-mono text-[var(--color-accent)]">
                  redline .
                </span>{" "}
                and review it like a pull request.
              </div>
              <div className="text-[var(--color-text-dim)] mt-1">
                Every change on the branch is one scrolling document. Check
                files off as Reviewed, jump hunk to hunk, and press ⌘K to
                comment on exact lines.
              </div>
            </div>
          </li>

          <li className="flex gap-4">
            <span
              aria-hidden
              className="flex-shrink-0 w-6 h-6 rounded-full border border-[var(--color-border)] bg-[var(--color-surface)] text-[var(--color-accent)] text-xs flex items-center justify-center font-semibold"
            >
              3
            </span>
            <div className="text-sm md:text-base leading-relaxed">
              <div className="text-[var(--color-text)]">
                Copy the review. Paste it into your agent. Repeat.
              </div>
              <div className="text-[var(--color-text-dim)] mt-1">
                The sidebar collects every comment; one Copy turns them all
                into a single prompt. Your agent applies the fixes, and the
                next round of review starts on a fresh diff.
              </div>
            </div>
          </li>
        </ol>

        <pre
          aria-label="The review loop"
          className="mt-8 bg-[var(--color-surface)] border border-[var(--color-border)] rounded-lg px-4 py-3 text-[11px] md:text-xs text-[var(--color-text-dim)] leading-relaxed overflow-x-auto"
        >
{`┌────────────┐    writes branch     ┌─────────────────┐
│ your agent │ ───────────────────▶ │   redline .     │
│            │                      │ ☑ files reviewed│
│  applies   │ ◀─────────────────── │ ⌘K line comments│
│  the fixes │   one prompt block   └─────────────────┘
└────────────┘`}
        </pre>
      </div>
    </section>
  );
}
