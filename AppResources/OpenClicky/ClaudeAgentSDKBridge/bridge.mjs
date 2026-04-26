#!/usr/bin/env node
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import readline from "node:readline";

const require = createRequire(import.meta.url);

function emit(event) {
  process.stdout.write(`${JSON.stringify(event)}\n`);
}

function moduleSearchPaths() {
  const explicit = (process.env.OPENCLICKY_CLAUDE_AGENT_SDK_PATHS || "")
    .split(":")
    .filter(Boolean);
  return [
    new URL(".", import.meta.url).pathname,
    process.cwd(),
    ...explicit
  ];
}

async function loadAgentSDK() {
  const sdkPath = require.resolve("@anthropic-ai/claude-agent-sdk", {
    paths: moduleSearchPaths()
  });
  const sdk = await import(pathToFileURL(sdkPath).href);
  return { sdk, sdkPath };
}

function integerFromEnv(name, fallback) {
  const value = Number.parseInt(process.env[name] || "", 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

const pendingCommands = [];
const commandWaiters = [];
let closed = false;
let currentRequestID = null;
let currentText = "";

function enqueueCommand(command) {
  if (closed) return;
  const waiter = commandWaiters.shift();
  if (waiter) {
    waiter(command);
  } else {
    pendingCommands.push(command);
  }
}

function nextCommand() {
  if (pendingCommands.length > 0) {
    return Promise.resolve(pendingCommands.shift());
  }
  if (closed) {
    return Promise.resolve({ type: "close" });
  }
  return new Promise((resolve) => commandWaiters.push(resolve));
}

function textFromHistory(history) {
  if (!Array.isArray(history) || history.length === 0) return "";
  const lines = ["Recent conversation:"];
  for (const entry of history) {
    if (entry?.user) lines.push(`User: ${entry.user}`);
    if (entry?.assistant) lines.push(`OpenClicky: ${entry.assistant}`);
  }
  return lines.join("\n");
}

function userMessageFromCommand(command) {
  const content = [];
  if (typeof command.systemPrompt === "string" && command.systemPrompt.trim()) {
    content.push({
      type: "text",
      text: `OpenClicky current voice policy and runtime context for this turn:\n${command.systemPrompt}`
    });
  }

  const historyText = textFromHistory(command.conversationHistory);
  if (historyText) {
    content.push({ type: "text", text: historyText });
  }

  const images = Array.isArray(command.images) ? command.images : [];
  if (images.length > 0) {
    const imageLines = ["Screen context:"];
    for (const [index, image] of images.entries()) {
      imageLines.push(`${index + 1}. ${image.label || `screen ${index + 1}`}`);
    }
    content.push({ type: "text", text: imageLines.join("\n") });
    for (const image of images) {
      if (!image?.data) continue;
      content.push({
        type: "image",
        source: {
          type: "base64",
          media_type: image.mediaType || "image/jpeg",
          data: image.data
        }
      });
    }
  }

  content.push({ type: "text", text: command.prompt || "" });

  return {
    type: "user",
    message: {
      role: "user",
      content
    },
    parent_tool_use_id: null
  };
}

async function* commandStream() {
  while (!closed) {
    const command = await nextCommand();
    if (!command || command.type === "close") {
      return;
    }
    if (command.type !== "request" && command.type !== "warmup") {
      continue;
    }

    currentRequestID = command.id;
    currentText = "";
    emit({ type: "started", id: currentRequestID, kind: command.type });
    yield userMessageFromCommand(command);
  }
}

function assistantText(message) {
  const content = message?.message?.content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("");
}

function handleSDKMessage(message) {
  if (!currentRequestID) return;

  if (message.type === "stream_event") {
    const event = message.event;
    if (event?.type === "content_block_delta" && event.delta?.type === "text_delta") {
      currentText += event.delta.text || "";
      emit({ type: "delta", id: currentRequestID, text: currentText });
    }
    return;
  }

  if (message.type === "assistant") {
    const text = assistantText(message);
    if (text) {
      currentText = text;
    }
    return;
  }

  if (message.type === "result") {
    const id = currentRequestID;
    const resultText = message.result || currentText;
    currentRequestID = null;
    currentText = "";
    if (message.is_error) {
      const errors = Array.isArray(message.errors) ? message.errors.join("\n") : "Claude Agent SDK query failed.";
      emit({ type: "error", id, message: errors || message.subtype || "Claude Agent SDK query failed." });
    } else {
      emit({ type: "result", id, text: resultText || "" });
    }
  }
}

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity
});

rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  try {
    const command = JSON.parse(trimmed);
    if (command.type === "close") {
      closed = true;
      enqueueCommand({ type: "close" });
      return;
    }
    enqueueCommand(command);
  } catch (error) {
    emit({ type: "error", message: `Invalid bridge command: ${error.message}` });
  }
});

rl.on("close", () => {
  closed = true;
  enqueueCommand({ type: "close" });
});

try {
  const { sdk, sdkPath } = await loadAgentSDK();
  const { query } = sdk;
  if (typeof query !== "function") {
    throw new Error("@anthropic-ai/claude-agent-sdk did not export query()");
  }

  emit({ type: "ready", sdkPath });

  const options = {
    model: process.env.OPENCLICKY_CLAUDE_MODEL || "claude-sonnet-4-6",
    maxTokens: integerFromEnv("OPENCLICKY_CLAUDE_MAX_OUTPUT_TOKENS", 64000),
    cwd: process.env.OPENCLICKY_CLAUDE_CWD || process.cwd(),
    systemPrompt: process.env.OPENCLICKY_CLAUDE_SYSTEM_PROMPT || "You are OpenClicky.",
    pathToClaudeCodeExecutable: process.env.OPENCLICKY_CLAUDE_EXECUTABLE,
    permissionMode: "dontAsk",
    tools: [],
    allowedTools: [],
    includePartialMessages: true,
    includeHookEvents: false,
    persistSession: false,
    settingSources: [],
    env: {
      ...process.env,
      CLAUDE_AGENT_SDK_CLIENT_APP: "openclicky/1.0"
    }
  };

  const stream = query({
    prompt: commandStream(),
    options
  });

  for await (const message of stream) {
    handleSDKMessage(message);
  }
} catch (error) {
  emit({
    type: "error",
    id: currentRequestID,
    message: error?.stack || error?.message || String(error)
  });
  process.exitCode = 1;
}
