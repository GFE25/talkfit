# iPhoneアプリを TestFlight で入れる（Mac 不要）

Mac も Xcode も使わずに、自分の iPhone（と友人の iPhone）にアプリ版を入れる方法です。
ビルドと署名は GitHub の Mac が行い、Apple の「TestFlight」アプリ経由で届きます。

- 費用：Apple Developer Program 年 99ドル（日本では約1.3万円）。App Store に出す時もこの登録をそのまま使う
- かかる時間：登録の審査1〜2日 ＋ 初回の準備30分。2回目からはボタン1つ
- 有効期間：1つのビルドは90日。新しいビルドを送れば延びる

## 1. Apple Developer Program に登録する（★本人）

1. iPhone の App Store で「Apple Developer」アプリを入れる
2. アプリ →「アカウント」→ 私用の Apple ID でサインイン →「今すぐ登録」→ 個人で登録
3. 本人確認と支払い。審査が終わるとメールが届く（1〜2日）

注意：会社の Apple ID は使わない。個人で登録すると、App Store に出した時の販売者名は本名になる（TestFlight の検証だけなら一般には公開されない）。

## 2. アプリの枠を作る（★本人・パソコンのブラウザで5分）

1. [developer.apple.com/account](https://developer.apple.com/account) →「Certificates, IDs & Profiles」→「Identifiers」→「＋」
   - 「App IDs」→「App」→ Description：`TalkFit`、Bundle ID（Explicit）：`jp.talkfit.app`
   - 「使えない」と出たら `jp.talkfit.app.seki` などに変え、GitHub の Variables に `IOS_BUNDLE_ID` として登録（3章と同じ画面の「Variables」タブ）
   - Capabilities は何も選ばずに「Continue」→「Register」
2. [App Store Connect](https://appstoreconnect.apple.com) →「アプリ」→「＋」→「新規App」
   - プラットフォーム：iOS、名前：`TalkFit`（使われていたら `TalkFit 声で筋トレ記録` など）、言語：日本語
   - バンドルID：1で作ったもの、SKU：`talkfit`、アクセス：フルアクセス

## 3. 鍵を作って GitHub に登録する（★本人・10分）

鍵はチャットに貼らず、GitHub に直接入れてください。

1. App Store Connect →「ユーザとアクセス」→「統合」→「App Store Connect API」
   - 初回は「アクセスをリクエスト」→ 同意
   - 「チームキー」の「＋」→ 名前：`GitHub`、アクセス：**Admin** →「生成」
   - 「APIキーをダウンロード」（`.p8` ファイル。**1回しかダウンロードできない**）
   - 画面に出る「Issuer ID」と、そのキーの「キーID」を控える
2. [developer.apple.com/account](https://developer.apple.com/account) の「メンバーシップの詳細」で「チームID」（英数字10文字）を控える
3. GitHub の [talkfit リポジトリ](https://github.com/GFE25/talkfit) →「Settings」→「Secrets and variables」→「Actions」→「New repository secret」で4つ登録

| Name | 入れるもの |
|---|---|
| `ASC_KEY_ID` | キーID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | `.p8` ファイルをメモ帳で開いた中身すべて（`-----BEGIN PRIVATE KEY-----` から最後の行まで） |
| `APPLE_TEAM_ID` | チームID |

## 4. 送る（ボタン1つ）

GitHub →「Actions」→「iPhoneアプリを TestFlight に送る」→「Run workflow」

緑のチェックが付けば送信完了（15〜25分）。Apple 側の処理にさらに10〜30分かかります。

## 5. iPhone に入れる

1. App Store で「TestFlight」アプリを入れる
2. App Store Connect → TalkFit →「TestFlight」→「内部テスト」の「＋」→ グループを作り、自分を追加
3. 届いたメール、または TestFlight アプリから「インストール」
4. 初回だけ、TalkFit の設定（⚙️）→「開発者向け」に OpenAI のキーを入れる（サーバー公開後は不要）

友人に配る時は「外部テスト」にグループを作り、公開リンクを共有します。外部テストの初回だけ Apple の確認があります（1日前後）。

## うまくいかない時

Actions の赤い ✕ の画面に出るエラー文を、そのまま Claude に見せてください。

| エラーに含まれる言葉 | 直し方 |
|---|---|
| `鍵が未登録です` | 3章の4つが登録されているか |
| `No suitable application records` | 2章の2（App Store Connect のアプリ）が無い、またはバンドルIDが違う |
| `bundle identifier ... not available` | 2章の1でバンドルIDを変え、`IOS_BUNDLE_ID` を登録 |
| `Cloud signing permission error` | 3章の鍵のアクセスが Admin になっているか |
