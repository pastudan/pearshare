export default function Privacy() {
  const updated = "March 31, 2026";

  return (
    <div
      className="max-w-2xl mx-auto px-6 py-16"
      style={{ color: "var(--text-primary)" }}
    >
      <a
        href="/"
        className="inline-flex items-center gap-1.5 text-sm mb-10"
        style={{ color: "var(--text-muted)" }}
      >
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
          <path
            d="M9 11L5 7l4-4"
            stroke="currentColor"
            strokeWidth="1.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
        Back to pearshare.app
      </a>

      <h1
        className="text-3xl font-semibold tracking-tight mb-2"
        style={{ color: "var(--text-primary)" }}
      >
        Privacy Policy
      </h1>
      <p className="text-sm mb-10" style={{ color: "var(--text-muted)" }}>
        Last updated: {updated}
      </p>

      <div className="flex flex-col gap-8" style={{ color: "var(--text-secondary)" }}>
        <section>
          <h2
            className="text-base font-semibold mb-2"
            style={{ color: "var(--text-primary)" }}
          >
            Overview
          </h2>
          <p className="text-sm leading-relaxed">
            PearShare is built on a simple principle: your data stays between
            you and the people you choose to share with. We do not operate relay
            servers, we do not collect personal information, and we do not
            transmit anything to PearShare infrastructure. This document
            explains exactly what happens — and what doesn't.
          </p>
        </section>

        <section>
          <h2
            className="text-base font-semibold mb-2"
            style={{ color: "var(--text-primary)" }}
          >
            Data we do not collect
          </h2>
          <ul className="text-sm leading-relaxed flex flex-col gap-1.5 list-disc list-inside">
            <li>No account registration or login</li>
            <li>No usage analytics or telemetry</li>
            <li>No crash reports sent to our servers</li>
            <li>No screen capture, audio, or video stored or transmitted to us</li>
            <li>No IP addresses or device identifiers logged</li>
          </ul>
        </section>

        <section>
          <h2
            className="text-base font-semibold mb-2"
            style={{ color: "var(--text-primary)" }}
          >
            How screen sharing and audio work
          </h2>
          <p className="text-sm leading-relaxed">
            All screen capture, video, and audio streams are sent directly from
            your device to your peer over an encrypted WireGuard tunnel provided
            by Tailscale. Nothing passes through PearShare servers — there are
            none. Streams are never recorded or stored by the app.
          </p>
        </section>

        <section>
          <h2
            className="text-base font-semibold mb-2"
            style={{ color: "var(--text-primary)" }}
          >
            Tailscale
          </h2>
          <p className="text-sm leading-relaxed">
            PearShare uses Tailscale as its network layer. Tailscale handles
            peer discovery and encrypted tunneling using your existing Tailscale
            account and tailnet. PearShare does not have access to your
            Tailscale credentials. Please refer to{" "}
            <a
              href="https://tailscale.com/privacy-policy"
              target="_blank"
              rel="noopener noreferrer"
              style={{ color: "var(--accent)" }}
            >
              Tailscale's Privacy Policy
            </a>{" "}
            for information on how Tailscale handles your data.
          </p>
        </section>

        <section>
          <h2
            className="text-base font-semibold mb-2"
            style={{ color: "var(--text-primary)" }}
          >
            License key and payment
          </h2>
          <p className="text-sm leading-relaxed">
            If you purchase a PearShare Pro license, payment is processed by{" "}
            <a
              href="https://www.paddle.com/legal/privacy"
              target="_blank"
              rel="noopener noreferrer"
              style={{ color: "var(--accent)" }}
            >
              Paddle
            </a>
            , our merchant of record. PearShare does not receive or store your
            payment details. When activating a license key in the app, the key
            is sent to Paddle's verification API to confirm its validity. No
            other personal data is transmitted during this process.
          </p>
        </section>

        <section>
          <h2
            className="text-base font-semibold mb-2"
            style={{ color: "var(--text-primary)" }}
          >
            Local data storage
          </h2>
          <p className="text-sm leading-relaxed">
            PearShare stores your activated license key locally in the macOS
            Keychain. No other personal data is written to disk beyond standard
            macOS application preferences.
          </p>
        </section>

        <section>
          <h2
            className="text-base font-semibold mb-2"
            style={{ color: "var(--text-primary)" }}
          >
            Open source
          </h2>
          <p className="text-sm leading-relaxed">
            PearShare is fully open source. You can inspect exactly what the app
            does — including all network calls — in the{" "}
            <a
              href="https://github.com/pastudan/pearshare"
              target="_blank"
              rel="noopener noreferrer"
              style={{ color: "var(--accent)" }}
            >
              GitHub repository
            </a>
            .
          </p>
        </section>

        <section>
          <h2
            className="text-base font-semibold mb-2"
            style={{ color: "var(--text-primary)" }}
          >
            Changes to this policy
          </h2>
          <p className="text-sm leading-relaxed">
            If we make material changes to this policy, we will update the date
            at the top of this page and note the change in the GitHub repository.
          </p>
        </section>

        <section>
          <h2
            className="text-base font-semibold mb-2"
            style={{ color: "var(--text-primary)" }}
          >
            Contact
          </h2>
          <p className="text-sm leading-relaxed">
            Questions? Reach us at{" "}
            <a
              href="mailto:support@pearshare.app"
              style={{ color: "var(--accent)" }}
            >
              support@pearshare.app
            </a>
            .
          </p>
        </section>
      </div>
    </div>
  );
}
