---- MODULE CodexBarGate ----
EXTENDS Naturals
VARIABLES gate, installed, lastProbe, opens
vars == <<gate, installed, lastProbe, opens>>
States == {"checking", "ready", "guide", "deferred"}

Init == gate = "checking" /\ installed \in BOOLEAN /\ lastProbe = "none" /\ opens = 0

Probe ==
    /\ gate \in {"checking", "guide"}
    /\ lastProbe' = IF installed THEN "yes" ELSE "no"
    /\ gate' = IF installed THEN "ready" ELSE "guide"
    /\ UNCHANGED <<installed, opens>>

OpenDownload ==
    /\ gate = "guide"
    /\ opens' = opens + 1
    /\ gate' = "deferred"
    /\ UNCHANGED <<installed, lastProbe>>

Later ==
    /\ gate = "guide"
    /\ gate' = "deferred"
    /\ UNCHANGED <<installed, lastProbe, opens>>

Relaunch ==
    /\ gate \in {"deferred", "ready"}
    /\ gate' = "checking"
    /\ lastProbe' = "none"
    /\ UNCHANGED <<installed, opens>>

UserInstalls ==
    /\ ~installed
    /\ installed' = TRUE
    /\ UNCHANGED <<gate, lastProbe, opens>>

UserRemoves ==
    /\ installed
    /\ installed' = FALSE
    /\ UNCHANGED <<gate, lastProbe, opens>>

Next == Probe \/ OpenDownload \/ Later \/ Relaunch \/ UserInstalls \/ UserRemoves

Spec == Init /\ [][Next]_vars
OpensBound == opens <= 2

TypeOK == gate \in States /\ installed \in BOOLEAN /\ lastProbe \in {"none", "yes", "no"} /\ opens \in Nat
ReadyOnlyAfterYes == gate = "ready" => lastProbe = "yes"
GuideOnlyAfterNo == gate = "guide" => lastProbe = "no"
CheckingHasNoProbe == gate = "checking" => lastProbe = "none"
====
