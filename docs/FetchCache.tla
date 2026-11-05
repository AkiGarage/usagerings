--------------------------- MODULE FetchCache ---------------------------
(* Fetch-cache model for the provider ring "?" bug (2026-11-05).

   Time unit: one hour. goodAt = -1 means "no good reading yet".
   Rules in plain Japanese: docs/fetch-cache-statechart.md
   "?" may be shown only if (no good reading in the last 5h or the reset
   passed) or the account is logged out; a value must never be shown when
   logged out or expired. *)
EXTENDS Naturals, TLC

CONSTANT Horizon,         \* max simulated hour
          RetainOnLogout  \* fault-injection switch: TRUE = logout wrongly keeps the value
VARIABLE goodAt,          \* hour of the last good reading, -1 = never
        now,              \* current hour
        reset,            \* reset hour; at/after it the reading is void
        loggedOut,        \* TRUE after a logout-classified failure
        shown             \* "value" or "?"

TypeOK ==
    /\ goodAt \in -1..Horizon
    /\ now \in 0..Horizon
    /\ reset \in 0..Horizon
    /\ loggedOut \in {TRUE, FALSE}
    /\ shown \in {"value", "?"}

Expired(s) == /\ s.goodAt # -1
               /\ \/ s.now - s.goodAt >= 5
                  \/ s.now >= s.reset

JustifiesQuestion(s) ==
    \/ s.goodAt = -1
    \/ Expired(s)
    \/ s.loggedOut

\* "?" is shown only if (no good reading in last 5h or reset passed) or logged out.
InvQuestionOnlyWhenJustified ==
    shown = "?" => JustifiesQuestion([goodAt |-> goodAt, now |-> now, reset |-> reset, loggedOut |-> loggedOut])

\* Converse: never show a value when logged out or expired (or with no reading).
InvNeverShowValueWhenGone ==
    shown = "value" => /\ goodAt # -1
                       /\ ~Expired([goodAt |-> goodAt, now |-> now, reset |-> reset, loggedOut |-> loggedOut])
                       /\ ~loggedOut

Init ==
    /\ goodAt = -1
    /\ now = 0
    /\ reset = Horizon
    /\ loggedOut = FALSE
    /\ shown = "?"

PollSuccess ==
    /\ now < reset
    /\ goodAt' = now
    /\ loggedOut' = FALSE
    /\ shown' = "value"
    /\ reset' = reset
    /\ now' = now

TransientFail ==
    /\ shown' = IF RetainOnLogout /\ loggedOut THEN shown
                 ELSE IF Expired([goodAt |-> goodAt, now |-> now, reset |-> reset, loggedOut |-> loggedOut])
                          \/ goodAt = -1 \/ loggedOut
                      THEN "?" ELSE "value"
    /\ goodAt' = goodAt
    /\ reset' = reset
    /\ loggedOut' = loggedOut
    /\ now' = now

LogoutFail ==
    /\ loggedOut' = TRUE
    /\ goodAt' = goodAt
    /\ reset' = reset
    /\ shown' = IF RetainOnLogout THEN "value" ELSE "?"
    /\ now' = now

Tick ==
    /\ now < Horizon
    /\ now' = now + 1
    /\ goodAt' = goodAt
    /\ reset' = reset
    /\ loggedOut' = loggedOut
    /\ shown' = IF Expired([goodAt |-> goodAt, now |-> now + 1, reset |-> reset, loggedOut |-> loggedOut])
                      \/ goodAt = -1 \/ loggedOut
                 THEN "?" ELSE "value"

Next == PollSuccess \/ TransientFail \/ LogoutFail \/ Tick

Spec == Init /\ [][Next]_<<goodAt, now, reset, loggedOut, shown>>

=============================================================================
