// CommandCode 计量反向代理：把请求原样转发给真正的网关，并把每个请求/响应的 usage 记成 JSONL。
//
//   node scripts/measure_harness_cost/proxy.mjs [port] [logfile]
//
// 为什么需要它：harness 自己的会话记录里**没有**网关侧的计费用量（codex 只报自己的口径、
// DSH 干脆不落盘、cmd 只报整轮累计），所以想比较「不同 harness 打到同一个网关花多少」，
// 就得在中间夹一层把网关原始 usage 记下来。
//
// 两条线都要支持，因为不同 harness 走不同 wire：
//   /chat/completions → usage.prompt_tokens + usage.prompt_tokens_details.cached_tokens
//   /responses（SSE） → 事件里嵌套的 response.usage.input_tokens + input_tokens_details.cached_tokens
// 所以这里是**递归找**第一个长得像 usage 的对象，而不是只看顶层键。
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";

const PORT = Number(process.argv[2] || 8899);
const LOG = process.argv[3] || "cc_usage.jsonl";
const UPSTREAM = process.env.MEASURE_UPSTREAM || "https://api.commandcode.ai";

const log = (obj) => appendFileSync(LOG, JSON.stringify(obj) + "\n");

function looksLikeUsage(v) {
  if (!v || typeof v !== "object" || Array.isArray(v)) return false;

  return ["input_tokens", "prompt_tokens", "output_tokens", "completion_tokens", "total_tokens"].some(
    (k) => typeof v[k] === "number"
  );
}

function findUsage(node, depth = 0) {
  if (depth > 6 || !node || typeof node !== "object") return null;
  if (looksLikeUsage(node)) return node;
  if (Array.isArray(node)) {
    for (const item of node) {
      const hit = findUsage(item, depth + 1);
      if (hit) return hit;
    }
    return null;
  }
  if (node.usage && looksLikeUsage(node.usage)) return node.usage;

  for (const v of Object.values(node)) {
    const hit = findUsage(v, depth + 1);
    if (hit) return hit;
  }

  return null;
}

function usageFromSse(text) {
  let usage = null;

  for (const line of text.split("\n")) {
    if (!line.startsWith("data:")) continue;
    const payload = line.slice(5).trim();
    if (payload === "" || payload === "[DONE]") continue;

    try {
      const hit = findUsage(JSON.parse(payload));
      if (hit) usage = hit;
    } catch {}
  }

  return usage;
}

function usageFromJson(text) {
  try {
    return findUsage(JSON.parse(text));
  } catch {
    return null;
  }
}

const server = createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = Buffer.concat(chunks);

  const headers = { ...req.headers };
  delete headers.host;
  delete headers["content-length"];

  let meta = {};
  try {
    const parsed = JSON.parse(body.toString("utf8"));
    meta = { model: parsed.model ?? null, stream: parsed.stream ?? null, reqBytes: body.length };
  } catch {}

  const started = Date.now();
  let status = 0;
  let usage = null;
  let err = null;

  try {
    const upstream = await fetch(UPSTREAM + req.url, {
      method: req.method,
      headers,
      body: req.method === "GET" || req.method === "HEAD" ? undefined : body
    });

    status = upstream.status;
    const text = await upstream.text();
    const ctype = upstream.headers.get("content-type") || "";
    usage = ctype.includes("event-stream") ? usageFromSse(text) : usageFromJson(text);

    res.writeHead(upstream.status, Object.fromEntries(upstream.headers));
    res.end(text);
  } catch (e) {
    err = String(e && e.message ? e.message : e);
    status = 599;
    if (!res.headersSent) res.writeHead(599, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: err } }));
  }

  log({ ts: new Date().toISOString(), path: req.url, ms: Date.now() - started, status, ...meta, usage, error: err });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`measure-harness-cost proxy on http://127.0.0.1:${PORT} → ${UPSTREAM}  log=${LOG}`);
});
