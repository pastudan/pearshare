import { useState } from "react";
import PearIcon from "./PearIcon";

export default function Nav() {
  const [open, setOpen] = useState(false);

  const links = [
    { label: "Features", href: "#features" },
    { label: "How it works", href: "#how-it-works" },
    { label: "Pricing", href: "#pricing" },
    { label: "GitHub", href: "https://github.com/pastudan/pearshare", external: true },
  ];

  return (
    <header
      style={{ borderBottom: "1px solid var(--border)", background: "var(--bg)" }}
      className="sticky top-0 z-50"
    >
      <div className="max-w-5xl mx-auto px-6 h-14 flex items-center justify-between">
        {/* Brand */}
        <a href="/" className="flex items-center gap-2">
          <PearIcon size={22} />
          <span
            className="font-semibold text-sm tracking-tight"
            style={{ color: "var(--text-primary)" }}
          >
            PearShare
          </span>
        </a>

        {/* Desktop nav */}
        <nav className="hidden sm:flex items-center gap-6">
          {links.map((l) => (
            <a
              key={l.label}
              href={l.href}
              target={l.external ? "_blank" : undefined}
              rel={l.external ? "noopener noreferrer" : undefined}
              className="text-sm transition-colors"
              style={{ color: "var(--text-secondary)" }}
            >
              {l.label}
            </a>
          ))}
          <a
            href="#pricing"
            className="text-sm px-3 py-1.5 rounded-md font-medium"
            style={{ background: "var(--accent)", color: "#fff" }}
          >
            Download free
          </a>
        </nav>

        {/* Hamburger button — mobile only */}
        <button
          className="sm:hidden flex flex-col justify-center items-center w-8 h-8 gap-1.5"
          onClick={() => setOpen((o) => !o)}
          aria-label="Toggle menu"
        >
          <span
            className="block w-5 h-px transition-all duration-200"
            style={{
              background: "var(--text-primary)",
              transform: open ? "translateY(4px) rotate(45deg)" : "none",
            }}
          />
          <span
            className="block w-5 h-px transition-all duration-200"
            style={{
              background: "var(--text-primary)",
              opacity: open ? 0 : 1,
            }}
          />
          <span
            className="block w-5 h-px transition-all duration-200"
            style={{
              background: "var(--text-primary)",
              transform: open ? "translateY(-4px) rotate(-45deg)" : "none",
            }}
          />
        </button>
      </div>

      {/* Mobile menu */}
      {open && (
        <div
          className="sm:hidden px-6 pb-4 flex flex-col gap-1"
          style={{ borderTop: "1px solid var(--border)", background: "var(--bg)" }}
        >
          {links.map((l) => (
            <a
              key={l.label}
              href={l.href}
              target={l.external ? "_blank" : undefined}
              rel={l.external ? "noopener noreferrer" : undefined}
              className="text-sm py-2.5"
              style={{
                color: "var(--text-secondary)",
                borderBottom: "1px solid var(--border)",
              }}
              onClick={() => setOpen(false)}
            >
              {l.label}
            </a>
          ))}
          <a
            href="#pricing"
            className="text-sm mt-2 py-2.5 rounded-md font-medium text-center"
            style={{ background: "var(--accent)", color: "#fff" }}
            onClick={() => setOpen(false)}
          >
            Download free
          </a>
        </div>
      )}
    </header>
  );
}
