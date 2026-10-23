# TalkFit — 開発メモ（Claude Code 向け）

声だけで筋トレを記録する PWA。セット後に「ベンチ80キロ10回」とつぶやくと、
種目・重量・回数が記録される。ゴールは **MRR ¥100,000（有料会員 約170人）**。

## 構成

- `index.html` — アプリ本体（単一ファイル、Vanilla JS）。データは端末の localStorage
- `config.js` — 公開設定（サーバーURL `apiBase`、シェア用 `shareHost`）。秘密情報は書かない
- `worker/` — Cloudflare Worker + D1。書き起こし／解析の中継、利用権判定、Stripe、計測、管理画面
  - デプロイ手順は `worker/DEPLOY.md`
- `lp/` — ランディングページ、`legal/` — 規約・プライバシー・特商法
- `docs/` — ローンチ計画（LAUNCH.md）と集客の素材（GROWTH.md）
- `tests/e2e.py` — 実ブラウザ（偽マイク）＋実Workerランタイムで、記録→課金→引き継ぎまで通す

## 守ること

- 変更したら `index.html` の `const BUILD` を1つ上げ、`config.js?v=` も合わせる
  （iOS はキャッシュが強く、実機が新コードを読めたかをビルド番号で確認している）
- APIキーをリポジトリに絶対に書かない（Public リポジトリ。GitHub の検出で自動失効した過去がある）
- 課金判定はサーバー（`worker/src/index.js` の `entitlement`）に集約する。アプリ側の判定は表示用
- 計測イベント名は Worker の `EVENT_NAMES` に追加しないと捨てられる
- 変更後は `cd worker && npm test` と `python3 tests/e2e.py` を通す
- コミットメッセージは日本語で、なぜ変えたかを書く

## プラン

- 初回から14日：全機能無料（カード登録なし）
- 以降の無料：手入力・履歴は無制限、音声は月4日まで
- Pro：¥680/月、¥5,800/年（Stripe Payment Link、`client_reference_id` に端末ID）
- 機種変更は「引き継ぎコード」（XXXX-XXXX）
