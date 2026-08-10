#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";
import { schemaForKind } from "./codex-worker.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const WORKER_PATH = path.join(__dirname, "codex-worker.mjs");
const DEFAULT_OUTPUT = path.join(__dirname, "..", "benchmark", "latency-results.json");

const outputSchema = {
  type: "object",
  additionalProperties: false,
  required: ["directAnswer", "points"],
  properties: {
    directAnswer: { type: "string" },
    points: { type: "array", items: { type: "string" } }
  }
};

const basePrompt = `面试官问：请介绍一个你主导过的、业务结果可量化的复杂项目。
回答要求：直接开场 30-60 秒；给出 3 个有区分度的要点；说明一个不足和补救方式。
只返回符合 schema 的 JSON，不解释，不使用 Markdown。`;

function parseArgs(argv) {
  const args = {
    model: "gpt-5.6-terra",
    provider: "openai",
    apiModel: null,
    effort: "low",
    kind: "answer",
    rounds: 5,
    maxTokens: 600,
    apiKey: process.env.OPENAI_API_KEY || "",
    baseUrl: process.env.OPENAI_BASE_URL || "https://api.openai.com/v1",
    cliOnly: false,
    apiOnly: false,
    noCacheKey: false,
    output: DEFAULT_OUTPUT
  };
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i + 1];
    switch (argv[i]) {
      case "--model": args.model = value; i += 1; break;
      case "--provider": args.provider = value; i += 1; break;
      case "--api-model": args.apiModel = value; i += 1; break;
      case "--effort": args.effort = value; i += 1; break;
      case "--kind": args.kind = value; i += 1; break;
      case "--rounds": args.rounds = Number(value); i += 1; break;
      case "--max-tokens": args.maxTokens = Number(value); i += 1; break;
      case "--api-key": args.apiKey = value; i += 1; break;
      case "--base-url": args.baseUrl = value; i += 1; break;
      case "--output": args.output = value; i += 1; break;
      case "--cli-only": args.cliOnly = true; break;
      case "--api-only": args.apiOnly = true; break;
      case "--no-cache-key": args.noCacheKey = true; break;
      default: break;
    }
  }
  args.provider = ["openai", "deepseek"].includes(args.provider) ? args.provider : "openai";
  args.kind = ["answer", "cue", "referenceAnswer", "followUps", "followUpAnswer"].includes(args.kind)
    ? args.kind
    : "answer";
  if (args.provider === "deepseek") {
    if (!args.apiKey) args.apiKey = process.env.DEEPSEEK_API_KEY || "";
    if (!args.baseUrl || args.baseUrl === "https://api.openai.com/v1") {
      args.baseUrl = "https://api.deepseek.com";
    }
  }
  if (!args.apiKey) {
    args.apiKey = readKeychainAPIKey(args.provider === "deepseek" ? "interviewAPIKey" : "openAIApiKey") || "";
  }
  args.apiModel = args.apiModel || (args.provider === "deepseek" ? "deepseek-v4-flash" : args.model);
  return args;
}

function readKeychainAPIKey(account) {
  try {
    const value = execFileSync(
      "security",
      ["find-generic-password", "-s", "com.openoats.app", "-a", account, "-w"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
    ).trim();
    return value || "";
  } catch {
    return "";
  }
}

function median(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[middle - 1] + sorted[middle]) / 2
    : sorted[middle];
}

function summarize(rows) {
  const values = rows.filter((row) => row.ok).map((row) => row.firstDeltaMs);
  if (values.length === 0) return null;
  values.sort((a, b) => a - b);
  const min = values[0];
  const max = values[values.length - 1];
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  const p90 = values[Math.min(values.length - 1, Math.floor(values.length * 0.9))];
  return { count: values.length, min, mean, median: median(values), p90, max };
}

function runWorkerRequest(child, writer, id, message) {
  return new Promise((resolve) => {
    const startedAt = performance.now();
    let firstDeltaMs = null;
    let outputChars = 0;
    let transport = null;
    const handler = (event) => {
      if (event.id !== id) return;
      if (event.event === "delta") {
        if (firstDeltaMs == null) firstDeltaMs = performance.now() - startedAt;
        outputChars += String(event.delta ?? "").length;
        return;
      }
      if (event.event === "completed") {
        transport = event.transport ?? null;
        outputChars = Math.max(outputChars, String(event.response ?? "").length);
        resolve({
          ok: true,
          firstDeltaMs: Math.round(firstDeltaMs ?? 0),
          totalMs: Math.round(performance.now() - startedAt),
          outputChars,
          transport
        });
        return;
      }
      if (event.event === "failed") {
        resolve({ ok: false, error: event.error ?? "worker failed", firstDeltaMs: Math.round(firstDeltaMs ?? 0), totalMs: Math.round(performance.now() - startedAt), outputChars, transport });
      }
    };
    child.once(`response-${id}`, handler);
    writer(JSON.stringify({ command: message.command, id, ...message.payload }));
  });
}

async function startWorker(extraEnv = {}) {
  const child = spawn(process.execPath, [WORKER_PATH], {
    cwd: __dirname,
    env: { ...process.env, ...extraEnv },
    stdio: ["pipe", "pipe", "pipe"]
  });
  const writer = (line) => child.stdin.write(`${line}\n`);
  const rl = readline.createInterface({ input: child.stdout });
  rl.on("line", (line) => {
    if (!line.trim()) return;
    try {
      const event = JSON.parse(line);
      if (event.id) child.emit(`response-${event.id}`, event);
    } catch {
      // Ignore malformed worker lines.
    }
  });
  child.stderr.on("data", () => {});
  await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("spawn", resolve);
  });
  return { child, writer, rl };
}

async function prewarmWorker(state) {
  return runWorkerRequest(state.child, state.writer, "prewarm", { command: "prewarm", payload: {} });
}

async function runCliRound(state, args, prompt, round) {
  const id = `cli-${round}`;
  return runWorkerRequest(state.child, state.writer, id, {
    command: "generate",
    payload: {
      id,
      prompt,
      model: args.model,
      reasoning_effort: args.effort,
      max_output_tokens: args.maxTokens,
      kind: args.kind
    }
  });
}

async function runApiRound(args, prompt, round) {
  if (args.provider === "deepseek") {
    return runDeepSeekResponsesRound(args, prompt, round);
  }
  const startedAt = performance.now();
  let firstDeltaMs = null;
  let output = "";
  let usage = null;
  const body = {
    model: args.model,
    input: prompt,
    reasoning: { effort: args.effort },
    max_output_tokens: args.maxTokens,
    stream: true,
    store: false,
    text: {
      format: {
        type: "json_schema",
        name: "benchmark_output",
        strict: true,
        schema: outputSchema
      }
    }
  };
  if (!args.noCacheKey) body.prompt_cache_key = `benchmark-${args.model}-${args.effort}`;

  const response = await fetch(`${args.baseUrl.replace(/\/$/, "")}/responses`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${args.apiKey}`,
      "Content-Type": "application/json",
      "Accept": "text/event-stream"
    },
    body: JSON.stringify(body)
  });
  if (!response.ok || !response.body) {
    const detail = await response.text().catch(() => "");
    throw new Error(`HTTP ${response.status}: ${detail.slice(0, 300)}`);
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let newlineIndex;
    while ((newlineIndex = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newlineIndex).trim();
      buffer = buffer.slice(newlineIndex + 1);
      if (!line.startsWith("data: ")) continue;
      const payload = line.slice(6);
      if (payload === "[DONE]") continue;
      let event;
      try {
        event = JSON.parse(payload);
      } catch {
        continue;
      }
      if (event.type === "response.output_text.delta" && typeof event.delta === "string") {
        if (firstDeltaMs == null) firstDeltaMs = performance.now() - startedAt;
        output += event.delta;
      } else if (event.type === "response.completed") {
        usage = event.response?.usage ?? null;
      } else if (event.type === "error") {
        throw new Error(event.message ?? "OpenAI streaming error");
      }
    }
  }
  return {
    ok: true,
    firstDeltaMs: Math.round(firstDeltaMs ?? 0),
    totalMs: Math.round(performance.now() - startedAt),
    outputChars: output.length,
    transport: "responses-api",
    usage
  };
}

async function runDeepSeekResponsesRound(args, prompt, round) {
  const startedAt = performance.now();
  let firstDeltaMs = null;
  let output = "";
  let usage = null;
  const schemaText = JSON.stringify(schemaForKind(args.kind));
  const body = {
    model: args.apiModel,
    input: `${prompt}\n\n<OUTPUT_SCHEMA>\n${schemaText}\n</OUTPUT_SCHEMA>`,
    stream: true,
    max_output_tokens: args.maxTokens,
    reasoning: { effort: args.effort },
    text: { format: { type: "json_object" } }
  };

  const response = await fetch(`${args.baseUrl.replace(/\/$/, "")}/responses`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${args.apiKey}`,
      "Content-Type": "application/json",
      "Accept": "text/event-stream"
    },
    body: JSON.stringify(body)
  });
  if (!response.ok || !response.body) {
    const detail = await response.text().catch(() => "");
    throw new Error(`HTTP ${response.status}: ${detail.slice(0, 300)}`);
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let newlineIndex;
    while ((newlineIndex = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newlineIndex).trim();
      buffer = buffer.slice(newlineIndex + 1);
      if (!line.startsWith("data: ")) continue;
      const payload = line.slice(6);
      let event;
      try {
        event = JSON.parse(payload);
      } catch {
        continue;
      }
      if (event.type === "response.output_text.delta" && typeof event.delta === "string") {
        if (firstDeltaMs == null) firstDeltaMs = performance.now() - startedAt;
        output += event.delta;
      } else if (event.type === "response.completed") {
        usage = event.response?.usage ?? null;
      } else if (event.type === "response.failed") {
        throw new Error(event.response?.error?.message ?? "DeepSeek Responses failed");
      } else if (event.type === "error") {
        throw new Error(event.message ?? "DeepSeek Responses error");
      }
    }
  }
  return {
    ok: true,
    firstDeltaMs: Math.round(firstDeltaMs ?? 0),
    totalMs: Math.round(performance.now() - startedAt),
    outputChars: output.length,
    transport: "deepseek-responses",
    usage
  };
}

async function runDeepSeekRound(args, prompt, round) {
  const startedAt = performance.now();
  let firstDeltaMs = null;
  let output = "";
  const body = {
    model: args.apiModel,
    messages: [{ role: "user", content: prompt }],
    stream: true,
    max_tokens: args.maxTokens
  };
  if (!args.apiModel.toLowerCase().includes("reasoner")) {
    body.response_format = { type: "json_object" };
  }

  const response = await fetch(`${args.baseUrl.replace(/\/$/, "")}/chat/completions`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${args.apiKey}`,
      "Content-Type": "application/json",
      "Accept": "text/event-stream"
    },
    body: JSON.stringify(body)
  });
  if (!response.ok || !response.body) {
    const detail = await response.text().catch(() => "");
    throw new Error(`HTTP ${response.status}: ${detail.slice(0, 300)}`);
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let newlineIndex;
    while ((newlineIndex = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newlineIndex).trim();
      buffer = buffer.slice(newlineIndex + 1);
      if (!line.startsWith("data: ")) continue;
      const payload = line.slice(6);
      if (payload === "[DONE]") continue;
      let chunk;
      try {
        chunk = JSON.parse(payload);
      } catch {
        continue;
      }
      if (chunk.error) {
        throw new Error(chunk.error.message ?? "DeepSeek streaming error");
      }
      const content = chunk.choices?.[0]?.delta?.content;
      if (typeof content === "string" && content.length > 0) {
        if (firstDeltaMs == null) firstDeltaMs = performance.now() - startedAt;
        output += content;
      }
    }
  }
  return {
    ok: true,
    firstDeltaMs: Math.round(firstDeltaMs ?? 0),
    totalMs: Math.round(performance.now() - startedAt),
    outputChars: output.length,
    transport: "deepseek-api"
  };
}

async function runBenchmark(args) {
  const prompt = `你是低延迟面试助手。\n${basePrompt}`;
  const rows = [];
  const cliState = args.cliOnly || !args.apiOnly ? await startWorker() : null;

  if (cliState) {
    await prewarmWorker(cliState);
    await runCliRound(cliState, args, prompt, "warmup");
  }
  if (!args.cliOnly && args.apiKey) {
    await runApiRound(args, prompt, "warmup").catch(() => {});
  }

  for (let i = 1; i <= args.rounds; i += 1) {
    const cliFirst = i % 2 === 1;
    const runCLI = async () => {
      if (!cliState) return;
      try {
        const result = await runCliRound(cliState, args, prompt, `m${i}`);
        rows.push({ path: "cli", round: i, ...result });
      } catch (error) {
        rows.push({ path: "cli", round: i, ok: false, error: String(error) });
      }
    };
    const runAPI = async () => {
      if (args.cliOnly || !args.apiKey) return;
      try {
        const result = await runApiRound(args, prompt, `m${i}`);
        rows.push({ path: "api", round: i, ...result });
      } catch (error) {
        rows.push({ path: "api", round: i, ok: false, error: String(error) });
      }
    };

    if (cliFirst) {
      await runCLI();
      await runAPI();
    } else {
      await runAPI();
      await runCLI();
    }
  }

  if (cliState) {
    cliState.child.kill();
  }

  const summary = {
    model: args.model,
    provider: args.provider,
    apiModel: args.apiModel,
    effort: args.effort,
    kind: args.kind,
    maxOutputTokens: args.maxTokens,
    promptCacheKey: args.noCacheKey ? null : `benchmark-${args.model}-${args.effort}`,
    cli: summarize(rows.filter((row) => row.path === "cli")),
    cliTotal: summarize(rows.filter((row) => row.path === "cli").map((row) => ({ ...row, firstDeltaMs: row.totalMs }))),
    api: summarize(rows.filter((row) => row.path === "api")),
    apiTotal: summarize(rows.filter((row) => row.path === "api").map((row) => ({ ...row, firstDeltaMs: row.totalMs }))),
    apiSkipped: !args.apiKey ? `${args.provider} API key not set` : null
  };

  fs.mkdirSync(path.dirname(args.output), { recursive: true });
  fs.writeFileSync(args.output, JSON.stringify({ summary, rows }, null, 2));

  console.log(`cliModel=${args.model} apiModel=${args.apiModel} provider=${args.provider} effort=${args.effort} rounds=${args.rounds} maxTokens=${args.maxTokens}`);
  console.log("path  round  firstDeltaMs  totalMs  outputChars  transport");
  for (const row of rows) {
    if (!row.ok) {
      console.log(`${row.path.padEnd(4)}  ${String(row.round).padEnd(5)}  error: ${row.error}`);
      continue;
    }
    console.log(
      `${row.path.padEnd(4)}  ${String(row.round).padEnd(5)}  ${String(row.firstDeltaMs).padEnd(12)}  ${String(row.totalMs).padEnd(8)}  ${String(row.outputChars).padEnd(12)}  ${row.transport}`
    );
  }
  console.log("summary:");
  console.log(`  cli firstDelta median=${summary.cli?.median ?? "n/a"} total median=${summary.cliTotal?.median ?? "n/a"}`);
  console.log(`  api firstDelta median=${summary.api?.median ?? "n/a"} total median=${summary.apiTotal?.median ?? "n/a"}${summary.apiSkipped ? ` (${summary.apiSkipped})` : ""}`);
  console.log(`results: ${args.output}`);
}

const args = parseArgs(process.argv.slice(2));
runBenchmark(args).catch((error) => {
  console.error(error);
  process.exit(1);
});
