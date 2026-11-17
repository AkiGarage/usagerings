---- MODULE ResetRefresh ----
EXTENDS Naturals, FiniteSets
CONSTANTS Once, SingleFlight, StopGuard, CurrentGuard, OneTimer
VARIABLES knownAt, now, deadline, timers, consumed, counts, running, stopped, afterStop, obsolete
vars == <<knownAt, now, deadline, timers, consumed, counts, running, stopped, afterStop, obsolete>>
Init == /\ knownAt = 0 /\ now = 0 /\ deadline = 0 /\ timers = {}
        /\ consumed = {} /\ counts = [d \in 1..2 |-> 0]
        /\ running = 0 /\ stopped = FALSE /\ afterStop = FALSE /\ obsolete = FALSE
Plan(d) == IF stopped \/ running > 0 \/ d = 0 \/ (Once /\ d \in consumed) THEN {} ELSE {d}
\* A conclusive snapshot replaces the known future deadline; repeated snapshots coalesce.
Learn == \E d \in 1..2 :
    /\ ~stopped /\ d > knownAt
    /\ deadline' = d
    /\ timers' = IF OneTimer THEN Plan(d) ELSE timers \cup Plan(d)
    /\ UNCHANGED <<knownAt, now, consumed, counts, running, stopped, afterStop, obsolete>>
Tick == /\ now < 3 /\ now' = now + 1
        /\ UNCHANGED <<knownAt, deadline, timers, consumed, counts, running, stopped, afterStop, obsolete>>
\* Regular fetches use the same single-flight slot.
Poll == /\ ~stopped /\ running = 0 /\ running' = 1 /\ knownAt' = now
        /\ UNCHANGED <<now, deadline, timers, consumed, counts, stopped, afterStop, obsolete>>
\* A busy callback leaves the reset unconsumed; apply() re-plans on completion.
Busy == /\ running > 0 /\ timers # {} /\ timers' = {}
        /\ UNCHANGED <<knownAt, now, deadline, consumed, counts, running, stopped, afterStop, obsolete>>
Complete == /\ running > 0 /\ running' = running - 1
            /\ timers' = IF running = 1 THEN IF stopped \/ deadline = 0 \/ (Once /\ deadline \in consumed) THEN {} ELSE {deadline} ELSE {}
            /\ UNCHANGED <<knownAt, now, deadline, consumed, counts, stopped, afterStop, obsolete>>
\* Includes an already queued callback for either an old deadline or a cancelled timer.
Fire == \E d \in 1..2 :
    /\ d <= now /\ counts[d] < 2
    /\ (Once => d \notin consumed)
    /\ (SingleFlight => running = 0)
    /\ (StopGuard => ~stopped)
    /\ (CurrentGuard => d \in timers /\ d = deadline)
    /\ timers' = {} /\ consumed' = consumed \cup {d}
    /\ counts' = [counts EXCEPT ![d] = @ + 1]
    /\ running' = running + 1
    /\ knownAt' = now
    /\ afterStop' = (afterStop \/ stopped)
    /\ obsolete' = (obsolete \/ d # deadline)
    /\ UNCHANGED <<now, deadline, stopped>>
Stop == /\ ~stopped /\ stopped' = TRUE
        /\ timers' = IF StopGuard THEN {} ELSE timers
        /\ UNCHANGED <<knownAt, now, deadline, consumed, counts, running, afterStop, obsolete>>
Idle == UNCHANGED vars
Next == Learn \/ Tick \/ Poll \/ Busy \/ Complete \/ Fire \/ Stop \/ Idle
\* 同じリセットで専用取得を2回開始しない。
AtMostOnce == \A d \in 1..2 : counts[d] <= 1
\* 取得中に別の取得を開始しない。
AtMostOneFetch == running <= 1
\* 停止後にタイマーで取得を開始しない。
NoFetchAfterStop == ~afterStop
\* 差し替え済みの期限では取得しない。
OnlyCurrentDeadline == ~obsolete
\* 保留タイマーはプロバイダーごとに最大1個である。
AtMostOneTimer == Cardinality(timers) <= 1
====
