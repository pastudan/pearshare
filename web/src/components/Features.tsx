const features = [
  {
    icon: (
      <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
        <circle cx="7" cy="8" r="3" stroke="currentColor" strokeWidth="1.5" />
        <circle cx="13" cy="8" r="3" stroke="currentColor" strokeWidth="1.5" />
        <path
          d="M1 16c0-2.5 2.5-4 6-4M19 16c0-2.5-2.5-4-6-4M10 12c3.5 0 6 1.5 6 4H4c0-2.5 2.5-4 6-4z"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    ),
    title: "Zero-config peer discovery",
    description:
      "If a device is in your Tailscale tailnet and running PearShare, it appears instantly. No invites, no friend requests — your Tailscale membership is your identity.",
  },
  {
    icon: (
      <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
        <rect
          x="2"
          y="3"
          width="16"
          height="11"
          rx="2"
          stroke="currentColor"
          strokeWidth="1.5"
        />
        <path
          d="M7 17h6M10 14v3"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
        />
        <path
          d="M8 8.5l1.5 1.5L12 7"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    ),
    title: "Screen sharing",
    description:
      "Share your screen with one click. No WebRTC negotiation, no relay latency — video streams directly over WireGuard to your peer.",
  },
  {
    icon: (
      <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
        <path
          d="M5 4l3 12M5 4l8 7-4 1 2 4"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path
          d="M13 4l3 12M13 4l-8 7 4 1-2 4"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
          opacity="0.4"
        />
      </svg>
    ),
    title: "Dual cursors",
    description:
      "Both people can move a cursor on the shared screen simultaneously. Built for pair programming, design reviews, and hands-on debugging.",
  },
  {
    icon: (
      <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
        <path
          d="M10 2L3 7v6l7 5 7-5V7L10 2z"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinejoin="round"
        />
        <path
          d="M10 2v16M3 7l7 5 7-5"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
          opacity="0.4"
        />
      </svg>
    ),
    title: "No relay servers",
    description:
      "All traffic is peer-to-peer over Tailscale's WireGuard tunnels. Nothing routes through PearShare infrastructure — your data never leaves your network.",
  },
];

export default function Features() {
  return (
    <section
      id="features"
      className="py-20"
      style={{ background: "var(--bg-subtle)" }}
    >
      <div className="max-w-5xl mx-auto px-6">
        <div className="text-center mb-12">
          <h2
            className="text-2xl font-semibold tracking-tight mb-3"
            style={{ color: "var(--text-primary)" }}
          >
            Built different
          </h2>
          <p
            className="text-base max-w-xl mx-auto"
            style={{ color: "var(--text-secondary)" }}
          >
            Most remote collaboration tools run through someone else&apos;s
            servers. PearShare doesn&apos;t.
          </p>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          {features.map((f, i) => (
            <div
              key={i}
              className="p-5 rounded-xl"
              style={{
                background: "var(--bg-card)",
                border: "1px solid var(--border)",
              }}
            >
              <div
                className="w-9 h-9 rounded-lg flex items-center justify-center mb-4"
                style={{
                  background: "var(--accent-subtle)",
                  color: "var(--accent)",
                }}
              >
                {f.icon}
              </div>
              <h3
                className="text-sm font-semibold mb-2"
                style={{ color: "var(--text-primary)" }}
              >
                {f.title}
              </h3>
              <p
                className="text-sm leading-relaxed"
                style={{ color: "var(--text-secondary)" }}
              >
                {f.description}
              </p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
