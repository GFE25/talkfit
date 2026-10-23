# TalkFit サーバーの公開手順

ターミナルは使いません。ブラウザでアカウントを作り、GitHub に鍵を登録して、ボタンを押すだけです。
所要時間は約30分。押した後は、DB作成・公開・アプリの接続先の書き換えまで自動で進みます。

## 1. Cloudflare（無料）

1. https://dash.cloudflare.com/sign-up で登録し、メール認証を済ませる
2. 左メニュー「Workers & Pages」を一度開く（初回の案内が出たら閉じてよい）
3. 右上の人型アイコン → 「プロフィール」→ 「API トークン」→ 「トークンを作成」
   - テンプレート「Cloudflare Workers を編集」の「テンプレートを使用」
   - 「権限」に1行追加：**アカウント ／ D1 ／ 編集**
   - 「アカウント リソース」で自分のアカウントを選び、「概要に進む」→「トークンを作成」
   - 表示されたトークンをコピー（一度しか表示されない）→ これが **CLOUDFLARE_API_TOKEN**
4. 「Workers & Pages」の画面右側にある「アカウント ID」をコピー → これが **CLOUDFLARE_ACCOUNT_ID**

## 2. OpenAI

1. https://platform.openai.com/settings/organization/billing で $10 をチャージ
2. https://platform.openai.com/api-keys →「Create new secret key」→ コピー → これが **OPENAI_API_KEY**
3. （任意）https://platform.openai.com/settings/organization/limits で月の上限を $30 に設定しておくと安心

## 3. GitHub に鍵を登録

https://github.com/GFE25/talkfit/settings/secrets/actions/new を開き、1つずつ「Name」と「Secret」を入れて登録。

| Name | 中身 |
|---|---|
| `CLOUDFLARE_API_TOKEN` | 1-3 のトークン |
| `CLOUDFLARE_ACCOUNT_ID` | 1-4 のアカウントID |
| `OPENAI_API_KEY` | 2-2 のキー |
| `ADMIN_KEY` | 管理画面に入るための合言葉。20文字以上の好きな英数字（パスワード管理アプリで生成すると楽） |
| `ANTHROPIC_API_KEY` | 任意。無くても動く（複雑な言い回しの解析精度が少し下がるだけ） |

鍵は GitHub の中で暗号化され、コードにもチャットにも出ません。

## 4. 公開ボタンを押す

https://github.com/GFE25/talkfit/actions/workflows/deploy-api.yml →「Run workflow」→「Run workflow」

3〜5分で緑のチェックが付けば完了です。実行結果の画面にサーバーのURLと管理画面のURLが表示されます。
アプリの接続先は自動で書き換わり、数分後にはAPIキーなしで動くようになります。

失敗した時は、赤いバツを開くと日本語で原因が出ます（鍵の登録漏れ、トークンの権限不足など）。直して再実行してください。何度実行しても壊れません。

## 5. 決済（Stripe）— 公開後に並行して

審査に1〜3日かかるので、無料体験だけで公開を始めてから進めて問題ありません。決済リンクが無い間、アプリの課金画面は「まもなく受付開始」と表示されます。

1. https://dashboard.stripe.com/register で登録 → 本人確認・口座登録
   （ウェブサイトURL：`https://gfe25.github.io/talkfit/lp/`、特商法表記：`https://gfe25.github.io/talkfit/legal/tokushoho.html`）
2. 商品カタログ →「TalkFit Pro」を作成し、価格を2つ：**¥680 毎月**、**¥5,800 毎年**
3. それぞれ「支払いリンク」を作成
   - 「支払い後」→「ウェブサイトにリダイレクト」→ `https://gfe25.github.io/talkfit/?checkout=success`
   - 「プロモーションコードを許可」をオン（トレーナー向けの無料クーポンに使う）
4. 設定 → Billing → カスタマーポータル を有効化（解約は「請求期間の終了時」）。ログインリンクを控える
5. 開発者 → Webhook →「送信先を追加」
   - URL：手順4の実行結果に出た「Webhook の登録先」
   - イベント：`checkout.session.completed` / `customer.subscription.updated` / `customer.subscription.deleted`
   - 作成後に表示される署名シークレット（whsec_…）を控える
6. GitHub に登録
   - Secrets（https://github.com/GFE25/talkfit/settings/secrets/actions/new）：`STRIPE_WEBHOOK_SECRET` = whsec_…
   - Variables（https://github.com/GFE25/talkfit/settings/variables/actions/new）：
     `PAYMENT_LINK_MONTHLY` / `PAYMENT_LINK_YEARLY` / `PORTAL_URL` = 3と4のURL
7. もう一度「公開ボタン」（手順4）を押す

最初はStripeの「テスト環境」で作り、テストカード `4242 4242 4242 4242` で1回通してから本番に切り替えること
（本番に切り替えたら、本番の支払いリンクとWebhookで5〜7をやり直す）。

## 管理画面

`https://talkfit-api.<…>.workers.dev/admin?key=<ADMIN_KEY>`

MRR・有料会員数・新規・DAU・音声利用・7日後継続率・ファネルが日別で見られます。

## 料金や上限を変える

`worker/wrangler.toml` の `[vars]` を書き換えて main に入れると、自動で再公開されます。
価格を変える時は Stripe 側の価格と支払いリンクも必ず合わせること。

## 費用の目安

- Cloudflare：無料枠（1日10万リクエスト）。1回のトレーニングで書き起こし約200リクエストなので、
  1日300回のトレーニングを超えたら Workers Paid（$5/月）へ
- OpenAI：音が入った区間だけ送るので、ヘビーユーザーでも月¥100〜150程度の想定。
  管理画面の「分」列で毎週確認し、ずれたら `MAX_AUDIO_SEC_PER_DAY` を調整

## 手元で動かす・テストする（開発者向け）

```bash
cd worker && npm install
npm test                         # Worker 単体（モックで29項目）
cd .. && python3 tests/e2e.py    # 実ブラウザ＋実Worker（23項目）
```
