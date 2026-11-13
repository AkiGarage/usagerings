---- MODULE UsageRefresh ----
EXTENDS Naturals, FiniteSets
CONSTANTS Accts, MaxReq, SingleFlight, RemapById, FailIsFailure, DropStaleAtReset, QueueRequests, GenGuard, PartialMerge, ExpireDeferred
VARIABLES period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained,
          queued, gen, stopped, appliedAfterStop, deferredChanged, deferredExpired
vars == <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained,
          queued, gen, stopped, appliedAfterStop, deferredChanged, deferredExpired>>
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
        /\ deferredChanged = FALSE
        /\ deferredExpired = FALSE

Start == \E targets \in SUBSET Accts :
         /\ awake
         /\ ~stopped
         /\ nextId <= MaxReq
         /\ (SingleFlight => inflight = {})
         /\ inflight' = inflight \cup {[id |-> nextId, period |-> period, order |-> order, gen |-> gen, targets |-> targets]}
         /\ nextId' = nextId + 1
         /\ UNCHANGED <<period, order, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, queued, gen, stopped, appliedAfterStop, deferredChanged, deferredExpired>>

\* refresh() while isRefreshing: a full request is remembered, not dropped (visibility on, cloud on, block expiry).
Request == /\ ~stopped
           /\ inflight # {}
           /\ nextId <= MaxReq
           /\ queued' = TRUE
           /\ UNCHANGED <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, gen, stopped, appliedAfterStop, deferredChanged, deferredExpired>>

\* stop(): timers off, generation bumped, queued request dropped; isRefreshing stays so no second fetch overlaps.
Stop == /\ ~stopped
        /\ gen < 2
        /\ stopped' = TRUE
        /\ gen' = gen + 1
        /\ queued' = FALSE
        /\ UNCHANGED <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, appliedAfterStop, deferredChanged, deferredExpired>>

Restart == /\ stopped
           /\ stopped' = FALSE
           /\ UNCHANGED <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, queued, gen, appliedAfterStop, deferredChanged, deferredExpired>>

Retained(a, r) ==
  LET old == IF RemapById THEN disp[a] ELSE disp[dispOrder[IndexOf(r.order, a)]]
  IN IF old.kind \in {"fresh", "stale"} /\ (DropStaleAtReset => old.period = period)
     THEN [old EXCEPT !.kind = "stale"]
     ELSE [Empty EXCEPT !.kind = "failed"]

\* Account subsets overapproximate provider target groups (including an empty fetch).
\* Untouched values keep their id/period/kind; budgeted values expire on merge.
Deferred(a) == IF ExpireDeferred /\ disp[a].kind \in {"fresh", "stale"} /\ disp[a].period < period
               THEN [Empty EXCEPT !.kind = IF disp[a].kind = "stale" THEN "failed" ELSE "none"]
               ELSE disp[a]

NewDisp(a, r, out) ==
  IF a \notin r.targets /\ PartialMerge THEN Deferred(a)
  ELSE CASE out = "ok" -> [src |-> a, id |-> r.id, period |-> r.period, kind |-> "fresh"]
    [] out = "transient" -> Retained(a, r)
    [] out = "fail" -> IF FailIsFailure THEN [Empty EXCEPT !.kind = "failed"]
                       ELSE [src |-> a, id |-> r.id, period |-> period, kind |-> "fresh"]

\* apply(): a current-generation result updates the display; then a queued full refresh starts at once.
Complete == \E r \in inflight, outs \in [Accts -> Outcomes], targets \in SUBSET Accts :
  LET nd == [a \in Accts |-> NewDisp(a, r, outs[a])]
      applies == r.gen = gen \/ ~GenGuard
      rest == inflight \ {r}
      runQueued == queued /\ ~stopped /\ QueueRequests
  IN /\ inflight' = IF runQueued THEN rest \cup {[id |-> nextId, period |-> period, order |-> order, gen |-> gen, targets |-> targets]} ELSE rest
     /\ nextId' = IF runQueued THEN nextId + 1 ELSE nextId
     /\ queued' = IF runQueued THEN FALSE ELSE queued
     /\ appliedAfterStop' = (appliedAfterStop \/ (applies /\ r.gen # gen))
     /\ deferredChanged' = (deferredChanged \/ (applies /\ \E a \in Accts \ r.targets :
           ~(disp[a].kind \in {"fresh", "stale"} /\ disp[a].period < period) /\ nd[a] # disp[a]))
     /\ deferredExpired' = (deferredExpired \/ (applies /\ \E a \in Accts \ r.targets :
           disp[a].period < period /\ nd[a].kind \in {"fresh", "stale"}))
     /\ IF applies
        THEN /\ disp' = nd
             /\ dispOrder' = r.order
             /\ lastOk' = [a \in Accts |-> IF a \in r.targets \/ ~PartialMerge THEN outs[a] = "ok" ELSE lastOk[a]]
             /\ maxId' = [a \in Accts |-> IF nd[a].kind \in {"fresh", "stale"} /\ nd[a].id > maxId[a] THEN nd[a].id ELSE maxId[a]]
             /\ maxPeriod' = [a \in Accts |-> IF nd[a].kind \in {"fresh", "stale"} /\ nd[a].period > maxPeriod[a] THEN nd[a].period ELSE maxPeriod[a]]
             /\ pastRetained' = \E a \in Accts : nd[a].kind = "stale" /\ nd[a].period < period
        ELSE UNCHANGED <<disp, dispOrder, lastOk, maxId, maxPeriod, pastRetained>>
     /\ UNCHANGED <<period, order, awake, gen, stopped>>

Reset == /\ period = 1
         /\ period' = 2
         /\ UNCHANGED <<order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, queued, gen, stopped, appliedAfterStop, deferredChanged, deferredExpired>>

ExpireStale == \E a \in Accts :
  /\ disp[a].kind = "stale"
  /\ disp[a].period < period
  /\ disp' = [disp EXCEPT ![a] = [Empty EXCEPT !.kind = "failed"]]
  /\ UNCHANGED <<period, order, inflight, nextId, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, queued, gen, stopped, appliedAfterStop, deferredChanged, deferredExpired>>

Reorder == /\ order' \in Orders \ {order}
           /\ UNCHANGED <<period, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, awake, pastRetained, queued, gen, stopped, appliedAfterStop, deferredChanged, deferredExpired>>

Sleep == /\ awake
         /\ awake' = FALSE
         /\ UNCHANGED <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, pastRetained, queued, gen, stopped, appliedAfterStop, deferredChanged, deferredExpired>>

Wake == /\ ~awake
        /\ awake' = TRUE
        /\ UNCHANGED <<period, order, inflight, nextId, disp, dispOrder, maxId, maxPeriod, lastOk, pastRetained, queued, gen, stopped, appliedAfterStop, deferredChanged, deferredExpired>>

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
\* 取得を見送った未失効の値は、観測時刻も成功・失敗状態も更新しない。
DeferredValuesUnchanged == ~deferredChanged
\* 取得を見送ってもリセット前の期限切れの値は表示しない。
DeferredValuesExpire == ~deferredExpired
\* Diagram-only projection. Full verification uses no constraint.
ChartBound == gen = 0 /\ awake /\ period = 1 /\ order = dispOrder /\ nextId <= 2 /\ ~queued
====
