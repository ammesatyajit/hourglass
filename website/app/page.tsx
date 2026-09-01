"use client";

import { useEffect, useRef, useState, type CSSProperties } from "react";

const DOWNLOAD_URL =
  "https://hourglass-downloads.ammesatyajit.workers.dev/download/0.4.2/Hourglass.dmg";

type Point = [number, number];
type SearchMode = "keyword" | "needle";
type LineVariant = "sent" | "received" | "brush" | "edge";

const sentFrequency: Point[] = [
  [0, 72], [7, 54], [13, 58], [18, 82], [25, 65], [31, 73], [38, 49],
  [45, 84], [52, 60], [58, 70], [65, 88], [72, 68], [79, 77], [86, 65],
  [92, 79], [97, 57], [100, 92],
];

const receivedFrequency: Point[] = [
  [0, 45], [8, 53], [13, 79], [18, 35], [24, 66], [31, 28], [38, 74],
  [44, 20], [50, 68], [57, 39], [64, 76], [71, 24], [78, 62], [85, 48],
  [92, 66], [97, 42], [100, 88],
];

// Valley profile: high at both edges, dipping through the center, with a
// little organic wobble so it doesn't read as a perfect parabola.
const heroEdge: Point[] = [
  [0, 8], [9, 20], [19, 29], [28, 50], [38, 70], [50, 86],
  [62, 68], [71, 58], [81, 38], [91, 16], [100, 6],
];

/// Resample a polyline through quadratic midpoint curves so corners render
/// round instead of sharp. Returns many short segments, which keeps the
/// existing length-walking draw animation working unchanged.
function smoothPoints(points: Point[], steps = 12): Point[] {
  if (points.length < 3) return points;
  const out: Point[] = [points[0]];
  const mid = (a: Point, b: Point): Point => [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2];
  let from = points[0];
  for (let i = 1; i < points.length - 1; i += 1) {
    const control = points[i];
    const to = i === points.length - 2 ? points[points.length - 1] : mid(points[i], points[i + 1]);
    for (let s = 1; s <= steps; s += 1) {
      const t = s / steps;
      const inv = 1 - t;
      out.push([
        inv * inv * from[0] + 2 * inv * t * control[0] + t * t * to[0],
        inv * inv * from[1] + 2 * inv * t * control[1] + t * t * to[1],
      ]);
    }
    from = to;
  }
  return out;
}

function ContinuousLine({
  points,
  variant,
  className = "",
  smooth = false,
}: {
  points: Point[];
  variant: LineVariant;
  className?: string;
  smooth?: boolean;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const shapedPoints = smooth ? smoothPoints(points) : points;

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    let animationFrame = 0;
    let startedAt = performance.now();
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    function draw(progress: number) {
      const context = canvas.getContext("2d");
      if (!context) return;

      const bounds = canvas.getBoundingClientRect();
      const width = Math.max(1, bounds.width);
      const height = Math.max(1, bounds.height);
      const pixelRatio = Math.min(window.devicePixelRatio || 1, 2);
      const targetWidth = Math.round(width * pixelRatio);
      const targetHeight = Math.round(height * pixelRatio);

      if (canvas.width !== targetWidth || canvas.height !== targetHeight) {
        canvas.width = targetWidth;
        canvas.height = targetHeight;
      }

      context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
      context.clearRect(0, 0, width, height);

      const coordinates = shapedPoints.map(([x, y]) => ({ x: width * x / 100, y: height * y / 100 }));
      const segmentLengths = coordinates.slice(1).map((point, index) => {
        const previous = coordinates[index];
        return Math.hypot(point.x - previous.x, point.y - previous.y);
      });
      const totalLength = segmentLengths.reduce((sum, length) => sum + length, 0);
      let remaining = totalLength * progress;
      let endPoint = coordinates[0];

      function tracePath() {
        context.beginPath();
        context.moveTo(coordinates[0].x, coordinates[0].y);
        endPoint = coordinates[0];

        for (let index = 0; index < segmentLengths.length; index += 1) {
          const start = coordinates[index];
          const end = coordinates[index + 1];
          const length = segmentLengths[index];

          if (remaining >= length) {
            context.lineTo(end.x, end.y);
            endPoint = end;
            remaining -= length;
            continue;
          }

          if (remaining > 0) {
            const amount = remaining / length;
            endPoint = {
              x: start.x + (end.x - start.x) * amount,
              y: start.y + (end.y - start.y) * amount,
            };
            context.lineTo(endPoint.x, endPoint.y);
          }
          break;
        }
      }

      if (variant === "sent") {
        tracePath();
        context.lineTo(endPoint.x, height);
        context.lineTo(coordinates[0].x, height);
        context.closePath();
        const fill = context.createLinearGradient(0, 0, 0, height);
        fill.addColorStop(0, "rgba(38, 137, 255, 0.22)");
        fill.addColorStop(0.8, "rgba(38, 137, 255, 0)");
        context.fillStyle = fill;
        context.fill();
        remaining = totalLength * progress;
      }

      tracePath();
      context.lineCap = "round";
      context.lineJoin = "round";
      context.setLineDash(variant === "received" ? [5, 7] : []);
      context.lineWidth = variant === "edge" ? 2 : variant === "received" ? 1 : 1.5;
      context.strokeStyle = variant === "received"
        ? "rgba(255, 255, 255, 0.58)"
        : variant === "brush"
          ? "rgba(38, 137, 255, 0.65)"
          : variant === "edge"
            ? "rgba(72, 147, 255, 0.88)"
            : "#2689ff";
      if (variant === "edge") {
        context.shadowBlur = 9;
        context.shadowColor = "rgba(38, 137, 255, 0.55)";
      }
      context.stroke();
    }

    function animate(now: number) {
      const elapsed = reducedMotion ? 1 : Math.min(1, (now - startedAt) / 850);
      const eased = 1 - Math.pow(1 - elapsed, 3);
      draw(eased);
      if (elapsed < 1) animationFrame = window.requestAnimationFrame(animate);
    }

    const observer = new ResizeObserver(() => {
      window.cancelAnimationFrame(animationFrame);
      startedAt = performance.now();
      animationFrame = window.requestAnimationFrame(animate);
    });
    observer.observe(canvas);
    animationFrame = window.requestAnimationFrame(animate);

    return () => {
      observer.disconnect();
      window.cancelAnimationFrame(animationFrame);
    };
  }, [points, variant, smooth]);

  return <canvas ref={canvasRef} className={`continuous-line ${className}`} aria-hidden="true" />;
}

function Logo({ small = false }: { small?: boolean }) {
  return (
    <a className="brand" href="#top" aria-label="Hourglass home">
      <img src="./hourglass-icon.png" width={small ? 28 : 34} height={small ? 28 : 34} alt="" />
      <span>Hourglass</span>
    </a>
  );
}

function Header() {
  return (
    <header className="topbar">
      <div className="topbar-left">
        <Logo />
        <a
          className="gh-link"
          href="https://github.com/ammesatyajit/hourglass"
          rel="noreferrer"
          aria-label="Hourglass on GitHub"
        >
          <svg viewBox="0 0 16 16" width="15" height="15" fill="currentColor" aria-hidden="true">
            <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
          </svg>
        </a>
      </div>
      <nav aria-label="Main navigation">
        <a className="nav-download" href={DOWNLOAD_URL} rel="noreferrer">Download</a>
        <a href="./privacy/">Privacy Policy</a>
        <a href="#about">About Me</a>
      </nav>
    </header>
  );
}

function DashboardBackdrop() {
  const people = ["Maya", "Theo", "Noor"];
  const groups = ["Studio", "Roommates", "Family"];
  return (
    <div className="dashboard-backdrop" aria-hidden="true">
      <aside className="dash-sidebar">
        <strong>Hourglass</strong>
        <span className="active"><i /> Overview</span>
        <span><i /> Vernacular</span>
        <span><i /> Nostalgia</span>
      </aside>
      <div className="dash-main">
        <div className="dash-title-row"><h3>Overview</h3><span>30d&nbsp;&nbsp; 12m&nbsp;&nbsp; All</span></div>
        <div className="dash-stats">
          <span>TOTAL <strong>602,304</strong></span>
          <span>SENT <strong>199,636</strong></span>
          <span>RECEIVED <strong>402,668</strong></span>
          <span>CHATS <strong>1,339</strong></span>
        </div>
        <div className="frequency-card">
          <div className="frequency-label"><strong>Texting frequency</strong><span>Last 30 days · daily</span></div>
          <div className="frequency-plot">
            <div className="chart-grid" />
            <ContinuousLine points={receivedFrequency} variant="received" className="received-line" />
            <ContinuousLine points={sentFrequency} variant="sent" className="sent-line" />
          </div>
          <div className="brush-strip"><ContinuousLine points={heroEdge} variant="brush" className="brush-line" /><i /></div>
        </div>
        <div className="leaderboards">
          <div className="leader-card">
            <strong>People you text the most</strong>
            {people.map((person, index) => <span key={person}><b>{index + 1}</b><i />{person}<em style={{ width: `${82 - index * 17}%` }} /></span>)}
          </div>
          <div className="leader-card">
            <strong>Group chats you text the most</strong>
            {groups.map((group, index) => <span key={group}><b>{index + 1}</b><i />{group}<em style={{ width: `${88 - index * 19}%` }} /></span>)}
          </div>
        </div>
      </div>
    </div>
  );
}

function Hero() {
  return (
    <section className="hero" id="top">
      <DashboardBackdrop />
      <div className="hero-shade" />
      <div className="hero-copy">
        <img className="hero-icon" src="./hourglass-icon.png" width="92" height="92" alt="Hourglass app icon" />
        <h1>Hourglass</h1>
        <p>iMessage search and analytics</p>
        <a className="primary-download" href={DOWNLOAD_URL} rel="noreferrer">
          Download for macOS <span>↗</span>
        </a>
      </div>
      <div className="hero-cut" aria-hidden="true" />
      <ContinuousLine points={heroEdge} variant="edge" smooth className="hero-edge-line" />
    </section>
  );
}

const searchCopy = {
  keyword: {
    query: 'in:"Studio" reactions:>=3',
    label: "Keyword Search",
  },
  needle: {
    query: "jokes from theo",
    label: "Natural Language Search",
  },
} as const;

/** The panel's bottom toolbar, mirroring the app's Spotlight footer. */
function PanelFooter({ results }: { results: string }) {
  return (
    <div className="panel-footer">
      <span>↵ Open in Messages</span>
      <span>⇅ Navigate</span>
      <span>⟲ Dismiss</span>
      <b>⚡ {results}</b>
    </div>
  );
}

function KeywordResults({ ready }: { ready: boolean }) {
  const rows: Array<{
    initials: string; name: string; body: string; date: string;
    pills: Array<[string, number | null]>; selected?: boolean; media?: boolean;
  }> = [
    { initials: "M", name: "Maya", body: "the deadline moved AGAIN and I refuse to be sad about it 💅", date: "8/15/26, 1:26 AM", pills: [["❤️", 4], ["😂", 2]], selected: true },
    { initials: "T", name: "Theo", body: "ok the new cut is actually insane. gallery night is BACK", date: "8/12/26, 5:47 PM", pills: [["❤️", 5], ["😂", null]] },
    { initials: "N", name: "Noor", body: "Image", date: "8/6/26, 2:52 PM", pills: [["❤️", 6]], media: true },
    { initials: "M", name: "Maya", body: "one of yall owns up to the glitter or nobody leaves", date: "7/29/26, 5:19 PM", pills: [["❤️", 3], ["‼️", null]] },
  ];
  return (
    <div className={`search-results ${ready ? "ready" : ""}`}>
      <div className="filter-chips">
        <span className="chip chip-scope">🗨 in:&quot;Studio&quot; <i>×</i></span>
        <span className="chip chip-react">❤ reactions:&gt;=3 <i>×</i></span>
      </div>
      {rows.map((row) => (
        <div className={`message-result ${row.selected ? "selected" : ""}`} key={row.date}>
          <span className="result-avatar">{row.initials}</span>
          <div>
            <strong>{row.name} <small>· 👥 Studio</small></strong>
            <p>{row.media ? <>🖼 <em>Image</em></> : row.body}</p>
          </div>
          <div className="row-side">
            <span className="pill-row">
              {row.pills.map(([glyph, count]) => (
                <i className="pill" key={glyph}>{glyph}{count !== null ? ` ${count}` : ""}</i>
              ))}
            </span>
            <time>{row.date}</time>
          </div>
        </div>
      ))}
      <PanelFooter results="77 results" />
    </div>
  );
}

function NeedleResult({ ready }: { ready: boolean }) {
  const moments: Array<[string, string, string]> = [
    ["I swear all my brainpower goes to brainrot and terrible puns now", "5/28/24, 8:34 PM", "8 messages"],
    ["“that knee injury is faker than our launch date” is an insane stray 💀", "10/19/25, 3:00 AM", "7 messages"],
  ];
  return (
    <div className={`needle-result ${ready ? "ready" : ""}`}>
      <div className="moment moment-hero">
        <div className="moment-head">
          <strong>Theo <small>· 👥 Studio</small></strong>
          <span>8/15/26, 2:35 AM <i>›</i> <i>↗</i></span>
        </div>
        <p>Ain&apos;t no one wanna hear that man&apos;s jokes again bruh 💀🙏</p>
        <button type="button" className="show-exchange">Show this exchange · 2 messages</button>
      </div>
      <span className="moments-label">Other moments</span>
      {moments.map(([body, date, count]) => (
        <div className="moment" key={date}>
          <div className="moment-head">
            <strong>Theo <small>· 👥 Studio</small></strong>
            <span>{date} <i>›</i> <i>↗</i></span>
          </div>
          <p>{body}</p>
          <button type="button" className="show-exchange">Show this exchange · {count}</button>
        </div>
      ))}
      <PanelFooter results="5 moments" />
    </div>
  );
}

function SearchDemo() {
  const [mode, setMode] = useState<SearchMode>("keyword");
  const [typed, setTyped] = useState("");
  const [ready, setReady] = useState(false);
  const [helpOpen, setHelpOpen] = useState(false);
  const panelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const query = searchCopy[mode].query;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    setTyped(reduced ? query : "");
    setReady(reduced);
    setHelpOpen(false);
    if (reduced) return;

    let index = 0;
    const typing = window.setInterval(() => {
      index += 1;
      setTyped(query.slice(0, index));
      if (index >= query.length) window.clearInterval(typing);
    }, 42);
    const reveal = window.setTimeout(() => setReady(true), query.length * 42 + 260);
    const switchMode = window.setTimeout(() => setMode((value) => value === "keyword" ? "needle" : "keyword"), mode === "keyword" ? 7600 : 8400);
    return () => {
      window.clearInterval(typing);
      window.clearTimeout(reveal);
      window.clearTimeout(switchMode);
    };
  }, [mode]);

  function handleKeyDown(event: React.KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Tab") {
      event.preventDefault();
      setMode((value) => value === "keyword" ? "needle" : "keyword");
    }
    if (event.metaKey && (event.key === "?" || event.key === "/")) {
      event.preventDefault();
      setHelpOpen((value) => !value);
    }
  }

  return (
    <section className="search-section" id="search">
      <div className="section-intro">
        <span>01</span>
        <h2>{mode === "keyword" ? "Keyword Search" : "Natural Language Search"}</h2>
        <p>{mode === "keyword" ? "Exact when you know the words." : "For when you only remember the idea — powered by Cactus Needle 2."}</p>
        <p className="switch-hint">Switch between Keyword and Natural Language search — just press <kbd>Tab</kbd></p>
      </div>
      <div
        className={`search-window ${mode}`}
        ref={panelRef}
        tabIndex={0}
        onKeyDown={handleKeyDown}
        aria-label="Interactive Hourglass search demonstration. Press Tab to change modes."
      >
        <div className="mac-titlebar">
          <div><i /><i /><i /></div>
          <span>{searchCopy[mode].label}</span>
          <button type="button" onClick={() => setHelpOpen((value) => !value)} aria-pressed={helpOpen}>⌘?</button>
        </div>
        <div className="search-input">
          <span aria-hidden="true">{mode === "keyword" ? "⌕" : "✦"}</span>
          <strong>{typed}<i /></strong>
          <kbd>TAB</kbd>
        </div>
        <div className="mode-caption">
          <span className={mode === "keyword" ? "active" : ""}>Keyword</span>
          <button type="button" onClick={() => setMode((value) => value === "keyword" ? "needle" : "keyword")}>Press Tab</button>
          <span className={mode === "needle" ? "active" : ""}>Natural Language</span>
        </div>
        {mode === "keyword" ? <KeywordResults ready={ready} /> : <NeedleResult ready={ready} />}
        <div className={`syntax-sheet ${helpOpen ? "open" : ""}`} aria-hidden={!helpOpen}>
          <div><strong>Search examples</strong><button type="button" onClick={() => setHelpOpen(false)}>×</button></div>
          <code>with:Maya last:30d</code>
          <code>type:image vacation</code>
          <code>reactions:&gt;=3</code>
          <code>flight + confirmation</code>
          <small>Tab switches to Cactus Needle 2</small>
        </div>
      </div>
      <p className="search-hint">Click the panel, then press <kbd>Tab</kbd> or <kbd>⌘?</kbd></p>
    </section>
  );
}

const graphNodes = [
  ["You", 50, 54, "you"], ["Maya", 27, 40, "blue"], ["Theo", 72, 34, "orange"],
  ["Noor", 67, 68, "purple"], ["Ben", 32, 73, "blue"], ["Imani", 46, 23, "orange"],
  ["Leah", 84, 54, "muted"], ["Ari", 16, 61, "muted"], ["Sam", 55, 82, "purple"],
  ["Jules", 82, 79, "muted"], ["Kai", 18, 24, "muted"], ["Nia", 41, 87, "muted"],
] as const;

const graphEdges = [
  [0, 1, "blue"], [0, 2, "orange"], [0, 3, "purple"], [0, 4, "blue"], [0, 5, "orange"],
  [1, 4, "blue"], [2, 3, "orange"], [3, 8, "purple"], [2, 6, "muted"], [4, 7, "muted"],
  [5, 10, "muted"], [8, 11, "muted"], [3, 9, "muted"], [1, 5, "muted"],
] as const;

function GraphEdge({ from, to, tone }: { from: number; to: number; tone: string }) {
  const [, x1, y1] = graphNodes[from];
  const [, x2, y2] = graphNodes[to];
  const dx = x2 - x1;
  const dy = (y2 - y1) * 0.66;
  const width = Math.sqrt(dx * dx + dy * dy);
  const rotation = Math.atan2(dy, dx) * (180 / Math.PI);
  return <i className={`graph-edge ${tone}`} style={{ "--x": `${x1}%`, "--y": `${y1}%`, "--w": `${width}%`, "--r": `${rotation}deg` } as CSSProperties} />;
}

const tradedWords = [
  ["cone", "spread to 4", "169×", "orange"],
  ["brother", "came from 1 · spread to 1", "292×", "purple"],
  ["lowkey", "came from 1", "446×", "blue"],
  ["wtv", "spread to 4", "177×", "orange"],
] as const;

function VernacularDemo() {
  const [selected, setSelected] = useState(0);
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const timer = window.setInterval(() => setSelected((value) => (value + 1) % tradedWords.length), 3200);
    return () => window.clearInterval(timer);
  }, []);
  const selectedWord = tradedWords[selected][0];

  return (
    <section className="vernacular-section" id="vernacular">
      <div className="section-intro vernacular-intro">
        <span>02</span>
        <h2>Vernacular</h2>
        <p>Your circles. Your shared language. What you picked up—and what you spread.</p>
      </div>
      <div className="vernacular-window">
        <div className="vernacular-topbar">
          <div><strong>How words moved</strong><small>Choose a word to trace it</small></div>
          <nav><span className="active">Circles</span><span>Vocabulary</span></nav>
        </div>
        <div className="vernacular-layout">
          <aside className="word-rail">
            <div className="rail-heading"><strong>Words you traded</strong><small>ranked by reach</small></div>
            {tradedWords.map(([word, detail, count, tone], index) => (
              <button className={selected === index ? "selected" : ""} key={word} type="button" onClick={() => setSelected(index)}>
                <span><strong>{word}</strong><b>{count}</b></span>
                <small>{detail}</small>
                <i className={tone} />
              </button>
            ))}
          </aside>
          <div className="social-graph" aria-label={`Social graph showing how the word ${selectedWord} moved through several circles`}>
            <div className="circle-label studio">STUDIO</div>
            <div className="circle-label home">HOME</div>
            <div className="circle-label friends">FRIENDS</div>
            {graphEdges.map(([from, to, tone], index) => <GraphEdge key={`${from}-${to}-${index}`} from={from} to={to} tone={tone} />)}
            {graphNodes.map(([name, x, y, tone], index) => (
              <button
                type="button"
                className={`person-node ${tone} ${index === 0 ? "center" : ""}`}
                style={{ left: `${x}%`, top: `${y}%`, "--node-delay": `${index * 70}ms` } as CSSProperties}
                key={name}
              >
                <i>{name === "You" ? "SK" : name.slice(0, 1)}</i><span>{name}</span>
              </button>
            ))}
            <div className="trace-label"><strong>{selectedWord}</strong><span>moving through 3 circles</span></div>
          </div>
          <aside className="shared-rail">
            <div className="person-card"><span>MC</span><div><strong>Maya</strong><small>6 words used by both</small></div></div>
            <div className="shared-group from-them">
              <small>↓ PICKED UP</small>
              <strong>lowkey</strong><i style={{ width: "88%" }} /><strong>brother</strong><i style={{ width: "62%" }} />
            </div>
            <div className="shared-group from-you">
              <small>↑ SPREAD</small>
              <strong>cone</strong><i style={{ width: "78%" }} /><strong>wtv</strong><i style={{ width: "54%" }} />
            </div>
            <div className="shared-group together">
              <small>● SHARED</small>
              <strong>idk</strong><i style={{ width: "92%" }} /><strong>bro</strong><i style={{ width: "67%" }} />
            </div>
          </aside>
        </div>
      </div>
    </section>
  );
}

function About() {
  return (
    <section className="about-section" id="about">
      <img className="about-mark" src="./headshot.jpg" alt="Satyajit Kumar" width="170" height="170" />
      <div>
        <span>ABOUT ME</span>
        <h2>Satyajit Kumar</h2>
        <p>I built Hourglass because the conversations I cared about were impossible to find again.</p>
        <a href="https://github.com/ammesatyajit" rel="noreferrer">GitHub ↗</a>
      </div>
    </section>
  );
}

/** Anonymous visit ping — one GET per page load, no cookies or identifiers.
 *  The Worker just bumps an aggregate counter; failures are ignored. */
function useVisitPing() {
  useEffect(() => {
    fetch("https://hourglass-downloads.ammesatyajit.workers.dev/visit").catch(() => {});
  }, []);
}

function DownloadCount() {
  const [count, setCount] = useState<number | null>(null);
  useEffect(() => {
    fetch("https://hourglass-downloads.ammesatyajit.workers.dev/stats")
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => {
        const n = d?.totals?.freshDownloads;
        if (typeof n === "number" && n > 0) setCount(n);
      })
      .catch(() => {
        // Counter is decorative — render nothing if stats are unreachable.
      });
  }, []);
  if (count === null) return null;
  return <> · {count.toLocaleString()} downloads</>;
}

function Footer() {
  return (
    <footer>
      <Logo small />
      <p>Nothing leaves your computer. <a href="./privacy/">See the privacy policy.</a></p>
      <span>© 2026 Satyajit Kumar<DownloadCount /></span>
    </footer>
  );
}

export default function Home() {
  useVisitPing();
  return (
    <main>
      <Header />
      <Hero />
      <SearchDemo />
      <VernacularDemo />
      <About />
      <Footer />
    </main>
  );
}
