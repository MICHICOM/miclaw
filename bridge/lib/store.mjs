// ブリッジのイベント台帳（SQLite）。OpenClaw 側のフック冪等キャッシュはメモリ上のみで
// 再起動を跨がないため、二重投入防止の正本はここに置く。
//
// 状態遷移:
//   RECEIVED -> VALIDATED -> SENT -> COMPLETED
//                  |           |-> RETRY_PENDING -> SENT ...（上限で FAILED）
//                  |-> REJECTED（検証失敗。再試行しない）

import { DatabaseSync } from 'node:sqlite';

export const STATES = ['RECEIVED', 'VALIDATED', 'SENT', 'COMPLETED', 'RETRY_PENDING', 'FAILED', 'REJECTED'];

export function openStore(file) {
  const db = new DatabaseSync(file);
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA busy_timeout = 5000;
    CREATE TABLE IF NOT EXISTS events (
      id            TEXT PRIMARY KEY,          -- eventKey:contentHash[0:12]
      event_key     TEXT NOT NULL,
      content_hash  TEXT NOT NULL,
      file_name     TEXT NOT NULL,
      source        TEXT,
      task          TEXT,
      run_id        TEXT,
      payload       TEXT,                      -- 正規化済みイベント（再送用）
      state         TEXT NOT NULL,
      attempts      INTEGER NOT NULL DEFAULT 0,
      next_attempt_at INTEGER,
      hook_run_id   TEXT,
      completion    TEXT,
      verification  TEXT,
      last_error    TEXT,
      created_at    INTEGER NOT NULL,
      updated_at    INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS events_state ON events(state, next_attempt_at);
    CREATE INDEX IF NOT EXISTS events_key ON events(event_key);
    CREATE TABLE IF NOT EXISTS seen_files (
      file_name    TEXT NOT NULL,
      content_hash TEXT NOT NULL,
      event_id     TEXT,
      seen_at      INTEGER NOT NULL,
      PRIMARY KEY (file_name, content_hash)
    );
    CREATE TABLE IF NOT EXISTS audit (
      seq        INTEGER PRIMARY KEY AUTOINCREMENT,
      event_id   TEXT,
      at         INTEGER NOT NULL,
      from_state TEXT,
      to_state   TEXT NOT NULL,
      detail     TEXT
    );
  `);

  const q = {
    seenFile: db.prepare('SELECT 1 FROM seen_files WHERE file_name = ? AND content_hash = ?'),
    markSeen: db.prepare('INSERT OR IGNORE INTO seen_files (file_name, content_hash, event_id, seen_at) VALUES (?, ?, ?, ?)'),
    get: db.prepare('SELECT * FROM events WHERE id = ?'),
    latestForKey: db.prepare("SELECT * FROM events WHERE event_key = ? AND state NOT IN ('REJECTED') ORDER BY created_at DESC LIMIT 1"),
    insert: db.prepare(`INSERT INTO events (id, event_key, content_hash, file_name, source, task, run_id, payload, state, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`),
    setState: db.prepare(`UPDATE events SET state = ?, attempts = COALESCE(?, attempts), next_attempt_at = ?,
                          hook_run_id = COALESCE(?, hook_run_id), completion = COALESCE(?, completion),
                          verification = COALESCE(?, verification), last_error = ?, updated_at = ? WHERE id = ?`),
    audit: db.prepare('INSERT INTO audit (event_id, at, from_state, to_state, detail) VALUES (?, ?, ?, ?, ?)'),
    due: db.prepare(`SELECT * FROM events WHERE state IN ('VALIDATED', 'RETRY_PENDING', 'SENT')
                     AND (next_attempt_at IS NULL OR next_attempt_at <= ?) ORDER BY created_at LIMIT ?`),
    counts: db.prepare('SELECT state, COUNT(*) AS n FROM events GROUP BY state'),
    recent: db.prepare('SELECT id, source, task, run_id, state, attempts, last_error, updated_at FROM events ORDER BY updated_at DESC LIMIT ?'),
  };

  function transition(id, to, fields = {}) {
    const now = fields.now ?? Date.now();
    const cur = q.get.get(id);
    q.setState.run(
      to,
      fields.attempts ?? null,
      fields.nextAttemptAt ?? null,
      fields.hookRunId ?? null,
      fields.completion ? JSON.stringify(fields.completion) : null,
      fields.verification ? JSON.stringify(fields.verification) : null,
      fields.error ?? null,
      now,
      id,
    );
    q.audit.run(id, now, cur?.state ?? null, to, fields.error ?? fields.detail ?? null);
  }

  return {
    db,
    hasSeen: (fileName, hash) => Boolean(q.seenFile.get(fileName, hash)),
    markSeen: (fileName, hash, eventId, now = Date.now()) => q.markSeen.run(fileName, hash, eventId, now),
    get: (id) => q.get.get(id),
    latestForKey: (key) => q.latestForKey.get(key),
    insert(ev, fileName, state, now = Date.now()) {
      const id = `${ev.eventKey}:${ev.contentHash.slice(0, 12)}`;
      q.insert.run(id, ev.eventKey, ev.contentHash, fileName, ev.source, ev.task, ev.runId, JSON.stringify(ev), state, now, now);
      q.audit.run(id, now, null, state, null);
      return id;
    },
    insertRejected(fileName, hash, error, now = Date.now()) {
      const id = `rejected:${hash.slice(0, 32)}`;
      if (!q.get.get(id)) {
        q.insert.run(id, id, hash, fileName, null, null, null, null, 'REJECTED', now, now);
        q.setState.run('REJECTED', null, null, null, null, null, error, now, id);
        q.audit.run(id, now, null, 'REJECTED', error);
      }
      return id;
    },
    transition,
    due: (now, limit) => q.due.all(now, limit),
    resetFailed(id, now = Date.now()) {
      const cur = q.get.get(id);
      if (!cur || cur.state !== 'FAILED') return false;
      q.setState.run('VALIDATED', 0, null, null, null, null, null, now, id);
      q.audit.run(id, now, 'FAILED', 'VALIDATED', 'manual retry');
      return true;
    },
    counts: () => Object.fromEntries(q.counts.all().map((r) => [r.state, r.n])),
    recent: (n) => q.recent.all(n),
    close: () => db.close(),
  };
}
