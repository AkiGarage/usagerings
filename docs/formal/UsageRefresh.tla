---- MODULE UsageRefresh ----
EXTENDS Naturals, FiniteSets
CONSTANTS Accts, MaxReq, SingleFlight, RemapById, FailIsFailure, DropStaleAtReset
VARIABLES period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained
vars == <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained>>

Orders == {o \in [1..2 -> Accts] : o[1] # o[2]}
Kinds == {"none", "fresh", "stale", "failed"}
Empty == [src |-> "none", id |-> 0, period |-> 0, kind |-> "none"]
Outcomes == {"ok", "transient", "fail"}
IndexOf(o, a) == CHOOSE i \in 1..2 : o[i] = a

Init == /\ period = 1
        /\ order \in Orders
        /\ dispOrder = order
        /\ inflight = {}
        /\ nextId = 1
        /\ disp = [a \in Accts |-> Empty]
        /\ maxId = [a \in Accts |-> 0]
        /\ maxPeriod = [a \in Accts |-> 0]
        /\ lastOk = [a \in Accts |-> FALSE]
        /\ awake = TRUE
        /\ pastRetained = FALSE

Start == /\ awake
         /\ nextId <= MaxReq
         /\ (SingleFlight => inflight = {})
         /\ inflight' = inflight \cup {[id |-> nextId, period |-> period, order |-> order]}
         /\ nextId' = nextId + 1
         /\ UNCHANGED <<period, order, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained>>

Retained(a, r) ==
  LET old == IF RemapById THEN disp[a] ELSE disp[dispOrder[IndexOf(r.order, a)]]
  IN IF old.kind \in {"fresh", "stale"} /\ (DropStaleAtReset => old.period = period)
     THEN [old EXCEPT !.kind = "stale"]
     ELSE [Empty EXCEPT !.kind = "failed"]

NewDisp(a, r, out) ==
  CASE out = "ok" -> [src |-> a, id |-> r.id, period |-> r.period, kind |-> "fresh"]
    [] out = "transient" -> Retained(a, r)
    [] out = "fail" -> IF FailIsFailure THEN [Empty EXCEPT !.kind = "failed"]
                       ELSE [src |-> a, id |-> r.id, period |-> period, kind |-> "fresh"]

Complete == \E r \in inflight, outs \in [Accts -> Outcomes] :
  LET nd == [a \in Accts |-> NewDisp(a, r, outs[a])]
  IN /\ inflight' = inflight \ {r}
     /\ disp' = nd
     /\ dispOrder' = r.order
     /\ lastOk' = [a \in Accts |-> outs[a] = "ok"]
     /\ maxId' = [a \in Accts |-> IF nd[a].kind \in {"fresh", "stale"} /\ nd[a].id > maxId[a] THEN nd[a].id ELSE maxId[a]]
     /\ maxPeriod' = [a \in Accts |-> IF nd[a].kind \in {"fresh", "stale"} /\ nd[a].period > maxPeriod[a] THEN nd[a].period ELSE maxPeriod[a]]
     /\ pastRetained' = \E a \in Accts : nd[a].kind = "stale" /\ nd[a].period < period
     /\ UNCHANGED <<period, order, nextId, awake>>

Reset == /\ period = 1
         /\ period' = 2
         /\ UNCHANGED <<order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained>>

ExpireStale == \E a \in Accts :
  /\ disp[a].kind = "stale"
  /\ disp[a].period < period
  /\ disp' = [disp EXCEPT ![a] = [Empty EXCEPT !.kind = "failed"]]
  /\ UNCHANGED <<period, order, inflight, nextId, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained>>

Reorder == /\ order' \in Orders \ {order}
           /\ UNCHANGED <<period, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained>>

Sleep == /\ awake
         /\ awake' = FALSE
         /\ UNCHANGED <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, pastRetained>>

Wake == /\ ~awake
        /\ awake' = TRUE
        /\ UNCHANGED <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, pastRetained>>

Next == Start \/ Complete \/ Reset \/ ExpireStale \/ Reorder \/ Sleep \/ Wake

TypeOK == /\ disp \in [Accts -> [src : Accts \cup {"none"}, id : 0..MaxReq, period : 0..2, kind : Kinds]]
          /\ awake \in BOOLEAN

NoCrossAccount == \A a \in Accts : disp[a].kind \in {"fresh", "stale"} => disp[a].src = a
StaleNeverOverwritesNewer == \A a \in Accts : disp[a].kind \in {"fresh", "stale"} => disp[a].id = maxId[a]
FailureNeverShownAsSuccess == \A a \in Accts : disp[a].kind = "fresh" => lastOk[a]
OldPeriodNeverOverwritesNew == \A a \in Accts : disp[a].kind \in {"fresh", "stale"} => disp[a].period = maxPeriod[a]
AtMostOneFetch == Cardinality(inflight) <= 1
RetainedNeverFromPastPeriod == ~pastRetained
====
