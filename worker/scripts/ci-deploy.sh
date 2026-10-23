#!/usr/bin/env bash
# GitHub Actions からサーバーを公開する。
# 人がやるのは GitHub の Secrets に鍵を登録してボタンを押すことだけ。
# 何度実行しても同じ結果になる（DB・サブドメインは既にあれば再利用する）。
set -euo pipefail
cd "$(dirname "$0")/.."

say() { echo "::notice::$*"; }
fail() { echo "::error::$*"; exit 1; }

# ── 1. 必要な鍵の確認 ──
missing=()
[ -n "${CLOUDFLARE_API_TOKEN:-}" ]  || missing+=("CLOUDFLARE_API_TOKEN")
[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] || missing+=("CLOUDFLARE_ACCOUNT_ID")
[ -n "${OPENAI_API_KEY:-}" ]        || missing+=("OPENAI_API_KEY")
[ -n "${ADMIN_KEY:-}" ]             || missing+=("ADMIN_KEY")
if [ ${#missing[@]} -gt 0 ]; then
  fail "GitHub の Settings → Secrets and variables → Actions に次を登録してください: ${missing[*]}"
fi
CF_API="https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}"
cf() { curl -sS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" "$@"; }

# ── 2. データベース（D1）を用意 ──
db_id=$(npx wrangler d1 list --json 2>/dev/null | jq -r '.[] | select(.name=="talkfit") | .uuid' | head -1)
if [ -z "$db_id" ]; then
  say "データベースを新規作成します"
  npx wrangler d1 create talkfit >/dev/null
  db_id=$(npx wrangler d1 list --json | jq -r '.[] | select(.name=="talkfit") | .uuid' | head -1)
fi
[ -n "$db_id" ] || fail "データベースを作れませんでした。APIトークンに「D1 編集」の権限があるか確認してください"
sed -i -E "s/^database_id = \".*\"/database_id = \"${db_id}\"/" wrangler.toml
npx wrangler d1 execute talkfit --remote --file=schema.sql >/dev/null
say "データベース OK（${db_id}）"

# ── 3. workers.dev のサブドメインを用意（新規アカウントは未登録のため）──
sub=$(cf "${CF_API}/workers/subdomain" | jq -r '.result.subdomain // empty')
if [ -z "$sub" ]; then
  want="talkfit-$(echo -n "$CLOUDFLARE_ACCOUNT_ID" | sha256sum | cut -c1-6)"
  say "workers.dev のサブドメイン ${want} を登録します"
  sub=$(cf -X PUT "${CF_API}/workers/subdomain" --data "{\"subdomain\":\"${want}\"}" | jq -r '.result.subdomain // empty')
fi
[ -n "$sub" ] || fail "workers.dev のサブドメインを登録できませんでした。Cloudflare の Workers 画面を一度開いてから再実行してください"
URL="https://talkfit-api.${sub}.workers.dev"

# ── 4. 公開（決済リンク等は GitHub の Variables から）──
args=()
for v in PAYMENT_LINK_MONTHLY PAYMENT_LINK_YEARLY PORTAL_URL CONTACT_URL ALLOWED_ORIGINS; do
  val="${!v:-}"
  [ -n "$val" ] && args+=(--var "${v}:${val}")
done
npx wrangler deploy "${args[@]}"

# ── 5. 秘密情報を登録 ──
IP_SALT="${IP_SALT:-$(echo -n "salt:${ADMIN_KEY}" | sha256sum | cut -c1-32)}"
jq -n \
  --arg OPENAI_API_KEY "$OPENAI_API_KEY" \
  --arg ANTHROPIC_API_KEY "${ANTHROPIC_API_KEY:-}" \
  --arg STRIPE_WEBHOOK_SECRET "${STRIPE_WEBHOOK_SECRET:-}" \
  --arg ADMIN_KEY "$ADMIN_KEY" \
  --arg IP_SALT "$IP_SALT" \
  '{OPENAI_API_KEY:$OPENAI_API_KEY, ADMIN_KEY:$ADMIN_KEY, IP_SALT:$IP_SALT}
   + (if $ANTHROPIC_API_KEY != "" then {ANTHROPIC_API_KEY:$ANTHROPIC_API_KEY} else {} end)
   + (if $STRIPE_WEBHOOK_SECRET != "" then {STRIPE_WEBHOOK_SECRET:$STRIPE_WEBHOOK_SECRET} else {} end)' \
  > "${RUNNER_TEMP:-/tmp}/secrets.json"
npx wrangler secret bulk "${RUNNER_TEMP:-/tmp}/secrets.json"
rm -f "${RUNNER_TEMP:-/tmp}/secrets.json"

# ── 6. 動作確認 ──
ok=""
for i in $(seq 1 20); do
  if curl -fsS "${URL}/health" | grep -q '"ok":true'; then ok=1; break; fi
  sleep 3
done
[ -n "$ok" ] || fail "公開はできましたが ${URL}/health が応答しません。数分後に再実行してください"
say "サーバー公開 OK: ${URL}"
echo "url=${URL}" >> "${GITHUB_OUTPUT:-/dev/null}"

{
  echo "## サーバーを公開しました"
  echo ""
  echo "- URL: ${URL}"
  echo "- 管理画面: ${URL}/admin?key=（ADMIN_KEY に登録した文字列）"
  echo "- 決済リンク: $([ -n "${PAYMENT_LINK_MONTHLY:-}" ] && echo 設定済み || echo 未設定（無料体験のみ受付中）)"
  echo "- Stripe Webhook: $([ -n "${STRIPE_WEBHOOK_SECRET:-}" ] && echo 設定済み || echo 未設定)"
  echo "- Webhook の登録先: ${URL}/v1/stripe/webhook"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
