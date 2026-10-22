# UsageRings

AIサービスの残り使用量とリセット時刻を、画面に浮かぶ小さなリングで確認するmacOSアプリです。メニューバーの空きに頼らず表示できます。

[English](README.md)

## 表示できるもの

- プロバイダーが返すセッション・週・月などの残り使用量。
- リセット時刻、アカウント別の制限、使用制限中の表示、取得エラー。
- 横・縦のレイアウト、パネルとバーそれぞれの拡大縮小、明暗テーマ、透明度の調整。
- ローカルのClaude Codeログから読み取る使用制限。アカウント名は初期状態で非表示で、表示する場合も一部を伏せます。

全体は約1分ごとに更新します。個別のデータ取得にはキャッシュや、制限に応じた待機時間があります。取得できない値は未取得として扱い、「まだ使える」とは判断しません。UIには日本語と英語が含まれます。

## 対応プロバイダーと必要なもの

| プロバイダー | データ取得元 | 必要な設定 |
| --- | --- | --- |
| OpenAI Codex | CodexBarCLI | CodexBarのインストールとCodex設定 |
| Claude Code | ローカルのCLIProxyAPI。制限表示はClaude Codeログでも補完 | CLIProxyAPIの有効なClaudeアカウント |
| Google Antigravity | ローカルのCLIProxyAPI | プロジェクトIDのある有効なAntigravityアカウント |
| Z.ai / GLM Coding Plan | CodexBarCLI。追加情報はZ.aiのリセット券API | CodexBarのZ.ai設定 |
| Grok | ローカルのCLIProxyAPI | 有効なGrokアカウント |

**macOS 14以降**に対応します。ビルドには **Swift 5.9以降**を含むXcode Command Line Toolsと、固定バージョンのSparkleを取得するインターネット接続が必要です。使用する開発ツールを`xcode-select`で選択してください。

**CodexとGLMの使用量表示には、現在もCodexBarCLIが必要です。** 参照先は `/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI` に固定されており、`PATH`の検索や参照先を変える設定はありません。CodexBarのメニューバーアプリを起動し続ける必要はありません。このCLIがなくても、ほかの取得元が設定済みなら対応する項目は独立して動作します。

Claude・Antigravity・Grokには、既存のCLIProxyAPI（`http://127.0.0.1:8317/v8/management/`）と、macOS Keychainのサービス名 `cliproxyapi-management` の汎用パスワード項目に保存した管理キーが必要です。これらは別途設定してください。UsageRingsにプロキシのインストールやアカウントへのログイン画面はありません。設定が足りない場合はパネルに表示します。

GLMのリセット券詳細は追加機能です。標準のCodexBar設定にあるglobalリージョンのZ.ai APIキーを利用します。この詳細取得は、設定ファイル・API接続先の上書きや複数トークンアカウントに対応していません。

## ビルドとインストール

ソースをダウンロードまたはcloneし、そのディレクトリで実行します。

```sh
swift build
swift test
./script/build_and_run.sh usagerings package
./script/build_and_run.sh usagerings package-verify
```

`package`は `dist/UsageRings.app` を作成します。アプリの起動やインストールは行いません。できたアプリをApplicationsフォルダにドラッグし、開いてください。ソース側のターゲット名は互換性のため `CodexUsageWidget` のままです。複数プロバイダー版を使う場合は、`swift run`で直接起動せず、上記のアプリを使用してください。

ビルド時は `package` を省略しないでください。モードを省略すると従来の `run` 動作になり、起動中のUsageRingsを停止し、`~/Applications/UsageRings.app` を置き換えて起動します。

標準ではad-hoc署名（開発用の簡易署名）を使います。自分の署名IDを指定する場合:

```sh
USAGERINGS_SIGN_IDENTITY='Your signing identity' ./script/build_and_run.sh usagerings package
```

このコマンドは公証や公開を行いません。ad-hoc署名で作り直すと、Keychainへのアクセス許可を再度求められる場合があります。

## 別のマシンにあるClaudeの制限を読む

詳細パネルの **歯車（Settings）** を開き、**Read remote Claude B limits over SSH** を有効にして、ホスト名・SSHの別名・`user@hostname`のいずれかを入力します。**初期状態は無効で、接続先も空です。** 設定はUserDefaultsの `claudeRateLimitSSHEnabled` と `claudeRateLimitSSHHost` にローカル保存されます。

接続先はBash・GNUのコマンド・Python 3を備え、`~/.claude-b/projects` にClaude BのログがあるLinuxマシンを想定しています。SSH認証とホスト鍵の信頼設定を先に済ませてください。アプリは対話入力を行わず、未確認のホスト鍵を自動承認しません。取得間隔は最短5分です。SSHオプション、URL、ポート番号の直接入力はできないため、必要ならSSHの別名を使ってください。変更は次の更新で反映されます。

## プライバシー

設定と表示用スナップショットは **ローカルにのみ保存**します。UsageRings独自のクラウドアカウント、アクセス解析、クラウドへのアップロードはありません。HTTPサーバーやLAN向けサーバーも公開しません。

最新の使用量を取得する通信は必要です。CodexBarCLIは各プロバイダーへ接続し、認証付きのローカルプロキシは各サービスへの要求を仲介します。GLMのリセット券はZ.aiへ直接問い合わせます。リモートClaude監視を有効にすると、指定したホストへのSSH通信も発生します。「ローカルのみ」は保存・処理の説明であり、オフライン動作という意味ではありません。

ローカルClaude監視は `~/.claude/projects`、`~/.claude-a/projects`、`~/.claude-b/projects` の最近のログ末尾を、ファイル数・サイズを制限して読みます。SSHでは制限イベントの文面・時刻・モデル識別子に絞った情報を受け取ります。Codexの表示用スナップショットは `~/Library/Application Support/CodexUsageWidget-Multi/` と、macOSのユーザーごとの一時ディレクトリ（`$TMPDIR`）内の `UsageRings` フォルダ（権限0700、ファイルは0600）に保存し、プロバイダー・使用枠の診断JSONも同じフォルダに保存します。このバージョンは共有の `/private/tmp` に書き込みません（古いビルドが残したファイルは自動では消しません）。SSHでのリモートClaude監視に失敗した場合は、Claudeの欄に接続先を含まない短い理由（「Remote Claude logs」）を表示します。これらは個人の利用情報として扱い、ログや画像を共有する前に内容を確認してください。

## アプリ本体は小さめ

開発者が比較したアプリ本体の参考サイズは、**CodexBarが163 MB、UsageRingsが7.3 MB**です。特定のビルドのディスク上のサイズであり、RAM使用量や全ビルドでの保証値ではありません。UsageRings側の値には、引き続き必要なCodexBarCLIのインストールや、任意のCLIProxyAPIサービスを含みません。UsageRingsは小さな表示に用途を絞っており、CodexBarの幅広いアカウント管理機能を置き換えるものではありません。

## スクリーンショット

画像はすべて内蔵のデモデータです（ダーク表示、バー200%）。

| 閉じたときのバー | ホバーで出る詳細 |
| --- | --- |
| ![リングのバー](docs/images/collapsed-bar.png) | ![ホバーの詳細カード](docs/images/hover-detail.png) |

![詳細パネル](docs/images/panel.png)

リセットチケットは、期限と残り時間つきで1行ずつ並びます。

![リセットチケット](docs/images/reset-tickets.png)

## 開発への参加とライセンス

[CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md)、[行動規範](CODE_OF_CONDUCT.md)をご覧ください。[MIT License](LICENSE)、著作権者はAkiGarageです。外部依存ライブラリには、それぞれのライセンスが適用されます。
