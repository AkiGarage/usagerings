---- MODULE OpenDesignRead ----
EXTENDS Naturals
CONSTANT Fault
VARIABLES enabled, phase, io, valid, status
vars == <<enabled, phase, io, valid, status>>
Init == /\ enabled \in BOOLEAN /\ phase = "idle" /\ io = 0 /\ valid = FALSE /\ status = 0
Start == /\ phase = "idle"
         /\ phase' = IF enabled \/ Fault = "disabled" THEN "credential" ELSE "hidden"
         /\ io' = IF enabled \/ Fault = "disabled" THEN 1 ELSE 0
         /\ UNCHANGED <<enabled, valid, status>>
Credential == /\ phase = "credential" /\ phase' \in {"directory", "login"}
              /\ io' = IF phase' = "directory" THEN 2 ELSE io
              /\ UNCHANGED <<enabled, valid, status>>
Directory == /\ phase = "directory" /\ phase' \in {"funding", "failure", "login"}
             /\ io' = IF phase' = "funding" THEN 3 ELSE io
             /\ UNCHANGED <<enabled, valid, status>>
Funding == /\ phase = "funding" /\ status' \in {200, 401, 403, 500}
           /\ valid' \in BOOLEAN
           /\ phase' = IF status' = 401 \/ (Fault = "forbidden" /\ status' = 403) THEN "login"
                        ELSE IF status' = 200 /\ (valid' \/ Fault = "invalid") THEN "shown" ELSE "failure"
           /\ UNCHANGED <<enabled, io>>
Done == /\ phase \in {"hidden", "login", "failure", "shown"} /\ UNCHANGED vars
Next == Start \/ Credential \/ Directory \/ Funding \/ Done
\* 無効にしたOpenDesignの認証情報を読まず、通信もしない。
DisabledNoIO == ~enabled => io = 0
\* 検証に失敗した応答を残量として表示しない。
OnlyValidatedQuota == phase = "shown" => (status = 200 /\ valid)
\* 403を再ログインが必要な状態として扱わない。
ForbiddenIsNotLogout == status = 403 => phase = "failure"
====
