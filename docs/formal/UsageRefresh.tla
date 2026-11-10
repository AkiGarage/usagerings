---- MODULE UsageRefresh ----
EXTENDS Naturals, FiniteSets
CONSTANTS Accts, MaxReq, SingleFlight, RemapById, FailIsFailure, DropStaleAtReset, QueueRequests, GenGuard
VARIABLES period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained,
          queued, gen, stopped, appliedAfterStop
vars == <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained,
          queued, gen, stopped, appliedAfterStop>>
\* queued: a full refresh asked for while a fetch is in flight (MultiUsageStore queued flag).
\* gen/stopped: stop() bumps the generation; a fetch from an older generation is not applied.
Aux == <<queued, gen, stopped, appliedAfterStop>>

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
        /\ queued = FALSE
        /\ gen = 0
        /\ stopped = FALSE
        /\ appliedAfterStop = FALSE

Start == /\ awake
         /\ ~stopped
         /\ nextId <= MaxReq
         /\ (SingleFlight => inflight = {})
         /\ inflight' = inflight \cup {[id |-> nextId, period |-> period, order |-> order, gen |-> gen]}
         /\ nextId' = nextId + 1
         /\ UNCHANGED <<period, order, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, queued, gen, stopped, appliedAfterStop>>

\* refresh() while isRefreshing: a full request is remembered, not dropped (visibility on, cloud on, block expiry).
Request == /\ ~stopped
           /\ inflight # {}
           /\ nextId <= MaxReq
           /\ queued' = TRUE
           /\ UNCHANGED <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, gen, stopped, appliedAfterStop>>

\* stop(): timers off, generation bumped, queued request dropped; isRefreshing stays so no second fetch overlaps.
Stop == /\ ~stopped
        /\ gen < 2
        /\ stopped' = TRUE
        /\ gen' = gen + 1
        /\ queued' = FALSE
        /\ UNCHANGED <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, appliedAfterStop>>

Restart == /\ stopped
           /\ stopped' = FALSE
           /\ UNCHANGED <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, queued, gen, appliedAfterStop>>

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

\* apply(): a current-generation result updates the display; then a queued full refresh starts at once.
Complete == \E r \in inflight, outs \in [Accts -> Outcomes] :
  LET nd == [a \in Accts |-> NewDisp(a, r, outs[a])]
      applies == r.gen = gen \/ ~GenGuard
      rest == inflight \ {r}
      runQueued == queued /\ ~stopped /\ QueueRequests
  IN /\ inflight' = IF runQueued THEN rest \cup {[id |-> nextId, period |-> period, order |-> order, gen |-> gen]} ELSE rest
     /\ nextId' = IF runQueued THEN nextId + 1 ELSE nextId
     /\ queued' = IF runQueued THEN FALSE ELSE queued
     /\ appliedAfterStop' = (appliedAfterStop \/ (applies /\ r.gen # gen))
     /\ IF applies
        THEN /\ disp' = nd
             /\ dispOrder' = r.order
             /\ lastOk' = [a \in Accts |-> outs[a] = "ok"]
             /\ maxId' = [a \in Accts |-> IF nd[a].kind \in {"fresh", "stale"} /\ nd[a].id > maxId[a] THEN nd[a].id ELSE maxId[a]]
             /\ maxPeriod' = [a \in Accts |-> IF nd[a].kind \in {"fresh", "stale"} /\ nd[a].period > maxPeriod[a] THEN nd[a].period ELSE maxPeriod[a]]
             /\ pastRetained' = \E a \in Accts : nd[a].kind = "stale" /\ nd[a].period < period
        ELSE UNCHANGED <<disp, dispOrder, lastOk, maxId, maxPeriod, pastRetained>>
     /\ UNCHANGED <<period, order, awake, gen, stopped>>

Reset == /\ period = 1
         /\ period' = 2
         /\ UNCHANGED <<order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, queued, gen, stopped, appliedAfterStop>>

ExpireStale == \E a \in Accts :
  /\ disp[a].kind = "stale"
  /\ disp[a].period < period
  /\ disp' = [disp EXCEPT ![a] = [Empty EXCEPT !.kind = "failed"]]
  /\ UNCHANGED <<period, order, inflight, nextId, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, queued, gen, stopped, appliedAfterStop>>

Reorder == /\ order' \in Orders \ {order}
           /\ UNCHANGED <<period, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, queued, gen, stopped, appliedAfterStop>>

Sleep == /\ awake
         /\ awake' = FALSE
         /\ UNCHANGED <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, pastRetained, queued, gen, stopped, appliedAfterStop>>

Wake == /\ ~awake
        /\ awake' = TRUE
        /\ UNCHANGED <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, pastRetained, queued, gen, stopped, appliedAfterStop>>

Next == Start \/ Request \/ Stop \/ Restart \/ Complete \/ Reset \/ ExpireStale \/ Reorder \/ Sleep \/ Wake

TypeOK == /\ disp \in [Accts -> [src : Accts \cup {"none"}, id : 0..MaxReq, period : 0..2, kind : Kinds]]
          /\ awake \in BOOLEAN

NoCrossAccount == \A a \in Accts : disp[a].kind \in {"fresh", "stale"} => disp[a].src = a
StaleNeverOverwritesNewer == \A a \in Accts : disp[a].kind \in {"fresh", "stale"} => disp[a].id = maxId[a]
FailureNeverShownAsSuccess == \A a \in Accts : disp[a].kind = "fresh" => lastOk[a]
OldPeriodNeverOverwritesNew == \A a \in Accts : disp[a].kind \in {"fresh", "stale"} => disp[a].period = maxPeriod[a]
AtMostOneFetch == Cardinality(inflight) <= 1
RetainedNeverFromPastPeriod == ~pastRetained
\* 取得中に頼まれた更新は捨てられず、取得が終われば必ず次の取得が始まる
NoLostRefreshRequest == queued => inflight # {}
\* 停止より前に始まった取得の結果は、停止後の表示に反映されない
NoApplyAfterStop == ~appliedAfterStop
====
