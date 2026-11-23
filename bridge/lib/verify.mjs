// F-07: AI の「完了」自己申告とは独立に、成果物が挙げた URL が実在するかを確認する。
// 取得するのはステータスコードだけで、本文は読まない（本文をモデルに渡さない）。
// 内部ネットワーク（loopback / RFC1918 / Tailscale CGNAT / link-local / メタデータ等）への到達は拒否する。

import dns from 'node:dns/promises';
import net from 'node:net';

const blocked = new net.BlockList();
for (const [addr, prefix] of [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16],
  ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15],
  ['224.0.0.0', 4], ['240.0.0.0', 4],
]) blocked.addSubnet(addr, prefix, 'ipv4');
for (const [addr, prefix] of [
  ['::', 128], ['::1', 128], ['fc00::', 7], ['fe80::', 10], ['ff00::', 8], ['64:ff9b::', 96], ['2001:db8::', 32],
]) blocked.addSubnet(addr, prefix, 'ipv6');

export function isBlockedAddress(address) {
  const family = net.isIP(address);
  if (family === 0) return true;
  if (family === 6) {
    const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(address);
    if (mapped) return blocked.check(mapped[1], 'ipv4');
    return blocked.check(address, 'ipv6');
  }
  return blocked.check(address, 'ipv4');
}

async function assertPublicHost(hostname, lookup) {
  const host = hostname.replace(/^\[|\]$/g, '');
  if (net.isIP(host)) {
    if (isBlockedAddress(host)) throw new Error('blocked address');
    return;
  }
  if (/^(localhost|.*\.local|.*\.internal|.*\.ts\.net)$/i.test(host)) throw new Error('blocked hostname');
  const addrs = await lookup(host, { all: true, verbatim: true });
  if (!addrs.length) throw new Error('no DNS records');
  for (const a of addrs) if (isBlockedAddress(a.address)) throw new Error(`resolves to blocked address ${a.address}`);
}

/**
 * @returns {Promise<Array<{url:string, ok:boolean, status?:number, location?:string, error?:string}>>}
 */
export async function verifyUrls(urls, { timeoutMs = 5000, fetchImpl = fetch, lookup = dns.lookup, max = 5 } = {}) {
  const out = [];
  for (const url of [...new Set(urls)].slice(0, max)) {
    try {
      const u = new URL(url);
      await assertPublicHost(u.hostname, lookup);
      let res = await fetchImpl(url, { method: 'HEAD', redirect: 'manual', signal: AbortSignal.timeout(timeoutMs) });
      if (res.status === 405 || res.status === 501) {
        res = await fetchImpl(url, { method: 'GET', redirect: 'manual', signal: AbortSignal.timeout(timeoutMs) });
        await res.body?.cancel?.();
      }
      const location = res.headers?.get?.('location') ?? undefined;
      out.push({ url, ok: res.status >= 200 && res.status < 400, status: res.status, ...(location ? { location } : {}) });
    } catch (e) {
      out.push({ url, ok: false, error: String(e?.message ?? e).slice(0, 200) });
    }
  }
  return out;
}
