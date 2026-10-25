// Copy for pairing popup startup failures. The TUI paints these and waits
// for a key so herdr does not close the pane before the user can read them.

export const MISSING_STATE_DIR =
  "HERDR_PLUGIN_STATE_DIR is not set. Run this popup through herdr.";

export const MISSING_HOST_KEY = [
  "No SSH host key found under /etc/ssh.",
  "",
  "Enable Remote Login (System Settings > General > Sharing), or run:",
  "  sudo ssh-keygen -A",
  "Then invoke pairing again.",
].join("\n");

export const MISSING_ADDRESS =
  "No routable network address found. Connect to a LAN or VPN and retry.";

export function pairingStartFailed(errorMessage) {
  return `Could not start pairing: ${errorMessage}`;
}

export function fatalLines(message) {
  return ["Pairing cannot start", "", message, "", "Press any key to close."];
}
