# TalkFit サーバーのデプロイ手順

Mac の Claude Code にこのファイルを渡して「この手順でデプロイして」と頼めば、
コマンドはすべて Claude Code が実行します。人がやるのは ★ の付いた操作だけです。

## 0. 必要なもの

| もの | 取得先 | 費用 |
|---|---|---|
| Cloudflare アカウント | https://dash.cloudflare.com/sign-up | 無料（Workers Free） |
| OpenAI APIキー | https://platform.openai.com/api-keys | 従量課金。最初に $10 チャージで十分 |
| Anthropic APIキー（任意） | https://console.anthropic.com/settings/keys | 従量課金。ほぼ使わない |
| Stripe アカウント | https://dashboard.stripe.com/register | 決済ごとに 3.6% |

## 1. Cloudflare にログインして DB を作る

```bash
cd worker
npm install
npx wrangler login              # ★ ブラウザが開くので「許可」を押す
npx wrangler d1 create talkfit  # 出力された database_id を wrangler.toml に貼る
npm run db:init                 # テーブル作成
```

## 2. 秘密情報を登録する

値は Claude Code に貼らず、プロンプトに直接入力する（★）。

```bash
npx wrangler secret put OPENAI_API_KEY      # ★ sk-... を入力
npx wrangler secret put ANTHROPIC_API_KEY   # ★ sk-ant-...（無ければ適当な文字列でよい）
npx wrangler secret put ADMIN_KEY           # ★ 管理画面用の長いランダム文字列（自分で決める）
npx wrangler secret put IP_SALT             # ★ 任意のランダム文字列
```

## 3. デプロイ

```bash
npm run deploy
```

出力された `https://talkfit-api.<あなたの名前>.workers.dev` を、リポジトリ直下の
`config.js` の `apiBase` に入れてコミット・プッシュする。これでアプリはAPIキーなしで動く。

動作確認： `https://talkfit-api.<...>.workers.dev/health` が `{"ok":true}` を返すこと。

## 4. Stripe（課金を始める時）

1. ★ Stripe で本人確認と口座登録を済ませる（特商法の表記ページ URL を求められる：
   `https://gfe25.github.io/talkfit/legal/tokushoho.html`）
2. ★ 商品「TalkFit Pro」を作り、価格を2つ作る：月額 ¥680（毎月）、年額 ¥5,800（毎年）
3. ★ それぞれ Payment Link を作る。「支払い後」→「ウェブサイトにリダイレクト」に
   `https://gfe25.github.io/talkfit/?checkout=success` を設定。あわせて「プロモーションコードを許可する」をオン（トレーナー向けの無料クーポン配布に使う）
4. ★ 設定 → Billing → カスタマーポータル を有効化（解約は「期間終了時」）。ログインリンクを控える
5. ★ 開発者 → Webhook → エンドポイント追加
   - URL：`https://talkfit-api.<...>.workers.dev/v1/stripe/webhook`
   - イベント：`checkout.session.completed` `customer.subscription.updated` `customer.subscription.deleted`
   - 署名シークレット（whsec_...）を控える
6. 登録：
   ```bash
   npx wrangler secret put STRIPE_WEBHOOK_SECRET   # ★ whsec_...
   ```
   `wrangler.toml` の `PAYMENT_LINK_MONTHLY` `PAYMENT_LINK_YEARLY` `PORTAL_URL` に URL を入れて `npm run deploy`

Stripe は最初「テストモード」で作り、テスト用カード `4242 4242 4242 4242` で
1回通してから本番モードに切り替えること。

## 5. 管理画面

`https://talkfit-api.<...>.workers.dev/admin?key=<ADMIN_KEY>`

MRR・有料会員数・新規・DAU・音声利用・D7継続率・ファネルが日別で見られる。

## 料金・上限を変える

`wrangler.toml` の `[vars]` を変えて `npm run deploy`。アプリの再配布は不要。
価格を変える時は Stripe 側の価格と Payment Link も必ず合わせる。

## 費用の目安

- Cloudflare：無料枠（1日10万リクエスト、D1書き込み1日10万行）。
  1回のトレーニング（約60分）で書き起こしは約200リクエスト。
  1日あたり300回のトレーニングを超えたら Workers Paid（$5/月）へ。
- OpenAI：gpt-4o-mini-transcribe。音が入った区間だけ送るので、1回のトレーニングで
  数円〜十数円。ヘビーユーザーでも月 ¥100〜150 程度の想定。
- 管理画面の「分」列で実際の音声分数を毎週確認し、想定を外れたら上限
  `MAX_AUDIO_SEC_PER_DAY` を調整する。

## テスト

```bash
npm test               # Worker 単体（モックの OpenAI/Anthropic/Stripe で29項目）
cd .. && python3 tests/e2e.py   # 実ブラウザ＋実Worker（20項目）
```
