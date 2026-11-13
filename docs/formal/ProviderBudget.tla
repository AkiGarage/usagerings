---- MODULE ProviderBudget ----
EXTENDS Naturals
CONSTANTS Horizon, MaxChecks, RespectInterval, AllowOverride, ErrorBackoff, KeepUserReason
VARIABLES now, due, failures, checks, running, target, queued, lastAdmission,
          lastDelay, lastFailureCount, lostUser
vars == <<now, due, failures, checks, running, target, queued, lastAdmission,
          lastDelay, lastFailureCount, lostUser>>
Reasons == {"automatic", "user", "reset"}
Delay(n) == CASE n = 0 -> 1 [] n = 1 -> 2 [] n = 2 -> 4 [] OTHER -> 8
Eligible(reason, at, deadline) == reason # "automatic" \/ at >= deadline
Targets(reason, at, deadline) ==
    (reason # "automatic" /\ AllowOverride) \/ at >= deadline \/ ~RespectInterval
Admission(reason) == [reason |-> reason, at |-> now, deadline |-> due,
                      fetched |-> Targets(reason, now, due)]
Init == /\ now = 0 /\ due = 0 /\ failures = 0 /\ checks = 0
        /\ running = FALSE /\ target = FALSE /\ queued = "none"
        /\ lastAdmission = [reason |-> "automatic", at |-> 0, deadline |-> 0, fetched |-> TRUE]
        /\ lastDelay = 1 /\ lastFailureCount = 0 /\ lostUser = FALSE
Start(reason) ==
    /\ ~running /\ checks < MaxChecks
    /\ running' = TRUE /\ checks' = checks + 1
    /\ target' = Targets(reason, now, due)
    /\ lastAdmission' = Admission(reason)
    /\ UNCHANGED <<now, due, failures, queued, lastDelay, lastFailureCount, lostUser>>
Request(reason) ==
    /\ running /\ reason \in {"automatic", "user"}
    /\ queued' = IF reason = "user" /\ KeepUserReason THEN "user"
                 ELSE IF queued = "user" THEN "user" ELSE "automatic"
    /\ lostUser' = (lostUser \/ (reason = "user" /\ queued' # "user"))
    /\ UNCHANGED <<now, due, failures, checks, running, target, lastAdmission, lastDelay, lastFailureCount>>
Complete(failed) ==
    LET count == IF failed THEN IF failures < 3 THEN failures + 1 ELSE 3 ELSE 0
        delay == IF ErrorBackoff THEN Delay(count) ELSE 1
        deadline == IF target THEN now + delay ELSE due
        again == queued # "none" /\ checks < MaxChecks
    IN /\ running
       /\ due' = deadline
       /\ failures' = IF target THEN count ELSE failures
       /\ lastDelay' = IF target THEN delay ELSE lastDelay
       /\ lastFailureCount' = IF target THEN count ELSE lastFailureCount
       /\ running' = again
       /\ checks' = IF again THEN checks + 1 ELSE checks
       /\ queued' = "none"
       /\ target' = IF again THEN Targets(queued, now, deadline) ELSE target
       /\ lastAdmission' = IF again
            THEN [reason |-> queued, at |-> now, deadline |-> deadline,
                  fetched |-> Targets(queued, now, deadline)] ELSE lastAdmission
       /\ UNCHANGED <<now, lostUser>>
Tick == /\ now < Horizon /\ now' = now + 1
        /\ UNCHANGED <<due, failures, checks, running, target, queued, lastAdmission,
                       lastDelay, lastFailureCount, lostUser>>
Done == /\ ~running /\ checks = MaxChecks /\ now = Horizon /\ UNCHANGED vars
Next == (\E reason \in Reasons : Start(reason))
        \/ (\E reason \in {"automatic", "user"} : Request(reason))
        \/ (\E failed \in BOOLEAN : Complete(failed)) \/ Tick \/ Done
TypeOK == /\ now \in 0..Horizon /\ failures \in 0..3 /\ checks \in 0..MaxChecks
          /\ due \in 0..(Horizon + 8) /\ running \in BOOLEAN /\ target \in BOOLEAN
          /\ queued \in Reasons \cup {"none"}
\* 自動取得は、前回の結果から通常間隔または失敗時の待機時間を空ける。
AutomaticRespectsBudget == lastAdmission.reason = "automatic" /\ lastAdmission.fetched
                           => lastAdmission.at >= lastAdmission.deadline
\* 手動更新とリセット更新は、予算の待機中でも取得する。
ExplicitBypassesBudget == lastAdmission.reason # "automatic" => lastAdmission.fetched
\* 連続失敗は待機を2倍・4倍・8倍にし、成功は通常間隔に戻す。
BackoffMatchesOutcome == lastDelay = Delay(lastFailureCount)
\* 取得中の手動更新を、その後の自動更新で通常更新に戻さない。
QueuedUserSurvives == ~lostUser
\* Diagram-only projection; full verification retains all eight ticks and four checks.
ChartBound == now <= 1 /\ checks <= 1 /\ queued = "none"
====
