import PearIcon from "./PearIcon";

export default function Nav() {
  return (
    <header
      style={{
        borderBottom: "1px solid var(--border)",
        background: "var(--bg)",
      }}
      className="sticky top-0 z-50"
    >
      <div className="max-w-5xl mx-auto px-6 h-14 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <PearIcon size={22} />
          <span
            className="font-semibold text-sm tracking-tight"
            style={{ color: "var(--text-primary)" }}
          >
            PearShare
          </span>
        </div>

        <nav className="flex items-center gap-6">
          <a
            href="#features"
            className="text-sm transition-colors"
            style={{ color: "var(--text-secondary)" }}
          >
            Features
          </a>
          <a
            href="#how-it-works"
            className="text-sm transition-colors"
            style={{ color: "var(--text-secondary)" }}
          >
            How it works
          </a>
          <a
            href="#pricing"
            className="text-sm transition-colors"
            style={{ color: "var(--text-secondary)" }}
          >
            Pricing
          </a>
          <a
            href="https://github.com/pastudan/pearshare"
            target="_blank"
            rel="noopener noreferrer"
            className="text-sm transition-colors"
            style={{ color: "var(--text-secondary)" }}
          >
            GitHub
          </a>
          <a
            href="#pricing"
            className="text-sm px-3 py-1.5 rounded-md font-medium transition-colors"
            style={{
              background: "var(--accent)",
              color: "#fff",
            }}
          >
            Download free
          </a>
        </nav>
      </div>
    </header>
  );
}
