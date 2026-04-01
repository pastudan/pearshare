import PearIcon from "./PearIcon";

export default function Footer() {
  return (
    <footer
      style={{ borderTop: "1px solid var(--border)" }}
      className="py-8"
    >
      <div className="max-w-5xl mx-auto px-6 flex flex-col sm:flex-row items-center justify-between gap-4">
        {/* Brand */}
        <div className="flex items-center gap-2">
          <PearIcon size={18} />
          <span
            className="text-sm font-medium"
            style={{ color: "var(--text-secondary)" }}
          >
            PearShare
          </span>
        </div>

        {/* Links */}
        <nav className="flex items-center gap-5">
          <a
            href="/privacy"
            className="text-xs transition-colors"
            style={{ color: "var(--text-muted)" }}
          >
            Privacy Policy
          </a>
          <a
            href="https://github.com/pastudan/pearshare"
            target="_blank"
            rel="noopener noreferrer"
            className="text-xs transition-colors"
            style={{ color: "var(--text-muted)" }}
          >
            GitHub
          </a>
          <a
            href="mailto:support@pearshare.app"
            className="text-xs transition-colors"
            style={{ color: "var(--text-muted)" }}
          >
            Support
          </a>
        </nav>

        <p className="text-xs" style={{ color: "var(--text-muted)" }}>
          © {new Date().getFullYear()} PearShare
        </p>
      </div>
    </footer>
  );
}
