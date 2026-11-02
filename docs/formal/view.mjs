export const title = "UsageRings: reading Antigravity / Grok / Claude via official CLIs";
export const state = (v) => ({
  idle: "Waiting for refresh", hidden: "Ring off (not read)", fetching: "Asking the official CLI",
  pending: "Claude: waiting for first value", shown: "Ring shows usage", failed: "Ring shows a setup/error notice",
}[v.phase]);
export const group = (v) => ({ shown: "good", failed: "bad", hidden: "off" }[v.phase] ?? "busy");
export const colors = { good: "teal", bad: "orange", off: "tan", busy: "blue" };
export const step = (a) => ({
  RefreshDisabled: "refresh runs [ring is off]", RefreshEnabled: "refresh runs [ring is on]",
  ClaudeCacheEmpty: "no cached Claude value yet", CliOk: "the CLI returns usage",
  CliFails: "CLI missing or signed out", CliTimesOutRetry: "the CLI times out once, retry",
  CliTimesOutGiveUp: "the CLI times out again", UserToggles: "you turn the ring on/off",
  CliChanges: "you install / sign in / sign out of the CLI",
}[a] ?? a);
