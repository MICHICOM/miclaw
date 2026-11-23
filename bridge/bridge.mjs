#!/usr/bin/env node
// claw-bridge: 外部クラウドAIの成果物フォルダ → 検証 → 重複排除 → OpenClaw reader エージェント
//
//   node bridge.mjs run              受信箱を1回走査して、期限の来たイベントを送る（systemd timer から起動）
//   node bridge.mjs status [--json]  台帳の状態別件数と直近イベント
//   node bridge.mjs retry <eventId>  FAILED を手動で再試行キューへ戻す
//
// 常駐しない（タイマー起動の oneshot）。設定は環境変数のみ（/etc/claw-hub/bridge.env）。

import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { parseInboxFile, EnvelopeError } from './lib/envelope.mjs';
import { openStore } from './lib/store.mjs';
import { verifyUrls } from './lib/verify.mjs';
import { buildReaderMessage, submitToReader, HookError } from './lib/hook.mjs';

export function loadConfig(env = process.env) {
  const need = (k) => {
    const v = env[k];
    if (!v) throw new Error(`missing env ${k}`);
    return v;
  };
  const cfg = {
    inboxDir: need('BRIDGE_INBOX_DIR'),
    dbFile: need('BRIDGE_DB'),
    hookUrl: env.OPENCLAW_HOOK_URL || 'http://127.0.0.1:18789/hooks/agent',
    // systemd の LoadCredential で渡されたファイルを優先（環境変数に秘密を置かない）
    hookToken: env.OPENCLAW_HOOKS_TOKEN_FILE
      ? fs.readFileSync(env.OPENCLAW_HOOKS_TOKEN_FILE, 'utf8').trim()
      : need('OPENCLAW_HOOKS_TOKEN'),
    channel: env.BRIDGE_DELIVER_CHANNEL || 'discord',
    to: need('BRIDGE_DELIVER_TO'),
    allowedSources: new Set(need('BRIDGE_ALLOWED_SOURCES').split(',').map((s) => s.trim()).filter(Boolean)),
    maxBytes: Number(env.BRIDGE_MAX_BYTES || 256 * 1024),
    maxAgeMs: Number(env.BRIDGE_MAX_AGE_DAYS || 7) * 86400_000,
    maxAttempts: Number(env.BRIDGE_MAX_ATTEMPTS || 5),
    backoffBaseMs: Number(env.BRIDGE_BACKOFF_BASE_SEC || 60) * 1000,
    batch: Number(env.BRIDGE_BATCH || 10),
    readerTimeoutSec: Number(env.BRIDGE_READER_TIMEOUT_SEC || 300),
    verify: env.BRIDGE_VERIFY_URLS !== '0',
  };
  const u = new URL(cfg.hookUrl);
  if (!['127.0.0.1', 'localhost', '[::1]'].includes(u.hostname)) {
    throw new Error('OPENCLAW_HOOK_URL must point at the local loopback Gateway');
  }
  if (!/^(channel|user):\d{15,22}$/.test(cfg.to)) throw new Error('BRIDGE_DELIVER_TO must be channel:<id> or user:<id>');
  return cfg;
}

function listInbox(dir, maxAgeMs, now) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch (e) {
    throw new Error(`cannot read inbox ${dir}: ${e.message}`);
  }
  const out = [];
  for (const name of names.sort()) {
    if (name.startsWith('.')) continue;
    const full = path.join(dir, name);
    const st = fs.lstatSync(full);
    if (!st.isFile()) continue; // シンボリックリンク・ディレクトリは無視
    if (now - st.mtimeMs > maxAgeMs) continue;
    out.push({ name, full, size: st.size });
  }
  return out;
}

export function ingest(store, cfg, { now = Date.now(), log = console } = {}) {
  const stats = { scanned: 0, accepted: 0, duplicate: 0, rejected: 0 };
  for (const f of listInbox(cfg.inboxDir, cfg.maxAgeMs, now)) {
    stats.scanned++;
    if (f.size > cfg.maxBytes) {
      // 巨大ファイルは読まずに拒否（名前+サイズで一意化）
      const key = sha256(`oversize\u0000${f.name}\u0000${f.size}`);
      if (!store.hasSeen(f.name, key)) {
        store.markSeen(f.name, key, store.insertRejected(f.name, key, `file exceeds ${cfg.maxBytes} bytes`, now), now);
        stats.rejected++;
      }
      continue;
    }
    const raw = fs.readFileSync(f.full);
    let ev;
    try {
      ev = parseInboxFile(f.name, raw, { allowedSources: cfg.allowedSources, maxBytes: cfg.maxBytes });
    } catch (e) {
      if (!(e instanceof EnvelopeError)) throw e;
      const hash = sha256(raw);
      if (!store.hasSeen(f.name, hash)) {
        const id = store.insertRejected(f.name, hash, e.message, now);
        store.markSeen(f.name, hash, id, now);
        stats.rejected++;
        log.warn?.(`[bridge] rejected ${f.name}: ${e.message}`);
      }
      continue;
    }
    if (store.hasSeen(f.name, ev.contentHash)) continue;
    const prev = store.latestForKey(ev.eventKey);
    if (prev && prev.content_hash === ev.contentHash) {
      // 同じ内容が別名で再出力された → 二重通知しない
      store.markSeen(f.name, ev.contentHash, prev.id, now);
      stats.duplicate++;
      continue;
    }
    const id = store.insert(ev, f.name, 'VALIDATED', now);
    store.markSeen(f.name, ev.contentHash, id, now);
    stats.accepted++;
  }
  return stats;
}

function sha256(data) {
  return createHash('sha256').update(data).digest('hex');
}

export async function dispatch(store, cfg, { now = Date.now(), fetchImpl = fetch, verify = verifyUrls, log = console } = {}) {
  const stats = { sent: 0, completed: 0, retry: 0, failed: 0 };
  const staleMs = (cfg.readerTimeoutSec + 120) * 1000;
  for (const row of store.due(now, cfg.batch)) {
    const ev = JSON.parse(row.payload);
    if (row.attempts >= cfg.maxAttempts) {
      store.transition(row.id, 'FAILED', { error: `gave up after ${row.attempts} attempts: ${row.last_error ?? ''}`, now });
      stats.failed++;
      continue;
    }
    const urls = [...ev.evidenceUrls, ...ev.items.map((i) => i.url).filter(Boolean)];
    const verification = cfg.verify && urls.length ? await verify(urls) : [];
    const attempts = row.attempts + 1;
    store.transition(row.id, 'SENT', { attempts, nextAttemptAt: now + staleMs, verification, now });
    stats.sent++;
    try {
      const res = await submitToReader({
        url: cfg.hookUrl,
        token: cfg.hookToken,
        eventId: `claw-bridge:${row.id}`,
        message: buildReaderMessage(ev, verification),
        name: `bridge:${ev.source}/${ev.task}`,
        channel: cfg.channel,
        to: cfg.to,
        timeoutSeconds: cfg.readerTimeoutSec,
        fetchImpl,
      });
      const c = res.completion ?? {};
      if (c.status === 'ok' && !c.deliveryError) {
        store.transition(row.id, 'COMPLETED', { hookRunId: res.runId, completion: c, now: Date.now() });
        stats.completed++;
      } else {
        const backoff = Math.min(cfg.backoffBaseMs * 2 ** (attempts - 1), 3600_000);
        store.transition(row.id, 'RETRY_PENDING', {
          hookRunId: res.runId,
          completion: c,
          nextAttemptAt: Date.now() + backoff,
          error: `reader run ${c.status ?? 'unknown'}${c.deliveryError ? ` / ${c.deliveryError}` : ''}`,
        });
        stats.retry++;
      }
    } catch (e) {
      if (e instanceof HookError && e.retryable) {
        const backoff = Math.min(cfg.backoffBaseMs * 2 ** (attempts - 1), 3600_000);
        store.transition(row.id, 'RETRY_PENDING', { nextAttemptAt: Date.now() + backoff, error: e.message });
        stats.retry++;
      } else {
        store.transition(row.id, 'FAILED', { error: e.message });
        stats.failed++;
      }
      log.warn?.(`[bridge] ${row.id}: ${e.message}`);
    }
  }
  return stats;
}

async function main(argv) {
  const cmd = argv[0] ?? 'run';
  // status / retry は台帳だけを見る（トークン不要）
  const dbOnly = () => {
    if (!process.env.BRIDGE_DB) throw new Error('missing env BRIDGE_DB');
    return openStore(process.env.BRIDGE_DB);
  };
  if (cmd === 'status') {
    const store = dbOnly();
    const out = { counts: store.counts(), recent: store.recent(20) };
    if (argv.includes('--json')) console.log(JSON.stringify(out, null, 2));
    else {
      console.log(Object.entries(out.counts).map(([k, v]) => `${k}=${v}`).join(' ') || '(empty)');
      for (const r of out.recent) {
        console.log(`${new Date(r.updated_at).toISOString()} ${r.state.padEnd(13)} ${r.attempts} ${r.source ?? '-'}/${r.task ?? '-'} ${r.run_id ?? ''} ${r.last_error ? `! ${r.last_error}` : ''}`);
      }
    }
    store.close();
    return 0;
  }
  if (cmd === 'retry') {
    const store = dbOnly();
    const ok = store.resetFailed(argv[1]);
    store.close();
    console.log(ok ? 'requeued' : 'not found or not FAILED');
    return ok ? 0 : 1;
  }
  if (cmd === 'run') {
    const cfg = loadConfig();
    const store = openStore(cfg.dbFile);
    try {
      const a = ingest(store, cfg);
      const b = await dispatch(store, cfg);
      console.log(JSON.stringify({ ingest: a, dispatch: b }));
      return b.failed > 0 ? 3 : 0;
    } finally {
      store.close();
    }
  }
  console.error('usage: bridge.mjs run | status [--json] | retry <eventId>');
  return 64;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (e) => {
      console.error(`[bridge] fatal: ${e.message}`);
      process.exit(1);
    },
  );
}
