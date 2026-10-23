// TalkFit の公開設定（アプリとLPの両方が読む）。秘密情報は絶対に書かないこと。
window.TALKFIT_CONFIG = {
  // Cloudflare Worker をデプロイした後に表示されるURL（例 'https://talkfit-api.xxxx.workers.dev'）
  // 空のままだと、アプリは「開発者向け」に入れたAPIキーで直接動く（従来動作）
  apiBase: '',
  // シェア画像に載せる短いURL（独自ドメインを取ったら 'talkfit.jp' など）
  shareHost: '',
  // 規約・特商法表記に載る運営者情報（公開されます）
  operatorName: '',      // 例 '関 勇輔' または屋号 'TalkFit'
  representative: '',    // 運営責任者の氏名
  contactEmail: '',      // 問い合わせ用（専用のGmailを推奨）
};
