export const title = "UsageRings: first-run CodexBar check";
export const state = (v) => ({
  checking: "Checking for CodexBar", ready: "CodexBar found, app runs",
  guide: "Guide shown: Download / Check Again / Later", deferred: "Guide closed until next launch",
}[v.gate]);
export const group = (v) => ({ ready: "good", guide: "bad", deferred: "off" }[v.gate] ?? "busy");
export const colors = { good: "teal", bad: "orange", off: "tan", busy: "blue" };
export const step = (a) => ({
  Probe: "look for CodexBarCLI", OpenDownload: "you press Download (opens CodexBar page)",
  Later: "you press Later", Relaunch: "app launches again",
  UserInstalls: "you install CodexBar", UserRemoves: "you remove CodexBar",
}[a] ?? a);
