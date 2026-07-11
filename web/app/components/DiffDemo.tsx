"use client";

import { useEffect, useState } from "react";

// The whole loop as one scripted scene, told for people who've never used a review
// tool: (1) an agent generates the feature branch, (2) you read the diff and drop
// comments across several files while the sidebar collects them, (3) one Copy sends
// the review to the agent as a prompt, (4) fixes land — next round.
const COMMENTS = [
  {
    path: "src/lib/checkout.ts",
    line: 13,
    text: "totals must come from the server — cart state can be stale",
  },
  {
    path: "src/components/PaymentForm.tsx",
    line: 25,
    text: "remove this log — it prints full card details",
  },
  {
    path: "src/api/cart.ts",
    line: 41,
    text: "debounce this — it calls the API on every keystroke",
  },
] as const;

const BUILD_LINES = [
  { cls: "at-cmd", text: '$ claude "build the checkout flow"' },
  { cls: "at-dim", text: "✻ Writing code…" },
  { cls: "at-ok", text: "✓ 14 files changed on feature/checkout-flow" },
];

const AGENT_LINES = [
  { cls: "at-cmd", text: "$ claude" },
  { cls: "at-prompt", text: "> Apply the following 3 code review comments:" },
  { cls: "at-dim", text: `  checkout.ts:13 — ${COMMENTS[0].text}` },
  { cls: "at-dim", text: `  PaymentForm.tsx:25 — ${COMMENTS[1].text}` },
  { cls: "at-dim", text: `  cart.ts:41 — ${COMMENTS[2].text}` },
  { cls: "at-dim", text: "✻ Applying fixes…" },
  { cls: "at-ok", text: "✓ 3 files changed — ready for your next review" },
];

type Phase =
  | "build"
  | "diff"
  | "select1"
  | "type1"
  | "commit1"
  | "scroll2"
  | "select2"
  | "type2"
  | "commit2"
  | "scroll3"
  | "select3"
  | "commit3"
  | "copy"
  | "toast"
  | "agent"
  | "done";

const TIMELINE: Array<[Phase, number]> = [
  ["build", BUILD_LINES.length * 520 + 900],
  ["diff", 1500],
  ["select1", 750],
  ["type1", COMMENTS[0].text.length * 26 + 500],
  ["commit1", 1000],
  ["scroll2", 800],
  ["select2", 700],
  ["type2", COMMENTS[1].text.length * 26 + 500],
  ["commit2", 1000],
  ["scroll3", 800],
  ["select3", 700],
  ["commit3", 1000],
  ["copy", 1000],
  ["toast", 1600],
  ["agent", AGENT_LINES.length * 480 + 1200],
  ["done", 1200],
];

const ORDER = TIMELINE.map(([p]) => p);
const at = (phase: Phase, cutoff: Phase) =>
  ORDER.indexOf(phase) >= ORDER.indexOf(cutoff);

function caption(phase: Phase): { no: string; text: string } {
  if (phase === "build") return { no: "1", text: "Your agent writes the whole feature" };
  if (!at(phase, "copy"))
    return { no: "2", text: "You review the branch — comments collect in the sidebar" };
  if (!at(phase, "agent"))
    return { no: "3", text: "Copy turns the whole review into one prompt" };
  return { no: "4", text: "Paste it into your agent — fixes land, review again" };
}

export default function DiffDemo() {
  const [index, setIndex] = useState(0);
  const [typed, setTyped] = useState(0);
  const [termLines, setTermLines] = useState(0);
  const phase = ORDER[index];

  // Advance the scene.
  useEffect(() => {
    const [, duration] = TIMELINE[index];
    const t = setTimeout(() => {
      setTyped(0);
      setTermLines(0);
      setIndex((index + 1) % TIMELINE.length);
    }, duration);
    return () => clearTimeout(t);
  }, [index]);

  // Typewriter for composer phases.
  useEffect(() => {
    if (phase !== "type1" && phase !== "type2") return;
    const t = setInterval(() => setTyped((n) => n + 1), 24);
    return () => clearInterval(t);
  }, [phase]);

  // Line-by-line reveal in the agent terminal.
  useEffect(() => {
    if (phase !== "build" && phase !== "agent") return;
    const t = setInterval(() => setTermLines((n) => n + 1), phase === "build" ? 520 : 480);
    return () => clearInterval(t);
  }, [phase]);

  const committedCount = at(phase, "commit3") ? 3 : at(phase, "commit2") ? 2 : at(phase, "commit1") ? 1 : 0;
  const sidebarVisible = committedCount > 0 && !at(phase, "agent");
  const scrollY = at(phase, "scroll3") ? -324 : at(phase, "scroll2") ? -158 : 0;
  const terminalVisible = phase === "build" || phase === "agent" || phase === "done";
  const terminalContent = phase === "build" ? BUILD_LINES : AGENT_LINES;
  const shownTermLines = phase === "done" ? AGENT_LINES.length : termLines;

  const composerFor = (n: 1 | 2) =>
    (n === 1 && (phase === "type1" || phase === "commit1")) ||
    (n === 2 && (phase === "type2" || phase === "commit2"));

  return (
    <div className="diff-demo-wrapper" style={{ opacity: 1, transition: "opacity 0.6s ease" }}>
      <div className="diff-window">
        <div className="diff-titlebar">
          <div className="diff-traffic-lights">
            <span className="tl-red" />
            <span className="tl-yellow" />
            <span className="tl-green" />
          </div>
          <span className="diff-titlebar-text">Redline — feature/checkout-flow</span>
          <div className="diff-traffic-lights" style={{ visibility: "hidden" }}>
            <span className="tl-red" />
            <span className="tl-yellow" />
            <span className="tl-green" />
          </div>
        </div>

        <div className="demo-stage">
          {/* Comments sidebar: appears with the first comment, like the real app */}
          <div className={`demo-sidebar${sidebarVisible ? " visible" : ""}`}>
            <div className="demo-sidebar-inner">
              <div className="sidebar-header">
                <span>
                  Comments <span className="sidebar-count">· {committedCount}</span>
                </span>
                <span className={`copyall-btn${at(phase, "copy") && !at(phase, "agent") ? " flash" : ""}`}>
                  {at(phase, "copy") && !at(phase, "agent") ? "✓ Copied" : "Copy"}
                </span>
              </div>
              {COMMENTS.slice(0, committedCount).map((c) => (
                <div className="sidebar-card" key={c.path}>
                  <div className="sc-path" title={c.path}>
                    {c.path.split("/").pop()}:{c.line}
                  </div>
                  <div className="sc-text">{c.text}</div>
                </div>
              ))}
            </div>
          </div>

          {/* The branch as one scrolling document */}
          <div className="demo-scroller">
            <div className="demo-doc" style={{ transform: `translateY(${scrollY}px)` }}>
              {/* src/lib/checkout.ts */}
              <div className="diff-file-header">
                <span className="dfh-chevron">▾</span>
                <span className="dfh-name">checkout.ts</span>
                <span className="dfh-dir">src/lib</span>
                <span className="dfh-adds">+9</span>
                <span className="dfh-dels">−2</span>
                <span className="dfh-reviewed">
                  <span className="dfh-checkbox"> </span>
                  Reviewed
                </span>
              </div>
              <div className="diff-rows">
                <SplitRow no={12} code={<><span className="c-kw">export async function</span> <span className="c-fn">checkout</span>(cart: Cart) {"{"}</>} />
                <div className="diff-row">
                  <div className="diff-row-side left row-del">
                    <span className="diff-gutter">13</span>
                    <span className="diff-code">{"  "}<span className="c-kw">const</span> total = <span className="c-kw">await</span> <span className="c-fn">serverTotal</span>(cart.id);</span>
                  </div>
                  <div className={`diff-row-side row-add${phase === "select1" ? " row-selected" : ""}${committedCount >= 1 ? " commented" : ""}`}>
                    <span className="diff-gutter">13</span>
                    <span className="diff-code">{"  "}<span className="c-kw">const</span> total = cart.localTotal;</span>
                  </div>
                </div>
                <div className="diff-row">
                  <div className="diff-row-side left" />
                  <div className={`diff-row-side row-add${phase === "select1" ? " row-selected" : ""}${committedCount >= 1 ? " commented" : ""}`}>
                    <span className="diff-gutter">14</span>
                    <span className="diff-code">{"  "}<span className="c-kw">const</span> tax = total * <span className="c-num">0.13</span>;</span>
                  </div>
                </div>
                <SplitRow no={15} code={<>{"  "}<span className="c-kw">return</span> <span className="c-fn">submitOrder</span>({"{ total, tax }"});</>} />
                <SplitRow no={16} code={<>{"}"}</>} />
              </div>
              {composerFor(1) && (
                <Composer
                  label={phase === "type1" ? "Comment · checkout.ts 13–14" : "Review comment"}
                  text={COMMENTS[0].text}
                  typed={phase === "type1" ? typed : COMMENTS[0].text.length}
                  typing={phase === "type1"}
                />
              )}

              {/* src/components/PaymentForm.tsx */}
              <div className="diff-file-header" style={{ marginTop: 8 }}>
                <span className="dfh-chevron">▾</span>
                <span className="dfh-name">PaymentForm.tsx</span>
                <span className="dfh-dir">src/components</span>
                <span className="dfh-adds">+34</span>
                <span className="dfh-reviewed">
                  <span className="dfh-checkbox"> </span>
                  Reviewed
                </span>
              </div>
              <div className="diff-rows">
                <SplitRow no={24} code={<><span className="c-kw">async function</span> <span className="c-fn">onSubmit</span>(v: FormValues) {"{"}</>} />
                <div className="diff-row">
                  <div className="diff-row-side left" />
                  <div className={`diff-row-side row-add${phase === "select2" ? " row-selected" : ""}${committedCount >= 2 ? " commented" : ""}`}>
                    <span className="diff-gutter">25</span>
                    <span className="diff-code">{"  "}console.<span className="c-fn">log</span>(<span className="c-str">&quot;payment&quot;</span>, v);</span>
                  </div>
                </div>
                <div className="diff-row">
                  <div className="diff-row-side left" />
                  <div className="diff-row-side row-add">
                    <span className="diff-gutter">26</span>
                    <span className="diff-code">{"  "}<span className="c-kw">await</span> <span className="c-fn">pay</span>(v);</span>
                  </div>
                </div>
                <SplitRow no={27} code={<>{"}"}</>} />
              </div>
              {composerFor(2) && (
                <Composer
                  label={phase === "type2" ? "Comment · PaymentForm.tsx 25" : "Review comment"}
                  text={COMMENTS[1].text}
                  typed={phase === "type2" ? typed : COMMENTS[1].text.length}
                  typing={phase === "type2"}
                />
              )}

              {/* src/api/cart.ts */}
              <div className="diff-file-header" style={{ marginTop: 8 }}>
                <span className="dfh-chevron">▾</span>
                <span className="dfh-name">cart.ts</span>
                <span className="dfh-dir">src/api</span>
                <span className="dfh-adds">+12</span>
                <span className="dfh-dels">−1</span>
                <span className="dfh-reviewed">
                  <span className="dfh-checkbox"> </span>
                  Reviewed
                </span>
              </div>
              <div className="diff-rows">
                <SplitRow no={40} code={<><span className="c-kw">export function</span> <span className="c-fn">bindQuantityInput</span>(el: Input) {"{"}</>} />
                <div className="diff-row">
                  <div className="diff-row-side left" />
                  <div className={`diff-row-side row-add${phase === "select3" ? " row-selected" : ""}${committedCount >= 3 ? " commented" : ""}`}>
                    <span className="diff-gutter">41</span>
                    <span className="diff-code">{"  "}el.<span className="c-fn">addEventListener</span>(<span className="c-str">&quot;input&quot;</span>, syncQuantity);</span>
                  </div>
                </div>
                <SplitRow no={42} code={<>{"  "}<span className="c-kw">return</span> () =&gt; el.<span className="c-fn">removeEventListener</span>(<span className="c-str">&quot;input&quot;</span>, syncQuantity);</>} />
                <SplitRow no={43} code={<>{"}"}</>} />
              </div>
              {phase === "commit3" && (
                <Composer label="Review comment" text={COMMENTS[2].text} typed={COMMENTS[2].text.length} typing={false} />
              )}
            </div>
          </div>

          {/* The external coding agent */}
          <div className={`demo-dim${terminalVisible ? " visible" : ""}`} />
          <div className={`agent-terminal${terminalVisible ? " visible" : ""}`}>
            <div className="at-titlebar">
              <div className="diff-traffic-lights">
                <span className="tl-red" style={{ width: 9, height: 9 }} />
                <span className="tl-yellow" style={{ width: 9, height: 9 }} />
                <span className="tl-green" style={{ width: 9, height: 9 }} />
              </div>
              your coding agent
            </div>
            <div className="at-body">
              {terminalContent.slice(0, shownTermLines).map((line, i) => (
                <div className={`at-line ${line.cls}`} key={i}>
                  {line.text}
                </div>
              ))}
              {shownTermLines < terminalContent.length && <span className="t-cursor" />}
            </div>
          </div>

          {phase === "toast" && (
            <div className="diff-toast animate-fade-in-up">
              ✓ 3 comments copied as one prompt
            </div>
          )}
        </div>
      </div>

      <div className="demo-caption">
        <span className="step-no">{caption(phase).no}</span>
        {caption(phase).text}
      </div>
    </div>
  );
}

/** A context row: same code on both sides of the split. */
function SplitRow({ no, code }: { no: number; code: React.ReactNode }) {
  return (
    <div className="diff-row">
      <div className="diff-row-side left">
        <span className="diff-gutter">{no}</span>
        <span className="diff-code">{code}</span>
      </div>
      <div className="diff-row-side">
        <span className="diff-gutter">{no}</span>
        <span className="diff-code">{code}</span>
      </div>
    </div>
  );
}

function Composer({
  label,
  text,
  typed,
  typing,
}: {
  label: string;
  text: string;
  typed: number;
  typing: boolean;
}) {
  return (
    <div className="diff-comment-card">
      <div className="diff-comment-label">{label}</div>
      <div>
        {text.slice(0, typed)}
        {typing && <span className="t-cursor" />}
      </div>
    </div>
  );
}
