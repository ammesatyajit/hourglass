import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description: "How Hourglass protects your iMessage history and what limited website data is processed.",
};

export default function PrivacyPolicy() {
  return (
    <main className="policy-page">
      <header className="policy-nav">
        <a className="brand" href="../" aria-label="Back to Hourglass home">
          <img src="../hourglass-icon.png" alt="" width="34" height="34" />
          <span>Hourglass</span>
        </a>
        <a className="policy-back" href="../">← Back to site</a>
      </header>

      <article className="policy-shell">
        <div className="policy-kicker">PRIVACY POLICY</div>
        <h1>Your conversations<br />are not our data.</h1>
        <p className="policy-intro">
          Hourglass is designed so your iMessage history stays on your Mac. The app
          does not upload your messages, contacts, attachments, searches, or AI questions.
        </p>
        <div className="policy-meta"><span>Effective August 15, 2026</span><span>Version 1.0</span></div>

        <section>
          <h2>1. What the app accesses</h2>
          <p>
            With your permission, Hourglass reads the macOS Messages database and local
            Contacts data needed to resolve names. macOS requires Full Disk Access for this.
            Access is read-only: Hourglass does not edit, delete, or send messages.
          </p>
        </section>

        <section>
          <h2>2. Where processing happens</h2>
          <p>
            Search indexing, keyword search, dashboard calculations, and Cactus Needle 2
            AI query routing run locally on your Mac. The private index is stored in your
            local Application Support folder. Needle 2 is bundled with the app, so AI search
            does not require a model download or a cloud request.
          </p>
        </section>

        <section>
          <h2>3. Data the app does not collect</h2>
          <ul>
            <li>Message text, attachments, reactions, or conversation metadata</li>
            <li>Contacts or phone numbers</li>
            <li>Search queries or AI questions</li>
            <li>Usage analytics, advertising identifiers, or behavioral profiles</li>
            <li>Account credentials—Hourglass does not require an account</li>
          </ul>
        </section>

        <section>
          <h2>4. Network activity</h2>
          <p>
            The app may connect to the Hourglass update feed when checking for a new release.
            Downloading the app or an update necessarily sends a standard web request to the
            download host. The download service records an aggregate count by release and
            download type; it does not receive your messages or searches. Infrastructure
            providers may process ordinary request metadata such as IP address and user agent
            for security and delivery operations under their own policies.
          </p>
        </section>

        <section>
          <h2>5. This website</h2>
          <p>
            This marketing site does not set advertising cookies and does not ask for an
            account. If the host keeps short-lived operational logs, they are used only to
            deliver and protect the site. Clicking the download button takes you through the
            versioned Hourglass download endpoint described above.
          </p>
        </section>

        <section>
          <h2>6. Your control</h2>
          <p>
            You can revoke Full Disk Access at any time in System Settings. You can remove
            Hourglass and its local index by deleting the app and its Application Support data.
            Your original Messages database remains under macOS control and is not changed by
            Hourglass.
          </p>
        </section>

        <section>
          <h2>7. Open source and changes</h2>
          <p>
            Hourglass is open source, so its behavior can be inspected. If this policy changes,
            the effective date above will be updated. Material privacy changes will be called
            out in the project’s release notes.
          </p>
        </section>

        <section>
          <h2>8. Questions</h2>
          <p>
            For privacy questions, open an issue in the public Hourglass repository or contact
            the project maintainer through GitHub.
          </p>
          <a className="text-link" href="https://github.com/ammesatyajit/hourglass/issues" rel="noreferrer">
            Contact the project on GitHub ↗
          </a>
        </section>
      </article>

      <footer className="policy-footer">
        <span>Hourglass</span><span>Nothing leaves your computer.</span><a href="../">Home</a>
      </footer>
    </main>
  );
}
