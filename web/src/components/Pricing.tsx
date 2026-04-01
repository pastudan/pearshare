const freeTier = [
  "1 peer connection",
  "Full screenshare",
  "Dual cursors",
  "Auto-updates via Sparkle",
  "No account required",
];

const paidTier = [
  "Unlimited peer connections",
  "Full screenshare",
  "Dual cursors",
  "Auto-updates via Sparkle",
  "No account required",
  "Support open-source development",
];

function Check({ faint = false }: { faint?: boolean }) {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 14 14"
      fill="none"
      style={{ opacity: faint ? 0.35 : 1, flexShrink: 0 }}
    >
      <circle cx="7" cy="7" r="6" fill="var(--accent)" opacity="0.15" />
      <path
        d="M4.5 7l2 2 3-3"
        stroke="var(--accent)"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export default function Pricing() {
  return (
    <section
      id="pricing"
      className="py-20"
      style={{ background: "var(--bg-subtle)" }}
    >
      <div className="max-w-5xl mx-auto px-6">
        <div className="text-center mb-12">
          <h2
            className="text-2xl font-semibold tracking-tight mb-3"
            style={{ color: "var(--text-primary)" }}
          >
            Simple pricing
          </h2>
          <p
            className="text-base max-w-md mx-auto"
            style={{ color: "var(--text-secondary)" }}
          >
            Free to try with one peer. Pay once to unlock your whole team.
          </p>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 max-w-2xl mx-auto">
          {/* Free tier */}
          <div
            className="p-6 rounded-xl flex flex-col"
            style={{
              background: "var(--bg-card)",
              border: "1px solid var(--border)",
            }}
          >
            <div className="mb-5">
              <p
                className="text-xs font-medium uppercase tracking-widest mb-2"
                style={{ color: "var(--text-muted)" }}
              >
                Free
              </p>
              <div className="flex items-baseline gap-1">
                <span
                  className="text-3xl font-semibold"
                  style={{ color: "var(--text-primary)" }}
                >
                  $0
                </span>
              </div>
              <p
                className="text-xs mt-1"
                style={{ color: "var(--text-muted)" }}
              >
                forever
              </p>
            </div>

            <ul className="flex flex-col gap-2.5 mb-6 flex-1">
              {freeTier.map((item, i) => (
                <li key={i} className="flex items-center gap-2.5">
                  <Check faint={i > 0} />
                  <span
                    className="text-sm"
                    style={{
                      color: i === 0 ? "var(--text-primary)" : "var(--text-secondary)",
                    }}
                  >
                    {item}
                  </span>
                </li>
              ))}
            </ul>

            <a
              href="#"
              className="text-center text-sm font-medium py-2.5 rounded-lg transition-colors"
              style={{
                border: "1px solid var(--border)",
                color: "var(--text-primary)",
                background: "var(--bg-subtle)",
              }}
            >
              Download free
            </a>
          </div>

          {/* Paid tier */}
          <div
            className="p-6 rounded-xl flex flex-col relative overflow-hidden"
            style={{
              background: "var(--accent-subtle)",
              border: "1px solid var(--accent)",
            }}
          >
            <div
              className="absolute top-3 right-3 text-xs font-medium px-2 py-0.5 rounded-full"
              style={{ background: "var(--accent)", color: "#fff" }}
            >
              Recommended
            </div>

            <div className="mb-5">
              <p
                className="text-xs font-medium uppercase tracking-widest mb-2"
                style={{ color: "var(--accent)" }}
              >
                Pro
              </p>
              <div className="flex items-baseline gap-1">
                <span
                  className="text-3xl font-semibold"
                  style={{ color: "var(--text-primary)" }}
                >
                  $5
                </span>
              </div>
              <p
                className="text-xs mt-1"
                style={{ color: "var(--text-muted)" }}
              >
                one-time · no subscription
              </p>
            </div>

            <ul className="flex flex-col gap-2.5 mb-6 flex-1">
              {paidTier.map((item, i) => (
                <li key={i} className="flex items-center gap-2.5">
                  <Check />
                  <span
                    className="text-sm font-medium"
                    style={{ color: "var(--text-primary)" }}
                  >
                    {item}
                  </span>
                </li>
              ))}
            </ul>

            <a
              href="#"
              className="text-center text-sm font-semibold py-2.5 rounded-lg transition-colors"
              style={{
                background: "var(--accent)",
                color: "#fff",
              }}
            >
              Unlock for $5
            </a>
          </div>
        </div>

        <p
          className="text-center text-xs mt-6"
          style={{ color: "var(--text-muted)" }}
        >
          One-time purchase. Yours forever. No subscription, no seat fees.
        </p>
      </div>
    </section>
  );
}
