import AppMockup from "./AppMockup";

export default function Hero() {
  return (
    <section className="max-w-5xl mx-auto px-6 pt-20 pb-16">
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-12 items-center">
        {/* Left: Copy */}
        <div>
          {/* App icon + badge row */}
          <div className="flex items-center gap-3 mb-6">
            <img
              src="/pear.png"
              alt="PearShare icon"
              width={52}
              height={52}
              style={{ borderRadius: "14px" }}
            />
            <div
              className="inline-flex items-center gap-2 text-xs font-medium px-3 py-1 rounded-full"
              style={{
                background: "var(--accent-subtle)",
                color: "var(--accent)",
                border: "1px solid var(--accent)",
                opacity: 0.9,
              }}
            >
              <span>●</span> The spiritual successor to ScreenHero
            </div>
          </div>

          <h1
            className="text-4xl lg:text-5xl font-semibold tracking-tight leading-tight mb-4"
            style={{ color: "var(--text-primary)" }}
          >
            See your teammates.
            <br />
            <span style={{ color: "var(--accent)" }}>Drive together.</span>
          </h1>

          <p
            className="text-lg leading-relaxed mb-8"
            style={{ color: "var(--text-secondary)" }}
          >
            Open-source, Tailscale-native remote collaboration. Share your
            screen, ring a teammate, and control together with dual cursors —
            all peer-to-peer over your existing Tailscale network.
          </p>

          <div className="flex flex-col sm:flex-row gap-3 mb-8">
            <a
              href="#"
              className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-lg font-medium text-sm transition-colors"
              style={{ background: "var(--accent)", color: "#fff" }}
            >
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                <path
                  d="M8 2v8M5 7l3 3 3-3M3 12h10"
                  stroke="currentColor"
                  strokeWidth="1.5"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
              Download free
            </a>
            <a
              href="#pricing"
              className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-lg font-medium text-sm transition-colors"
              style={{
                border: "1px solid var(--border)",
                color: "var(--text-primary)",
                background: "var(--bg-card)",
              }}
            >
              Unlock unlimited peers — $5
            </a>
          </div>

          {/* Requirement badges */}
          <div className="flex flex-wrap gap-2">
            <span
              className="inline-flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-md"
              style={{
                background: "var(--bg-subtle)",
                color: "var(--text-muted)",
                border: "1px solid var(--border)",
              }}
            >
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                <rect
                  x="1"
                  y="1"
                  width="10"
                  height="10"
                  rx="2"
                  stroke="currentColor"
                  strokeWidth="1.2"
                />
                <path
                  d="M4 6l1.5 1.5L8 4"
                  stroke="currentColor"
                  strokeWidth="1.2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
              Requires Tailscale
            </span>
            <span
              className="inline-flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-md"
              style={{
                background: "var(--bg-subtle)",
                color: "var(--text-muted)",
                border: "1px solid var(--border)",
              }}
            >
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                <path
                  d="M2 9 C2 9 3 3 6 3 C9 3 10 9 10 9"
                  stroke="currentColor"
                  strokeWidth="1.2"
                  strokeLinecap="round"
                />
                <path d="M1 9h10" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
              </svg>
              macOS 13+
            </span>
            <span
              className="inline-flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-md"
              style={{
                background: "var(--bg-subtle)",
                color: "var(--text-muted)",
                border: "1px solid var(--border)",
              }}
            >
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                <circle cx="6" cy="6" r="4.5" stroke="currentColor" strokeWidth="1.2" />
                <path
                  d="M4 6h4M6 4v4"
                  stroke="currentColor"
                  strokeWidth="1.2"
                  strokeLinecap="round"
                />
              </svg>
              Free • No account needed
            </span>
          </div>
        </div>

        {/* Right: App mockup */}
        <div className="flex justify-center lg:justify-end">
          <AppMockup />
        </div>
      </div>
    </section>
  );
}
