const steps = [
  {
    number: "01",
    title: "Install Tailscale",
    description:
      "PearShare runs on top of your existing Tailscale network. If your team already uses Tailscale, you're ready.",
    cta: { label: "Get Tailscale →", href: "https://tailscale.com" },
  },
  {
    number: "02",
    title: "Download PearShare",
    description:
      "Download the macOS app, drag it to Applications, and launch. No account creation, no setup wizard.",
    cta: null,
  },
  {
    number: "03",
    title: "See your team",
    description:
      "Anyone on your tailnet running PearShare appears immediately. Ring them, share your screen, take control.",
    cta: null,
  },
];

export default function HowItWorks() {
  return (
    <section id="how-it-works" className="py-20">
      <div className="max-w-5xl mx-auto px-6">
        <div className="text-center mb-12">
          <h2
            className="text-2xl font-semibold tracking-tight mb-3"
            style={{ color: "var(--text-primary)" }}
          >
            Up in three steps
          </h2>
          <p
            className="text-base max-w-md mx-auto"
            style={{ color: "var(--text-secondary)" }}
          >
            No accounts to create, no NAT traversal to debug.
          </p>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
          {steps.map((step, i) => (
            <div key={i} className="relative">
              {/* Connector line */}
              {i < steps.length - 1 && (
                <div
                  className="hidden md:block absolute top-7 left-1/2 w-full h-px"
                  style={{
                    background:
                      "linear-gradient(to right, var(--border), transparent)",
                  }}
                />
              )}

              <div className="relative flex flex-col gap-3">
                {/* Step number */}
                <div
                  className="w-14 h-14 rounded-xl flex items-center justify-center text-lg font-bold font-mono"
                  style={{
                    background: "var(--accent-subtle)",
                    color: "var(--accent)",
                    border: "1px solid var(--border)",
                  }}
                >
                  {step.number}
                </div>

                <h3
                  className="text-sm font-semibold"
                  style={{ color: "var(--text-primary)" }}
                >
                  {step.title}
                </h3>
                <p
                  className="text-sm leading-relaxed"
                  style={{ color: "var(--text-secondary)" }}
                >
                  {step.description}
                </p>
                {step.cta && (
                  <a
                    href={step.cta.href}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="text-sm font-medium"
                    style={{ color: "var(--accent)" }}
                  >
                    {step.cta.label}
                  </a>
                )}
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
