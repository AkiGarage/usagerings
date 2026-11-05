# 取得キャッシュの状態モデル（fetch-cache）

2026-11-05 の "?" リング不具合（1回の取得失敗で前回値が消える）の修正に対する状態モデル。
対象は `MultiUsageService` / `ClaudeCLIUsage` → `MultiUsageStore.retainingStaleValues` の流れ。

## 日本語でのルール（不変条件の元になる文）

1. リングに「?」を出してよいのは、(a) 直近5時間に良い取得値がない、(b) リセット時刻を過ぎている、(c) ログアウトしている、のいずれかの場合だけ。
2. 一時的な失敗（タイムアウト、起動失敗、通信エラー、プロバイダエラー・HTTP 5xx/429、パース失敗）では前回の良い値を「Stale」表示で保持し、5時間またはリセット期限まで示し続ける。
3. ログアウト（CLI が not logged in / unauthorized / 401 / no credentials / login required / please log in / not authenticated を明示）では前回値を保持せず「?」とする。ログアウトは一時失敗として再試行しない。
4. 逆に、ログアウト中か、値の期限（5時間またはリセット）が切れているのに数値を示してはならない。
5. 一時的な失敗は1回だけ（約2.5秒後に）再試行する。部分結果として使える出力（複数アカウントの一部のみ失敗）は再試行しない。
6. 失敗の診断のため、1失敗につき1行（時刻・プロバイダ・理由・終了コード・マスク済みメッセージ）を `fetch-failures.log` に追記する。秘密は決して書かない。

## 状態遷移図

```mermaid
stateDiagram-v2
    [*] --> NoReading
    NoReading --> Fresh : Poll成功（良い取得値）
    Fresh --> Fresh : Poll成功
    Fresh --> Stale : 一時的失敗（timeout/launch/transport/providerError）\n前回値を保持しStale表示
    Stale --> Fresh : Poll成功
    Stale --> Stale : 一時的失敗（5h未満かつリセット前）
    Stale --> Expired : now-goodAt>=5h または resetPassed\n（「?」を表示）
    Fresh --> LoggedOut : logout失敗\n（「?」を表示、保持しない）
    Stale --> LoggedOut : logout失敗
    LoggedOut --> Fresh : 再ログイン後 Poll成功
    Expired --> Fresh : Poll成功
    NoReading --> LoggedOut : logout失敗
    LoggedOut --> LoggedOut : logout失敗（再試行しない）
    Expired --> Expired : 失敗が続く限り「?」
```

## TLA+ 仕様

`FetchCache.tla`（設定 `FetchCache.cfg`）が上のモデルを形式化し、次を不変条件として検証する。

- `InvQuestionOnlyWhenJustified`: `shown = "?" => (goodAt = -1 \/ now - goodAt >= 5 \/ now >= reset \/ loggedOut)`
- `InvNeverShowValueWhenGone`: `shown = "value" => (goodAt # -1 /\ now - goodAt < 5 /\ now < reset /\ ~loggedOut)`

`FetchCacheFault.cfg` は「ログアウトしても前回値を保持する」故障注入（`RetainOnLogout = TRUE`）で、
不変条件がその故障を検出することを確認するために使う。

TLC はこの環境に入っていないため、同等の全状態探索を `docs/fetch_cache_check.py`（Python, 標準ライブラリのみ）で行う。
実行: `python3 -B docs/fetch_cache_check.py`（正常系は OK、故障系は violation を報告して終了コード1）。
