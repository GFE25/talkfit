// リポジトリ直下のアプリ（index.html ほか）を、iPhoneアプリに同梱する www/ にコピーする。
// アプリ本体は Web 版と同じ1ファイル。ネイティブ専用の動作は index.html の中で切り替える。
import fs from 'node:fs';
import path from 'node:path';
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..');
const www = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', 'www');
fs.rmSync(www, { recursive: true, force: true });
fs.mkdirSync(www, { recursive: true });
for (const f of ['index.html', 'config.js', 'manifest.webmanifest']) fs.copyFileSync(path.join(root, f), path.join(www, f));
for (const d of ['icons', 'legal']) fs.cpSync(path.join(root, d), path.join(www, d), { recursive: true });
console.log('copied web app →', www);
