---- MODULE UsageRead ----
EXTENDS Naturals
\* RetryLogout = FALSE in the real model; Fault-RetryLogout.cfg sets TRUE (breaks the isLogout guard).
CONSTANT RetryLogout
VARIABLES enabled, cli, phase, source, tries, claudeCached
vars == <<enabled, cli, phase, source, tries, claudeCached>>
CliStates == {"ok", "missing", "signedOut", "timeout"}

Init == /\ enabled \in BOOLEAN
        /\ cli \in CliStates
        /\ phase = "idle"
        /\ source = "none"
        /\ tries = 0
        /\ claudeCached \in BOOLEAN

RefreshDisabled == phase = "idle" /\ ~enabled /\ phase' = "hidden" /\ UNCHANGED <<enabled, cli, source, tries, claudeCached>>
RefreshEnabled == phase = "idle" /\ enabled /\ phase' = "fetching" /\ source' = "cli" /\ tries' = 1 /\ UNCHANGED <<enabled, cli, claudeCached>>
ClaudeCacheEmpty == phase = "fetching" /\ ~claudeCached /\ phase' = "pending" /\ UNCHANGED <<enabled, cli, source, tries, claudeCached>>
CliOk == phase \in {"fetching", "pending"} /\ cli = "ok" /\ (phase = "pending" \/ claudeCached) /\ phase' = "shown" /\ claudeCached' = TRUE /\ UNCHANGED <<enabled, cli, source, tries>>
\* MultiUsageService.attempt: a nonzero exit without a partial result is retried once, unless it is a logout.
Retryable(c) == c = "missing" \/ (RetryLogout /\ c = "signedOut")
CliFailsRetry == phase = "fetching" /\ claudeCached /\ Retryable(cli) /\ tries = 1 /\ tries' = 2 /\ UNCHANGED <<enabled, cli, phase, source, claudeCached>>
CliFails == phase \in {"fetching", "pending"} /\ cli \in {"missing", "signedOut"} /\ (phase = "pending" \/ claudeCached) /\ (~Retryable(cli) \/ tries = 2 \/ phase = "pending") /\ phase' = "failed" /\ UNCHANGED <<enabled, cli, source, tries, claudeCached>>
CliTimesOutRetry == phase = "fetching" /\ claudeCached /\ cli = "timeout" /\ tries = 1 /\ tries' = 2 /\ UNCHANGED <<enabled, cli, phase, source, claudeCached>>
CliTimesOutGiveUp == phase \in {"fetching", "pending"} /\ cli = "timeout" /\ (tries = 2 \/ phase = "pending") /\ phase' = "failed" /\ UNCHANGED <<enabled, cli, source, tries, claudeCached>>
UserToggles == phase \in {"shown", "failed", "hidden"} /\ enabled' = ~enabled /\ phase' = "idle" /\ source' = "none" /\ tries' = 0 /\ UNCHANGED <<cli, claudeCached>>
CliChanges == phase \in {"shown", "failed", "hidden"} /\ cli' \in CliStates \ {cli} /\ phase' = "idle" /\ source' = "none" /\ tries' = 0 /\ UNCHANGED <<enabled, claudeCached>>

Next == RefreshDisabled \/ RefreshEnabled \/ ClaudeCacheEmpty \/ CliOk \/ CliFailsRetry \/ CliFails \/ CliTimesOutRetry \/ CliTimesOutGiveUp \/ UserToggles \/ CliChanges

OnlyOfficialCli == source \in {"none", "cli"}
DisabledNeverFetched == ~enabled => (source = "none" /\ phase \in {"idle", "hidden"})
HiddenOnlyWhenDisabled == phase = "hidden" => ~enabled
ShownOnlyWithWorkingCli == phase = "shown" => cli = "ok"
FailedOnlyWithBrokenCli == phase = "failed" => cli # "ok"
BoundedRetries == tries <= 2
\* ログアウト時は再試行しない (a logged-out CLI is never asked twice)
NoRetryOnLogout == cli = "signedOut" => tries <= 1
====
