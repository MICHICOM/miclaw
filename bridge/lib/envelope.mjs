// 外部クラウドAI（ChatGPT Work / Claude Cowork / Gemini Spark 等）が
// 許可済みフォルダに書き出した成果物を「非信頼データ」として検証・正規化する。
//
// 受け付ける形式は2つだけ:
//   1) <任意>.json  … claw-hub/result@1 エンベロープ（下記 validateEnvelope）
//   2) <source>__<task>__<runId>.md|.txt … 本文のみ。ファイル名からメタデータを取る
// それ以外は REJECTED。中身の「指示」は一切解釈しない。

import { createHash } from 'node:crypto';
import path from 'node:path';

export const SCHEMA_ID = 'claw-hub/result@1';
const ID_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:+-]{0,63}$/;
const STATUSES = new Set(['ok', 'error', 'partial']);
const MAX_ITEMS = 50;
const MAX_URLS = 10;
const MAX_FIELD = 2000;
const MAX_SUMMARY = 20000;

export class EnvelopeError extends Error {}

function str(v, field, max, { required = true } = {}) {
  if (v === undefined || v === null || v === '') {
    if (required) throw new EnvelopeError(`${field} is required`);
    return undefined;
  }
  if (typeof v !== 'string') throw new EnvelopeError(`${field} must be a string`);
  if (v.length > max) throw new EnvelopeError(`${field} exceeds ${max} chars`);
  return v;
}

export function checkHttpUrl(u, field) {
  let parsed;
  try {
    parsed = new URL(u);
  } catch {
    throw new EnvelopeError(`${field} is not a valid URL`);
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    throw new EnvelopeError(`${field} must be http(s)`);
  }
  if (parsed.username || parsed.password) {
    throw new EnvelopeError(`${field} must not contain credentials`);
  }
  return parsed.toString();
}

export function validateEnvelope(obj, { allowedSources }) {
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) {
    throw new EnvelopeError('envelope must be a JSON object');
  }
  if (obj.schema !== SCHEMA_ID) throw new EnvelopeError(`schema must be "${SCHEMA_ID}"`);
  const source = str(obj.source, 'source', 64);
  if (!ID_RE.test(source)) throw new EnvelopeError('source has invalid characters');
  if (!allowedSources.has(source)) throw new EnvelopeError(`source "${source}" is not allowlisted`);
  const task = str(obj.task, 'task', 64);
  if (!ID_RE.test(task)) throw new EnvelopeError('task has invalid characters');
  const runId = str(obj.run_id, 'run_id', 64);
  if (!RUN_ID_RE.test(runId)) throw new EnvelopeError('run_id has invalid characters');
  const status = str(obj.status, 'status', 16);
  if (!STATUSES.has(status)) throw new EnvelopeError('status must be ok|error|partial');
  const createdAt = str(obj.created_at, 'created_at', 40, { required: false });
  if (createdAt && Number.isNaN(Date.parse(createdAt))) {
    throw new EnvelopeError('created_at must be an ISO-8601 timestamp');
  }
  const title = str(obj.title, 'title', 200, { required: false });
  const summary = str(obj.summary, 'summary', MAX_SUMMARY);

  const items = [];
  if (obj.items !== undefined) {
    if (!Array.isArray(obj.items)) throw new EnvelopeError('items must be an array');
    if (obj.items.length > MAX_ITEMS) throw new EnvelopeError(`items exceeds ${MAX_ITEMS}`);
    obj.items.forEach((it, i) => {
      if (!it || typeof it !== 'object') throw new EnvelopeError(`items[${i}] must be an object`);
      const url = it.url ? checkHttpUrl(str(it.url, `items[${i}].url`, MAX_FIELD), `items[${i}].url`) : undefined;
      items.push({
        title: str(it.title, `items[${i}].title`, 300),
        url,
        note: str(it.note, `items[${i}].note`, MAX_FIELD, { required: false }),
      });
    });
  }

  const evidenceUrls = [];
  if (obj.evidence_urls !== undefined) {
    if (!Array.isArray(obj.evidence_urls)) throw new EnvelopeError('evidence_urls must be an array');
    if (obj.evidence_urls.length > MAX_URLS) throw new EnvelopeError(`evidence_urls exceeds ${MAX_URLS}`);
    obj.evidence_urls.forEach((u, i) => {
      evidenceUrls.push(checkHttpUrl(str(u, `evidence_urls[${i}]`, MAX_FIELD), `evidence_urls[${i}]`));
    });
  }

  return { source, task, runId, status, createdAt, title, summary, items, evidenceUrls };
}

// <source>__<task>__<runId>.md|.txt
const TEXT_NAME_RE = /^([a-z0-9][a-z0-9._-]{0,63})__([a-z0-9][a-z0-9._-]{0,63})__([A-Za-z0-9][A-Za-z0-9._:+-]{0,63})\.(md|txt)$/;

export function parseInboxFile(fileName, raw, { allowedSources, maxBytes }) {
  if (raw.length > maxBytes) throw new EnvelopeError(`file exceeds ${maxBytes} bytes`);
  const text = raw.toString('utf8');
  if (text.includes('\u0000')) throw new EnvelopeError('binary content is not accepted');
  const base = path.basename(fileName);
  let ev;
  if (base.endsWith('.json')) {
    let obj;
    try {
      obj = JSON.parse(text);
    } catch (e) {
      throw new EnvelopeError(`invalid JSON: ${e.message}`);
    }
    ev = validateEnvelope(obj, { allowedSources });
  } else {
    const m = TEXT_NAME_RE.exec(base);
    if (!m) throw new EnvelopeError('unsupported file name (expected <source>__<task>__<runId>.md|.txt or *.json)');
    ev = validateEnvelope(
      { schema: SCHEMA_ID, source: m[1], task: m[2], run_id: m[3], status: 'ok', summary: text.slice(0, MAX_SUMMARY) },
      { allowedSources },
    );
  }
  const contentHash = createHash('sha256').update(raw).digest('hex');
  // 同じ (source, task, run_id) は同一イベント。中身が変わった再出力は別 revision として扱う
  const eventKey = createHash('sha256').update(`${ev.source}\u0000${ev.task}\u0000${ev.runId}`).digest('hex').slice(0, 32);
  return { ...ev, contentHash, eventKey };
}
