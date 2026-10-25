# TalkFit iPhoneアプリ版

Web版との違いは1つだけです。**Spotify などで音楽を流したまま、画面ロック中（ポケットの中）も録音が続きます。**
Web版は、他のアプリが音楽を流すと iOS にマイクを止められます。アプリ版は音声を「他のアプリと共存」させる設定で録音するので、止められません。

画面と機能は Web 版と同じです（リポジトリ直下の `index.html` をそのまま同梱しています）。

## 自分の iPhone に入れる（無料・約20分）

App Store に出す前の検証は、Apple ID だけで自分の iPhone に入れられます（有料の開発者登録は不要。7日ごとに入れ直しが必要）。

Mac の Claude Code に「app-ios/README.md の手順で自分の iPhone に入れたい」と頼めば、コマンドは代わりに実行します。人がやるのは ★ だけです。

1. ★ Mac に Xcode を入れる（App Store から無料。初回起動で追加コンポーネントの導入を許可）
2. ★ Xcode → 設定 → Accounts →「+」→ Apple ID でサインイン
3. 準備（Claude Code が実行）
   ```bash
   cd app-ios
   npm install
   npm run sync      # index.html などを同梱
   npm run open      # Xcode でプロジェクトを開く
   ```
4. ★ Xcode 左の「App」→「Signing & Capabilities」
   - Team：自分の名前（Personal Team）を選ぶ
   - Bundle Identifier：`jp.talkfit.app` が使えないと言われたら `jp.talkfit.app.seki` などに変える
5. ★ iPhone をケーブルで Mac につなぎ、iPhone の「設定 → プライバシーとセキュリティ → デベロッパモード」をオン（再起動あり）
6. ★ Xcode 上部の実行先で自分の iPhone を選び、▶︎（Run）
7. ★ 初回だけ iPhone の「設定 → 一般 → VPNとデバイス管理」で自分の Apple ID を「信頼」

## 使い方の注意

- 初回は設定（⚙️）の「開発者向け」に OpenAI のキーを入れる（サーバー公開後は不要）
- アプリ版と Safari 版は記録が別々に保存されます
- マイクは iPhone 本体のものを使います（AirPods は音楽の再生に使ったまま、音質も落ちません）
- 記録できると「ドミ」と短い音が鳴ります。画面を見なくても分かります
- 画面ロック中に話した分は、次に画面を開いた時にまとめて記録されます（音が鳴った分は失われません）

## 仕組み

| 部分 | ファイル |
|---|---|
| 録音・発話の切り出し・書き起こし・合図の音 | `ios/App/App/TalkFitVoicePlugin.swift` |
| プラグインの登録 | `ios/App/App/MainViewController.swift` |
| アプリ内での切り替え（ネイティブ録音を使う） | `index.html` の「iPhoneアプリ版」の節 |

- 音声セッション：`playAndRecord` + `mixWithOthers` + `allowBluetoothA2DP`
- 発話の切り出し：20ms ごとの音量を、直近4秒の騒音レベル（下位15%）と比べる。話し終わって0.8秒で区切り、前後の無音を削って送る
- 書き起こしは端末内の待ち行列に保存してから JS に渡す。JS が止まっていても（画面ロック中）失われない
- `Info.plist`：マイクの利用目的、バックグラウンド音声（`UIBackgroundModes: audio`）

## ビルドの確認

`main` に入るたびに GitHub Actions（「iPhoneアプリのビルド確認」）が Mac 上でビルドします。

## App Store に出す時（有料・後で）

Apple Developer Program（年 $99）に登録 → Xcode の Product → Archive → App Store Connect に提出。
App Store 版では、課金を Apple のアプリ内課金にするか、Web で購入したライセンスを使うだけの作りにするかを決める必要があります。
