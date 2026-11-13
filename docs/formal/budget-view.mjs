export const title = "UsageRings: provider refresh budget (one check projection)";
export const state = (v) => {
  if (v.running) return v.target ? "Fetching provider" : "Provider deferred";
  if (v.due > v.now) return v.failures ? "Error backoff" : "Normal interval wait";
  return "Provider eligible";
};
export const step = (action) => ({
  Start: "refresh admitted or deferred", Complete: "record outcome and next eligible time",
  Request: "remember full refresh reason", Tick: "clock advances",
}[action] ?? action);
