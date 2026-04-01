export default function OpenSource() {
  return (
    <section className="py-20">
      <div className="max-w-5xl mx-auto px-6">
        <div
          className="rounded-xl p-8 flex flex-col sm:flex-row items-start sm:items-center gap-6"
          style={{
            background: "var(--bg-card)",
            border: "1px solid var(--border)",
          }}
        >
          {/* GitHub icon */}
          <div
            className="w-12 h-12 rounded-xl flex items-center justify-center shrink-0"
            style={{ background: "var(--bg-subtle)", border: "1px solid var(--border)" }}
          >
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
              <path
                d="M12 2C6.477 2 2 6.477 2 12c0 4.418 2.865 8.166 6.839 9.489.5.092.682-.217.682-.482 0-.237-.009-.868-.013-1.703-2.782.604-3.369-1.342-3.369-1.342-.454-1.155-1.11-1.463-1.11-1.463-.908-.62.069-.608.069-.608 1.003.07 1.531 1.03 1.531 1.03.892 1.529 2.341 1.087 2.91.831.092-.646.35-1.086.636-1.336-2.22-.253-4.555-1.11-4.555-4.943 0-1.091.39-1.984 1.029-2.683-.103-.253-.446-1.27.098-2.647 0 0 .84-.269 2.75 1.025A9.578 9.578 0 0112 6.836c.85.004 1.705.114 2.504.336 1.909-1.294 2.747-1.025 2.747-1.025.546 1.377.203 2.394.1 2.647.64.699 1.028 1.592 1.028 2.683 0 3.842-2.339 4.687-4.566 4.935.359.309.678.919.678 1.852 0 1.336-.012 2.415-.012 2.743 0 .267.18.578.688.48C19.138 20.163 22 16.417 22 12c0-5.523-4.477-10-10-10z"
                fill="var(--text-secondary)"
              />
            </svg>
          </div>

          {/* Copy */}
          <div className="flex-1">
            <h3
              className="text-sm font-semibold mb-1"
              style={{ color: "var(--text-primary)" }}
            >
              Open source
            </h3>
            <p
              className="text-sm leading-relaxed"
              style={{ color: "var(--text-secondary)" }}
            >
              PearShare is fully open source. Inspect the code, self-host it,
              build your own distribution, or contribute improvements back.
              The $5 license is for convenience — not a paywall on knowledge.
            </p>
          </div>

          {/* CTA */}
          <a
            href="https://github.com/pastudan/pearshare"
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium shrink-0 transition-colors"
            style={{
              border: "1px solid var(--border)",
              color: "var(--text-primary)",
              background: "var(--bg-subtle)",
            }}
          >
            View on GitHub
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
              <path
                d="M2.5 9.5l7-7M4 2.5h5.5V8"
                stroke="currentColor"
                strokeWidth="1.5"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          </a>
        </div>
      </div>
    </section>
  );
}
