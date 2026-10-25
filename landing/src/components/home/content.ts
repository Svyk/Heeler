// Homepage copy shared by its sections. Copy changes should stay in sync
// with README.md at the repo root, where most of it comes from.

export const hero = {
  lede: 'A native iOS companion for <a class="text-link" href="https://herdr.dev">herdr</a>, the agent-first terminal runtime, over plain SSH.',
};

export const consoleCopy = {
  body: "Every Agent across your machines in one status-sorted list (Blocked comes first), filterable by Host, updating live off herdr's event stream.",
};

export const steerCopy = {
  body: 'Through libghostty, with Metal rendering, native scrollback, momentum touch scrolling that drives full-screen TUIs, and long-press selection. Draft locally with the full standard iOS keyboard (autocorrect, IME, dictation), then Send the complete message once as a single <span class="mono">agent.prompt</span> RPC.',
};

export const connect = {
  lede: "The app speaks herdr's JSON API, newline-delimited JSON over a Unix socket, through SSH. SSH access plus a running herdr server is the whole prerequisite.",
  pairNote:
    'The <span class="mono">pair</span> action opens a Pairing Code QR. Scan it and the machine is added as a Host. Nothing to type.',
};

export const path = [
  { node: 'Heeler.app', note: 'iPhone' },
  { node: 'jump host', note: 'optional · VPS loopback' },
  { node: 'sshd', note: 'stream-local forwarding' },
  { node: 'herdr.sock', note: 'ndjson rpc + events' },
  { node: 'agent pane', note: 'pty · takeover' },
];

export const pairLines = [
  '<span class="tk-comment"># on the machine running herdr</span>',
  '<span class="tk-fn">herdr</span> plugin install ZingerLittleBee/Heeler <span class="tk-string">--ref plugin --yes</span>',
  '<span class="tk-fn">herdr</span> plugin action invoke heeler.pair',
];

// The closing steps' commands, wrapped so every line fits a phone-width column.
export const addCommandLines = [
  '<span class="tk-fn">herdr</span> plugin install \\',
  '  ZingerLittleBee/Heeler \\',
  '  <span class="tk-string">--ref plugin --yes</span>',
  '<span class="tk-fn">herdr</span> plugin action invoke heeler.pair',
];

export const security = [
  {
    title: 'Device Key in the Keychain',
    body: 'An Ed25519 Device Key is generated on device during QR pairing; the private key stays in the Keychain, and the Pairing Code pins the host key fingerprint.',
  },
  {
    title: 'End-to-end encrypted notifications',
    body: 'The relay sees the device token, source IP, request timing, and ciphertext, but cannot read the notification.',
  },
  {
    title: 'Verified at both hops',
    body: 'Behind a Jump Host, host keys are verified independently at each hop.',
  },
  {
    title: 'No new surface area',
    body: 'No herdr server changes and no extra packages. The Host’s SSH server must permit stream-local forwarding, the OpenSSH default.',
  },
];

export const faq = [
  {
    q: 'What do I need on the machine?',
    a: 'Node &gt;= 20, herdr &gt;= 0.7.5, and an OpenSSH server enabled. On macOS that is System Settings &gt; General &gt; Sharing &gt; Remote Login.',
  },
  {
    q: 'Does it work on iPad?',
    a: 'Native iPad support is restored in 0.1.8, with Magic Keyboard shortcuts, multiple windows, and drag and drop. <a class="text-link" href="/ipad">See the iPad screenshots</a>.',
  },
  {
    q: 'What happens to the terminal I already had open?',
    a: 'Attach and Reattach use herdr takeover mode, disconnecting the previous terminal owner when necessary.',
  },
  {
    q: 'Is it affiliated with herdr?',
    a: 'No. Heeler is an independent, personal-use-first project on the App Store and is not affiliated with the herdr project.',
  },
  {
    q: 'Where can I read the design decisions?',
    a: 'In <span class="mono">docs/adr/</span>. The transport story in particular is not obvious.',
  },
];

export const source = {
  title: 'Open source, Apache-2.0.',
  lede: 'Heeler is built in public and shaped by daily driving. Clone it, run it on the simulator, and send back what breaks.',
  links: [
    { href: 'https://github.com/ZingerLittleBee/Heeler', label: 'Star on GitHub' },
    { href: 'https://github.com/ZingerLittleBee/Heeler/issues', label: 'Open an issue' },
    { href: 'https://github.com/ZingerLittleBee/Heeler/blob/main/CONTRIBUTING.md', label: 'Contributing guide' },
  ],
  buildLines: [
    '<span class="tk-comment"># run it on the simulator</span>',
    '<span class="tk-fn">brew</span> install xcodegen',
    '<span class="tk-fn">git</span> clone <span class="tk-string">https://github.com/ZingerLittleBee/Heeler</span>',
    '<span class="tk-fn">cd</span> Heeler &amp;&amp; <span class="tk-fn">make</span> sim',
  ],
};

export const links = {
  appStore: 'https://apps.apple.com/us/app/heeler-for-herdr/id6797263135',
  testFlight: 'https://testflight.apple.com/join/aXSxRn4r',
  setup: 'https://docs.heeler.bybee.dev/pairing',
};
