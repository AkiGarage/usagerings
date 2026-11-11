---- MODULE VerticalTabFit ----
EXTENDS Naturals
CONSTANT Fault
VARIABLES chosen, saved, screen, orientation, rendered
vars == <<chosen, saved, screen, orientation, rendered>>
\* Discrete zooms stand for the minimum, normal and maximum values.
\* A short screen fits up to normal; a tall screen fits the maximum.
Fit(z, s, o) == IF o = "vertical" /\ s = "short" /\ z > 1 /\ Fault # "noFit" THEN 1 ELSE z
Init == /\ chosen \in 0..2 /\ saved = chosen /\ screen = "tall"
        /\ orientation = "horizontal" /\ rendered = chosen
ChangeScreenOrOrientation ==
    /\ screen' \in {"short", "tall"} /\ orientation' \in {"horizontal", "vertical"}
    /\ rendered' = IF Fault = "stuck" /\ screen' = "tall" THEN rendered ELSE Fit(saved, screen', orientation')
    /\ saved' = IF Fault = "overwrite" THEN rendered' ELSE saved
    /\ UNCHANGED chosen
Next == ChangeScreenOrOrientation
\* 画面に合わせて縮小しても、保存した拡大率を変えない。
SavedZoomUnchanged == saved = chosen
\* 縦表示は、その画面に収まる拡大率で描画する。
FitsScreen == (orientation = "vertical" /\ screen = "short") => rendered <= 1
\* 大きい画面や横表示では、利用者が選んだ拡大率に戻る。
RestoresZoom == (screen = "tall" \/ orientation = "horizontal") => rendered = chosen
====
