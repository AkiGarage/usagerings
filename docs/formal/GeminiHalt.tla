---- MODULE GeminiHalt ----
EXTENDS Naturals
\* Gemini 停止の期限付き回復 (Sources/CodexUsageWidget/Services/GeminiAppUsage.swift, sync f87c804)。
\* 停止は時刻を記録し、60分で期限が切れて再試行する。読めるページが停止を解く。
\* 一時エラー表示では停止しない。値を保存できるのは usage ページを正常に読めた時だけ。
\* 1時間単位 = 5分。quiet hours・画面スリープ・アイドル・時計巻き戻しは bounds (docs/formal の SKILL.md 参照)。
\*
\* 実装のスイッチ。本体 cfg はすべて FALSE。各 Fault-*.cfg は1つだけ TRUE にする。
CONSTANT HaltNeverExpires,  \* TRUE = 停止の期限切れを無効化 (Fault-GeminiHaltForever)
           ReadWhileHalted,  \* TRUE = shouldRead が haltBlocking を無視して停止中も読む (Fault-GeminiReadWhileHalted)
           TransientHalts,   \* TRUE = 一時エラー (.pageError) でも halt させる (Fault-GeminiTransientHalts)
           Fabricate         \* TRUE = 非 usage ページでも値を保存する (Fault-GeminiFabricate)

VARIABLES active, halted, sinceHalt, sinceRead, page, shown, saved, goodReads,
          haltSource, lastReadHaltAge
vars == <<active, halted, sinceHalt, sinceRead, page, shown, saved, goodReads, haltSource, lastReadHaltAge>>

\* GeminiReadPolicy.haltRetryAfter = 60分 = 12単位。停止からの経過は12で飽和する
\* (12 = 期限切れ。haltedAt の無い古い停止データ = すぐ再試行、も同じ状態で表す)。
CapHalt == 12
\* 前回読取からの経過の飽和上限 (GeminiReadPolicy.interval = 5分 = 1単位)。
CapRead == 12
Interval == 1
\* 保存回数・正常読取回数の上限。model を有限にするだけの打ち切り。
SaveCap == 2

\* usage = 数字が読めるページ / verify = 確認ページ (.blocked。JS無効・許可なし等の
\* halt する失敗も同じ効果なのでこの1つに折る) / transientError = 一時エラー表示
\* (.pageError。タブなし・タイムアウト・スリープ中も保存も停止もしない点で同じ)。
Pages == {"usage", "verify", "transientError"}
\* value = 新鮮な値 / staleValue = cachedOrUnknown のキャッシュ表示 / unknown = 不明。
ShownVals == {"value", "staleValue", "unknown"}
HaltSources == {"none", "verify", "transient"}
\* 読取時の停止経過。停止中でない読みは 13 (= CapHalt+1) で表す
\* (TLC は文字列と数値の混合 set を fingerprint できないため数値で符号化する)。
NoHaltAge == CapHalt + 1
Min(a, b) == IF a < b THEN a ELSE b

\* GeminiReadPolicy.haltBlocking: 停止してから60分未満なら読まない。
BlockingHalt == halted /\ (HaltNeverExpires \/ sinceHalt < CapHalt)

\* GeminiReadPolicy.shouldRead (監視オン・停止でない・前回の読取から5分)。
ShouldRead == active /\ (ReadWhileHalted \/ ~BlockingHalt) /\ sinceRead >= Interval

\* 起動状態: メニューのオン/オフの再現。再起動しても停止は UserDefaults に残る
\* (古い停止は期限切れ、新しい停止は経過も残る) ので、Init は両方を許す。
Init == /\ active \in BOOLEAN
        /\ halted \in BOOLEAN
        /\ sinceHalt \in 0..CapHalt
        /\ sinceRead \in 0..CapRead
        /\ page \in Pages
        /\ shown \in ShownVals
        /\ saved \in 0..SaveCap
        /\ goodReads \in 0..SaveCap
        /\ haltSource \in HaltSources
        /\ lastReadHaltAge \in {NoHaltAge}
        /\ saved <= goodReads
        /\ (~halted) => sinceHalt = 0
        /\ (shown = "value") => saved > 0
        /\ (halted => haltSource = "verify")
        /\ (~halted => haltSource = "none")

\* 時間経過 (1単位 = 5分)。監視オフでも時計は進む。
Tick == /\ sinceRead' = Min(sinceRead + 1, CapRead)
        /\ sinceHalt' = IF halted THEN Min(sinceHalt + 1, CapHalt) ELSE 0
        /\ UNCHANGED <<active, halted, page, shown, saved, goodReads, haltSource, lastReadHaltAge>>

\* 環境: ページの中身が変わる (読める / 確認ページ / 一時エラー表示)。
PageChanges == /\ page' \in Pages \ {page}
               /\ UNCHANGED <<active, halted, sinceHalt, sinceRead, shown, saved, goodReads, haltSource, lastReadHaltAge>>

\* メニューのトグル (setEnabled): setHalted(false) で停止を即クリア。lastRead は
\* 保持するので、トグル自体は読取の間隔を縮めない (読みは Read が担う)。
MenuToggle == /\ active' = ~active
              /\ halted' = FALSE
              /\ sinceHalt' = 0
              /\ haltSource' = "none"
              /\ shown' = IF saved > 0 THEN "staleValue" ELSE "unknown"
              /\ UNCHANGED <<sinceRead, page, saved, goodReads, lastReadHaltAge>>

\* この読みで停止するか: 確認ページ (.blocked)、または一時エラーで停止させる故障。
ReadHalt == page = "verify" \/ (page = "transientError" /\ TransientHalts)

\* GeminiAppUsageMonitor.tick の読み取り (shouldRead が真の時だけ)。結果は page で分岐:
\* usage = 数字が読めた (save + setHalted(false, at: now))、verify = .blocked (haltText →
\* setHalted(true, at: now) で時計をやり直す)、transientError = .pageError (保存も停止も変えない)。
Read == /\ ShouldRead
        /\ sinceRead' = 0
        /\ halted' = IF ReadHalt THEN TRUE ELSE IF page = "usage" THEN FALSE ELSE halted
        /\ haltSource' = IF ReadHalt THEN (IF page = "verify" THEN "verify" ELSE "transient")
                         ELSE IF page = "usage" THEN "none" ELSE haltSource
        \* 停止の (再) 開始は haltedAt=now。実装通り、pageError だけ haltedAt を変えない。
        /\ sinceHalt' = IF halted' /\ ~ReadHalt THEN sinceHalt ELSE 0
        \* 読取時に停止中だったか (ガードをすり抜けた読みを不変条件で捕まえる記録)。
        /\ lastReadHaltAge' = IF halted THEN sinceHalt ELSE NoHaltAge
        /\ saved' = IF page = "usage" \/ Fabricate THEN Min(saved + 1, SaveCap) ELSE saved
        /\ goodReads' = IF page = "usage" THEN Min(goodReads + 1, SaveCap) ELSE goodReads
        /\ shown' = IF page = "usage" THEN "value"
                    ELSE IF saved' > 0 THEN "staleValue" ELSE "unknown"
        /\ UNCHANGED <<active, page>>

Next == Tick \/ PageChanges \/ MenuToggle \/ Read

Spec == Init /\ [][Next]_vars
        \* 時間は進み続け、読める状態が続くなら必ず読む (活性のための公平性)。
        /\ WF_vars(Tick)
        /\ WF_vars(Read)

TypeOK == /\ active \in BOOLEAN
          /\ halted \in BOOLEAN
          /\ sinceHalt \in 0..CapHalt
          /\ sinceRead \in 0..CapRead
          /\ page \in Pages
          /\ shown \in ShownVals
          /\ saved \in 0..SaveCap
          /\ goodReads \in 0..SaveCap
          /\ haltSource \in HaltSources
          /\ lastReadHaltAge \in 0..NoHaltAge
          /\ (~halted) => (sinceHalt = 0 /\ haltSource = "none")
          /\ halted => haltSource # "none"

\* 停止から60分未満は読まない (shouldRead は haltBlocking を見る)。
\* lastReadHaltAge >= CapHalt = 期限切れ (12) か停止中でない読み (13)。
NoReadWhileFreshHalt == lastReadHaltAge >= CapHalt

\* 確認ページや一時エラーのページでは値を保存しない (保存数は usage を正常に読めた回数を超えない)。
NoFabrication == saved <= goodReads

\* 一時エラーでは停止状態にならない (.pageError は halted も haltedAt も変えない)。
TransientNeverHalts == ~halted \/ haltSource = "verify"

\* 停止しても、監視がオンでページが読めるままなら、いずれ停止は解ける (期限付き再試行)。
HaltEventuallyRetried == [] ( (halted /\ page = "usage" /\ active) =>
                               ( [] (page = "usage" /\ active) => <> ~halted ) )
====
