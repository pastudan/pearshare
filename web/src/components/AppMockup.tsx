export default function AppMockup() {
  const peers = [
    { name: "alex@tailnet", initials: "AL", online: true, active: true },
    { name: "maya@tailnet", initials: "MA", online: true, active: false },
    { name: "dan@tailnet", initials: "DA", online: false, active: false },
  ];

  return (
    <div
      className="w-64 rounded-xl overflow-hidden shadow-2xl"
      style={{
        background: "var(--bg-card)",
        border: "1px solid var(--border)",
      }}
    >
      {/* Title bar */}
      <div
        className="flex items-center gap-2 px-3 py-2.5"
        style={{ borderBottom: "1px solid var(--border)" }}
      >
        <div className="flex gap-1.5">
          <div className="w-2.5 h-2.5 rounded-full bg-red-400 opacity-80" />
          <div className="w-2.5 h-2.5 rounded-full bg-yellow-400 opacity-80" />
          <div className="w-2.5 h-2.5 rounded-full bg-green-400 opacity-80" />
        </div>
        <span
          className="text-xs font-medium flex-1 text-center pr-6"
          style={{ color: "var(--text-muted)" }}
        >
          PearShare
        </span>
      </div>

      {/* Peer list */}
      <div className="p-2">
        <p
          className="text-xs font-medium px-2 pt-1 pb-2"
          style={{ color: "var(--text-muted)" }}
        >
          YOUR TAILNET
        </p>
        {peers.map((peer, i) => (
          <div
            key={i}
            className="flex items-center gap-2.5 px-2 py-2 rounded-lg group"
            style={{
              background:
                peer.active ? "var(--accent-subtle)" : "transparent",
            }}
          >
            {/* Avatar */}
            <div
              className="w-7 h-7 rounded-full flex items-center justify-center text-xs font-semibold shrink-0"
              style={{
                background: peer.active
                  ? "var(--accent)"
                  : "var(--bg-subtle)",
                color: peer.active ? "#fff" : "var(--text-secondary)",
              }}
            >
              {peer.initials}
            </div>

            {/* Name + status */}
            <div className="flex-1 min-w-0">
              <p
                className="text-xs font-medium truncate"
                style={{ color: "var(--text-primary)" }}
              >
                {peer.name}
              </p>
              <p
                className="text-xs"
                style={{
                  color: peer.active
                    ? "var(--accent)"
                    : peer.online
                    ? "var(--text-muted)"
                    : "var(--text-muted)",
                  opacity: peer.online ? 1 : 0.5,
                }}
              >
                {peer.active ? "sharing" : peer.online ? "online" : "offline"}
              </p>
            </div>

            {/* Actions */}
            {peer.online && (
              <div className="flex gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                <button
                  className="w-6 h-6 rounded flex items-center justify-center"
                  style={{ background: "var(--bg-subtle)" }}
                  title="Ring"
                >
                  <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                    <path
                      d="M2 2h1.5l.75 2-.875.875a7.5 7.5 0 002.75 2.75L7 7l2 .75V9a1 1 0 01-1 1A8 8 0 012 2z"
                      stroke="var(--text-secondary)"
                      strokeWidth="1"
                      strokeLinejoin="round"
                    />
                  </svg>
                </button>
                <button
                  className="w-6 h-6 rounded flex items-center justify-center"
                  style={{ background: "var(--bg-subtle)" }}
                  title="Share screen"
                >
                  <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                    <rect
                      x="1"
                      y="2"
                      width="10"
                      height="7"
                      rx="1"
                      stroke="var(--text-secondary)"
                      strokeWidth="1"
                    />
                    <path
                      d="M4 10.5h4M6 9v1.5"
                      stroke="var(--text-secondary)"
                      strokeWidth="1"
                      strokeLinecap="round"
                    />
                  </svg>
                </button>
              </div>
            )}
          </div>
        ))}
      </div>

      {/* Status bar */}
      <div
        className="flex items-center gap-2 px-3 py-2 mt-1"
        style={{ borderTop: "1px solid var(--border)" }}
      >
        <div
          className="w-1.5 h-1.5 rounded-full"
          style={{ background: "var(--accent)" }}
        />
        <span className="text-xs" style={{ color: "var(--text-muted)" }}>
          Connected via Tailscale
        </span>
      </div>
    </div>
  );
}
