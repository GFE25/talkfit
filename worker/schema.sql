-- TalkFit backend schema (Cloudflare D1 / SQLite)

-- 端末ごとの利用者。ログイン不要で使えるよう、端末で生成したIDで識別する。
CREATE TABLE IF NOT EXISTS devices (
  id          TEXT PRIMARY KEY,
  created_at  INTEGER NOT NULL,          -- ms
  license     TEXT,                      -- 紐づいた有料ライセンス
  updated_at  INTEGER NOT NULL
);

-- 有料ライセンス。1つの購入で複数端末に引き継げるよう、端末とは別に持つ。
CREATE TABLE IF NOT EXISTS licenses (
  code            TEXT PRIMARY KEY,      -- 引き継ぎコード XXXX-XXXX
  status          TEXT NOT NULL,         -- active / canceled
  plan            TEXT,                  -- monthly / yearly
  stripe_customer TEXT,
  stripe_sub      TEXT,
  email           TEXT,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_licenses_sub ON licenses(stripe_sub);
CREATE INDEX IF NOT EXISTS idx_licenses_customer ON licenses(stripe_customer);

-- 音声利用量（日別）。無料枠の判定と、使いすぎ防止の上限に使う。
CREATE TABLE IF NOT EXISTS voice_usage (
  device_id  TEXT NOT NULL,
  day        TEXT NOT NULL,              -- YYYY-MM-DD (JST)
  sec        REAL NOT NULL DEFAULT 0,
  req        INTEGER NOT NULL DEFAULT 0,
  sets       INTEGER NOT NULL DEFAULT 0, -- 実際に記録になった数（アプリから報告）
  PRIMARY KEY (device_id, day)
);

-- 同一IPからの乱用防止（IPはハッシュ化して保存）
CREATE TABLE IF NOT EXISTS ip_usage (
  ip_hash  TEXT NOT NULL,
  day      TEXT NOT NULL,
  req      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (ip_hash, day)
);

-- アクティブ日（継続率の計算用）
CREATE TABLE IF NOT EXISTS active_days (
  device_id TEXT NOT NULL,
  day       TEXT NOT NULL,
  PRIMARY KEY (device_id, day)
);

-- ファネル計測（日別のイベント件数）
CREATE TABLE IF NOT EXISTS events (
  day  TEXT NOT NULL,
  name TEXT NOT NULL,
  n    INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, name)
);

-- 処理済みStripeイベント（再送による二重処理を防ぐ）
CREATE TABLE IF NOT EXISTS stripe_events (
  id         TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL
);
