export const title = "UsageRings: partial refresh and retained observations (one request projection)";
export const state = (v) => {
  if (v.inflight.length) return "Fetching selected providers";
  const values = Object.values(v.disp);
  if (values.some((a) => a.kind === "stale")) return "Retained after transient failure";
  if (values.some((a) => a.kind === "fresh")) return "Showing observed usage";
  if (values.some((a) => a.kind === "failed")) return "Showing failure";
  return "No observation";
};
export const step = (action) => ({
  Start: "refresh selects provider targets", Complete: "merge selected results and preserve untouched values",
}[action] ?? action);
