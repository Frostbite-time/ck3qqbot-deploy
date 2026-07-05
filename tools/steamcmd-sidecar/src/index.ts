import { randomUUID } from "node:crypto";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { createMcpExpressApp } from "@modelcontextprotocol/sdk/server/express.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import * as z from "zod/v4";

type TaskState = "queued" | "running" | "succeeded" | "failed" | "cancelled";
type TaskKind = "check-login" | "download-depot" | "download-workshop";

type TaskRole = "mcp" | "internal";

type SizePreflight = {
  source: string;
  sizeBytes: number;
  sizeKiB: number;
  limitKiB: number;
  detail: string;
};

type Task = {
  id: string;
  kind: TaskKind;
  role: TaskRole;
  label: string;
  args: string[];
  targetDir?: string;
  createdAt: string;
  startedAt?: string;
  finishedAt?: string;
  state: TaskState;
  exitCode?: number | null;
  error?: string;
  preflight?: SizePreflight;
  outputTail: string[];
  process?: ChildProcessWithoutNullStreams;
};

const config = {
  host: env("CK3QQBOT_STEAMCMD_MCP_HOST", "0.0.0.0"),
  port: parsePort(env("CK3QQBOT_STEAMCMD_MCP_PORT", env("PORT", "18032"))),
  mcpToken: requiredEnv("CK3QQBOT_STEAMCMD_MCP_TOKEN"),
  internalToken: requiredEnv("CK3QQBOT_STEAMCMD_INTERNAL_TOKEN"),
  steamUser: env("CK3QQBOT_STEAM_USER", ""),
  steamcmdBin: env("CK3QQBOT_STEAMCMD_BIN", "steamcmd"),
  steamHome: path.resolve(env("CK3QQBOT_STEAMCMD_HOME", "/steam")),
  downloadRoot: path.resolve(env("CK3QQBOT_STEAMCMD_DOWNLOAD_ROOT", "/downloads")),
  mcpRuntimeDownloadRoot: path.resolve(env("CK3QQBOT_STEAMCMD_MCP_RUNTIME_DOWNLOAD_ROOT", "/bot/steam-downloads")),
  knowledgeRoot: path.resolve(env("CK3QQBOT_KNOWLEDGE_DIR", "/knowledge")),
  outputTailLines: Number.parseInt(env("CK3QQBOT_STEAMCMD_TASK_OUTPUT_TAIL_LINES", "40"), 10),
  mcpMaxDownloadKiB: parseNonNegativeInt(env("CK3QQBOT_STEAMCMD_MCP_MAX_DOWNLOAD_KIB", "0"), "CK3QQBOT_STEAMCMD_MCP_MAX_DOWNLOAD_KIB"),
  preflightTimeoutMs: parseNonNegativeInt(env("CK3QQBOT_STEAMCMD_MCP_PREFLIGHT_TIMEOUT_SEC", "60"), "CK3QQBOT_STEAMCMD_MCP_PREFLIGHT_TIMEOUT_SEC") * 1000,
  appInfoOutputMaxBytes: parseNonNegativeInt(env("CK3QQBOT_STEAMCMD_APP_INFO_OUTPUT_MAX_BYTES", "20971520"), "CK3QQBOT_STEAMCMD_APP_INFO_OUTPUT_MAX_BYTES"),
  workshopDetailsUrl: env("CK3QQBOT_STEAM_WORKSHOP_DETAILS_URL", "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"),
};

const tasks = new Map<string, Task>();
const queue: Task[] = [];
let activeTask: Task | undefined;

function env(name: string, fallback: string): string {
  const value = process.env[name];
  return value === undefined || value === "" ? fallback : value;
}

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function parsePort(raw: string): number {
  const port = Number.parseInt(raw, 10);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`invalid CK3QQBOT_STEAMCMD_MCP_PORT: ${raw}`);
  }
  return port;
}

function parseNonNegativeInt(raw: string, name: string): number {
  if (!/^\d+$/.test(raw)) {
    throw new Error(`${name} must be a non-negative integer`);
  }
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(`${name} is outside the supported integer range`);
  }
  return parsed;
}

function steamId(name: string, value: string): string {
  if (!/^\d+$/.test(value)) {
    throw new Error(`${name} must be a numeric Steam id`);
  }
  return value;
}

function now(): string {
  return new Date().toISOString();
}

function isAuthorized(header: unknown, token: string): boolean {
  return typeof header === "string" && header === `Bearer ${token}`;
}

function publicTask(task: Task, includeInternalTail: boolean) {
  const elapsedSec = task.startedAt
    ? Math.max(0, Math.floor((Date.now() - Date.parse(task.startedAt)) / 1000))
    : 0;
  return {
    id: task.id,
    kind: task.kind,
    state: task.state,
    label: task.label,
    createdAt: task.createdAt,
    startedAt: task.startedAt,
    finishedAt: task.finishedAt,
    elapsedSec,
    exitCode: task.exitCode,
    error: task.error,
    targetDir: task.targetDir,
    runtimeTargetDir: task.role === "mcp" && task.targetDir ? mcpRuntimeTargetPath(task.targetDir) : undefined,
    targetBytes: task.targetDir ? dirSize(task.targetDir) : undefined,
    preflight: task.preflight,
    outputTail: includeInternalTail ? task.outputTail.slice(-config.outputTailLines) : undefined,
  };
}

function mcpRuntimeTargetPath(sidecarTargetDir: string): string | undefined {
  const resolved = path.resolve(sidecarTargetDir);
  const root = config.downloadRoot;
  if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
    return undefined;
  }
  return path.join(config.mcpRuntimeDownloadRoot, path.relative(root, resolved));
}

function dirSize(root: string): number | undefined {
  try {
    let total = 0;
    const stack = [root];
    while (stack.length > 0) {
      const current = stack.pop()!;
      for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
        const entryPath = path.join(current, entry.name);
        if (entry.isDirectory()) {
          stack.push(entryPath);
        } else if (entry.isFile()) {
          total += fs.statSync(entryPath).size;
        }
      }
    }
    return total;
  } catch {
    return undefined;
  }
}

function dirHasEntries(root: string | undefined): boolean {
  if (!root) {
    return false;
  }
  try {
    return fs.statSync(root).isDirectory() && fs.readdirSync(root).length > 0;
  } catch {
    return false;
  }
}

function validateCompletedTask(task: Task) {
  if (task.kind === "download-workshop" && !dirHasEntries(task.targetDir)) {
    throw new Error(`SteamCMD completed but workshop item directory is missing or empty: ${task.targetDir || "unknown"}`);
  }
}

function resetWorkshopState(appId: string): string[] {
  const workshopRoot = path.join(config.steamHome, "Steam", "steamapps", "workshop");
  const downloadsRoot = path.join(workshopRoot, "downloads");
  const candidates = [
    path.join(workshopRoot, `appworkshop_${appId}.acf`),
    path.join(downloadsRoot, appId),
    path.join(workshopRoot, "temp", appId),
  ];

  try {
    for (const entry of fs.readdirSync(downloadsRoot)) {
      if (entry.startsWith(`state_${appId}_${appId}_`) && entry.endsWith(".patch")) {
        candidates.push(path.join(downloadsRoot, entry));
      }
    }
  } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) {
      throw error;
    }
  }

  const removed: string[] = [];
  for (const candidate of candidates) {
    if (!candidate.startsWith(`${workshopRoot}${path.sep}`)) {
      throw new Error(`refusing to reset path outside Steam workshop root: ${candidate}`);
    }
    if (fs.existsSync(candidate)) {
      fs.rmSync(candidate, { recursive: true, force: true });
      removed.push(candidate);
    }
  }
  return removed;
}

function makeMcpDownloadWritable(task: Task) {
  try {
    if (task.role !== "mcp" || !task.targetDir) {
      return;
    }

    const target = assertUnder(config.downloadRoot, task.targetDir);
    const relative = path.relative(config.downloadRoot, target);
    const firstPart = relative.split(path.sep).find(Boolean);
    if (!firstPart) {
      return;
    }

    const writableRoot = assertUnder(config.downloadRoot, path.join(config.downloadRoot, firstPart));
    chmodTreeForSharedWrite(writableRoot);
  } catch {
    // Download success should not be masked by best-effort permission repair.
  }
}

function chmodTreeForSharedWrite(root: string) {
  if (!fs.existsSync(root)) {
    return;
  }

  const stack = [root];
  while (stack.length > 0) {
    const current = stack.pop()!;
    let stat: fs.Stats;
    try {
      stat = fs.lstatSync(current);
    } catch {
      continue;
    }

    if (stat.isSymbolicLink()) {
      continue;
    }

    try {
      fs.chmodSync(current, stat.mode | (stat.isDirectory() ? 0o777 : 0o666));
    } catch {
      continue;
    }

    if (!stat.isDirectory()) {
      continue;
    }

    try {
      for (const entry of fs.readdirSync(current)) {
        stack.push(path.join(current, entry));
      }
    } catch {
      continue;
    }
  }
}

function appendOutput(task: Task, chunk: Buffer) {
  const text = chunk.toString("utf8");
  for (const line of text.split(/\r?\n/)) {
    if (!line) {
      continue;
    }
    task.outputTail.push(line.slice(0, 500));
  }
  const max = Math.max(1, config.outputTailLines);
  if (task.outputTail.length > max) {
    task.outputTail.splice(0, task.outputTail.length - max);
  }
}

function assertUnder(root: string, candidate: string): string {
  const resolvedRoot = path.resolve(root);
  const resolved = path.resolve(candidate);
  if (resolved !== resolvedRoot && !resolved.startsWith(`${resolvedRoot}${path.sep}`)) {
    throw new Error(`path escapes allowed root: ${candidate}`);
  }
  return resolved;
}

function mcpDownloadPath(targetSubdir: string | undefined, fallback: string): string {
  const subdir = targetSubdir || fallback;
  if (path.isAbsolute(subdir) || subdir.split(/[\\/]+/).includes("..")) {
    throw new Error("targetSubdir must be relative and must not contain '..'");
  }
  return assertUnder(config.downloadRoot, path.join(config.downloadRoot, subdir));
}

function internalTargetPath(targetDir: string): string {
  const resolved = path.resolve(targetDir);
  try {
    return assertUnder(config.knowledgeRoot, resolved);
  } catch {
    return assertUnder(config.downloadRoot, resolved);
  }
}

function ensureWorkshopTarget(appId: string, targetDir: string) {
  fs.mkdirSync(targetDir, { recursive: true });
  const contentParent = path.join(config.steamHome, "Steam", "steamapps", "workshop", "content");
  const contentDir = path.join(contentParent, appId);
  fs.mkdirSync(contentParent, { recursive: true });

  let existingStat: fs.Stats | undefined;
  try {
    existingStat = fs.lstatSync(contentDir);
  } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ENOENT")) {
      throw error;
    }
  }

  if (existingStat) {
    const wanted = fs.realpathSync(targetDir);

    if (!existingStat.isSymbolicLink()) {
      throw new Error(`workshop content path exists and is not sidecar-managed symlink: ${contentDir}`);
    }

    let existing: string | undefined;
    try {
      existing = fs.realpathSync(contentDir);
    } catch {
      existing = undefined;
    }

    if (existing === wanted) {
      return;
    }

    fs.unlinkSync(contentDir);
  }

  fs.symlinkSync(targetDir, contentDir, "dir");
}

function commonSteamArgs(): string[] {
  if (!config.steamUser) {
    throw new Error("CK3QQBOT_STEAM_USER is required before running SteamCMD tasks");
  }

  return [
    "+@ShutdownOnFailedCommand",
    "1",
    "+@NoPromptForPassword",
    "1",
    "+login",
    config.steamUser,
  ];
}

function enqueueTask(task: Omit<Task, "id" | "createdAt" | "state" | "outputTail">): Task {
  const fullTask: Task = {
    ...task,
    id: randomUUID(),
    createdAt: now(),
    state: "queued",
    outputTail: [],
  };
  tasks.set(fullTask.id, fullTask);
  queue.push(fullTask);
  drainQueue();
  return fullTask;
}

function enqueueCheckLogin(role: TaskRole): Task {
  return enqueueTask({
    kind: "check-login",
    role,
    label: "check SteamCMD cached login",
    args: [...commonSteamArgs(), "+quit"],
  });
}

function enqueueDepot(role: TaskRole, appId: string, depotId: string, manifestId: string | undefined, targetDir: string): Task {
  return enqueueDepotWithPreflight(role, appId, depotId, manifestId, targetDir);
}

function enqueueDepotWithPreflight(role: TaskRole, appId: string, depotId: string, manifestId: string | undefined, targetDir: string, preflight?: SizePreflight): Task {
  fs.mkdirSync(targetDir, { recursive: true });
  return enqueueTask({
    kind: "download-depot",
    role,
    label: `download_depot ${appId} ${depotId}`,
    targetDir,
    preflight,
    args: [
      ...commonSteamArgs(),
      "+download_depot",
      appId,
      depotId,
      manifestId || "0",
      "0",
      targetDir,
      "+quit",
    ],
  });
}

function enqueueWorkshop(role: TaskRole, appId: string, itemId: string, targetDir: string): Task {
  return enqueueWorkshopWithPreflight(role, appId, itemId, targetDir);
}

function enqueueWorkshopWithPreflight(role: TaskRole, appId: string, itemId: string, targetDir: string, preflight?: SizePreflight): Task {
  ensureWorkshopTarget(appId, targetDir);
  return enqueueTask({
    kind: "download-workshop",
    role,
    label: `workshop_download_item ${appId} ${itemId}`,
    targetDir: path.join(targetDir, itemId),
    preflight,
    args: [...commonSteamArgs(), "+workshop_download_item", appId, itemId, "+quit"],
  });
}

function drainQueue() {
  if (activeTask || queue.length === 0) {
    return;
  }
  const task = queue.shift()!;
  activeTask = task;
  task.state = "running";
  task.startedAt = now();

  const child = spawn(config.steamcmdBin, task.args, {
    cwd: "/",
    env: { ...process.env, HOME: config.steamHome },
  });
  task.process = child;
  child.stdout.on("data", chunk => appendOutput(task, chunk));
  child.stderr.on("data", chunk => appendOutput(task, chunk));
  child.on("error", error => {
    task.state = "failed";
    task.error = error.message;
    task.finishedAt = now();
    task.process = undefined;
    activeTask = undefined;
    drainQueue();
  });
  child.on("close", code => {
    task.exitCode = code;
    task.finishedAt = now();
    task.process = undefined;
    if (task.state === "cancelled") {
      activeTask = undefined;
      drainQueue();
      return;
    }
    if (code === 0 && !loginOutputLooksBad(task.outputTail)) {
      try {
        validateCompletedTask(task);
        task.state = "succeeded";
        makeMcpDownloadWritable(task);
      } catch (error) {
        task.state = "failed";
        task.error = error instanceof Error ? error.message : String(error);
      }
    } else {
      task.state = "failed";
      task.error = code === 0 ? "SteamCMD output indicates login failure" : `SteamCMD exited with ${code}`;
    }
    activeTask = undefined;
    drainQueue();
  });
}

function loginOutputLooksBad(lines: string[]): boolean {
  return lines.some(line =>
    /Invalid Password|No cached credentials|password required|Steam Guard|Two-factor|not logged on|Login Failure|FAILED \(No Connection\)|FAILED with result/i.test(line),
  );
}

function cancelTask(id: string): Task {
  const task = tasks.get(id);
  if (!task) {
    throw new Error(`unknown task: ${id}`);
  }
  if (task.state === "queued") {
    const index = queue.findIndex(candidate => candidate.id === id);
    if (index >= 0) {
      queue.splice(index, 1);
    }
    task.state = "cancelled";
    task.finishedAt = now();
    return task;
  }
  if (task.state === "running" && task.process) {
    task.state = "cancelled";
    task.error = "cancelled by request";
    task.process.kill("SIGTERM");
  }
  return task;
}

function assertMcpDownloadAllowed(preflight: SizePreflight) {
  if (preflight.limitKiB <= 0) {
    return;
  }
  if (preflight.sizeKiB > preflight.limitKiB) {
    throw new Error(
      `SteamCMD MCP download rejected: ${preflight.detail} is ${preflight.sizeKiB} KiB, over configured limit ${preflight.limitKiB} KiB`,
    );
  }
}

function noMcpLimit(): boolean {
  return config.mcpMaxDownloadKiB <= 0;
}

function byteCount(raw: unknown, label: string): number {
  if (typeof raw !== "string" && typeof raw !== "number") {
    throw new Error(`${label} is missing`);
  }
  const text = String(raw);
  if (!/^\d+$/.test(text)) {
    throw new Error(`${label} is not a byte count`);
  }
  const parsed = Number.parseInt(text, 10);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(`${label} is outside the supported integer range`);
  }
  return parsed;
}

function sizeKiB(sizeBytes: number): number {
  return Math.ceil(sizeBytes / 1024);
}

async function fetchWorkshopPreflight(appId: string, itemId: string): Promise<SizePreflight | undefined> {
  if (noMcpLimit()) {
    return undefined;
  }

  const body = new URLSearchParams();
  body.set("itemcount", "1");
  body.set("publishedfileids[0]", itemId);

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), config.preflightTimeoutMs);
  try {
    const response = await fetch(config.workshopDetailsUrl, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
      signal: controller.signal,
    });
    if (!response.ok) {
      throw new Error(`Steam PublishedFile API returned HTTP ${response.status}`);
    }
    const payload = await response.json() as any;
    const details = payload?.response?.publishedfiledetails?.[0];
    if (!details || Number(details.result) !== 1) {
      throw new Error(`Steam PublishedFile API did not return usable details for workshop item ${itemId}`);
    }
    if (String(details.consumer_app_id || "") !== appId) {
      throw new Error(`workshop item ${itemId} belongs to app ${details.consumer_app_id}, not requested app ${appId}`);
    }

    const sizeBytes = byteCount(details.file_size, "workshop file_size");
    const preflight = {
      source: "ISteamRemoteStorage/GetPublishedFileDetails",
      sizeBytes,
      sizeKiB: sizeKiB(sizeBytes),
      limitKiB: config.mcpMaxDownloadKiB,
      detail: `workshop item ${itemId} file_size`,
    };
    assertMcpDownloadAllowed(preflight);
    return preflight;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`SteamCMD MCP workshop size preflight failed: ${message}`);
  } finally {
    clearTimeout(timeout);
  }
}

type VdfObject = { [key: string]: VdfValue };
type VdfValue = string | VdfObject;

function tokenizeVdf(text: string): string[] {
  const tokens: string[] = [];
  const regex = /"((?:\\.|[^"\\])*)"|[{}]/g;
  let match: RegExpExecArray | null;
  while ((match = regex.exec(text)) !== null) {
    if (match[0] === "{" || match[0] === "}") {
      tokens.push(match[0]);
    } else {
      tokens.push(match[1].replace(/\\"/g, "\"").replace(/\\\\/g, "\\"));
    }
  }
  return tokens;
}

function parseVdf(text: string): VdfObject {
  const tokens = tokenizeVdf(text);
  let index = 0;

  function parseObject(): VdfObject {
    const object: VdfObject = {};
    while (index < tokens.length) {
      const key = tokens[index++];
      if (key === "}") {
        break;
      }
      if (key === "{") {
        continue;
      }
      const next = tokens[index++];
      if (next === "{") {
        object[key] = parseObject();
      } else if (next && next !== "}") {
        object[key] = next;
      } else {
        break;
      }
    }
    return object;
  }

  return parseObject();
}

function asObject(value: VdfValue | undefined): VdfObject | undefined {
  return value && typeof value === "object" ? value : undefined;
}

function asString(value: VdfValue | undefined): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function findDepotsObject(value: VdfValue | undefined): VdfObject | undefined {
  const object = asObject(value);
  if (!object) {
    return undefined;
  }
  const direct = asObject(object.depots);
  if (direct) {
    return direct;
  }
  for (const child of Object.values(object)) {
    const found = findDepotsObject(child);
    if (found) {
      return found;
    }
  }
  return undefined;
}

function chooseManifest(manifests: VdfObject, manifestId: string | undefined): { branch: string; manifest: VdfObject } {
  if (manifestId) {
    for (const [branch, value] of Object.entries(manifests)) {
      const manifest = asObject(value);
      if (manifest && asString(manifest.gid) === manifestId) {
        return { branch, manifest };
      }
    }
    throw new Error(`manifest ${manifestId} was not found in app_info_print output`);
  }

  const publicManifest = asObject(manifests.public);
  if (publicManifest) {
    return { branch: "public", manifest: publicManifest };
  }

  for (const [branch, value] of Object.entries(manifests)) {
    const manifest = asObject(value);
    if (manifest) {
      return { branch, manifest };
    }
  }

  throw new Error("no depot manifest metadata was found");
}

function depotManifestPreflightFromAppInfo(appId: string, depotId: string, manifestId: string | undefined, appInfo: string): SizePreflight {
  const parsed = parseVdf(appInfo);
  const depots = findDepotsObject(parsed);
  const depot = asObject(depots?.[depotId]);
  if (!depot) {
    throw new Error(`depot ${depotId} was not found in app_info_print output for app ${appId}`);
  }

  const manifests = asObject(depot.manifests);
  if (!manifests) {
    throw new Error(`depot ${depotId} has no manifest metadata in app_info_print output`);
  }

  const selected = chooseManifest(manifests, manifestId);
  const sizeCandidates = [
    asString(selected.manifest.size),
    asString(selected.manifest.download),
  ].filter((candidate): candidate is string => Boolean(candidate));

  if (sizeCandidates.length === 0) {
    throw new Error(`depot ${depotId} manifest ${asString(selected.manifest.gid) || selected.branch} does not expose size metadata`);
  }

  const sizeBytes = Math.max(...sizeCandidates.map(candidate => byteCount(candidate, "depot manifest size")));
  return {
    source: "SteamCMD app_info_print depot manifest metadata",
    sizeBytes,
    sizeKiB: sizeKiB(sizeBytes),
    limitKiB: config.mcpMaxDownloadKiB,
    detail: `depot ${depotId} manifest ${asString(selected.manifest.gid) || selected.branch} size`,
  };
}

function runSteamcmdCapture(args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(config.steamcmdBin, args, {
      cwd: "/",
      env: { ...process.env, HOME: config.steamHome },
    });

    let output = "";
    let settled = false;

    const timeout = setTimeout(() => {
      if (!settled) {
        settled = true;
        child.kill("SIGTERM");
        reject(new Error(`SteamCMD preflight timed out after ${Math.floor(config.preflightTimeoutMs / 1000)} seconds`));
      }
    }, config.preflightTimeoutMs);

    const collect = (chunk: Buffer) => {
      if (settled) {
        return;
      }
      output += chunk.toString("utf8");
      if (output.length > config.appInfoOutputMaxBytes) {
        settled = true;
        clearTimeout(timeout);
        child.kill("SIGTERM");
        reject(new Error(`SteamCMD preflight output exceeded ${config.appInfoOutputMaxBytes} bytes`));
      }
    };

    child.stdout.on("data", collect);
    child.stderr.on("data", collect);
    child.on("error", error => {
      if (!settled) {
        settled = true;
        clearTimeout(timeout);
        reject(error);
      }
    });
    child.on("close", code => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      if (code === 0 && !loginOutputLooksBad(output.split(/\r?\n/))) {
        resolve(output);
      } else {
        reject(new Error(code === 0 ? "SteamCMD output indicates login failure" : `SteamCMD exited with ${code}`));
      }
    });
  });
}

async function fetchDepotPreflight(appId: string, depotId: string, manifestId: string | undefined): Promise<SizePreflight | undefined> {
  if (noMcpLimit()) {
    return undefined;
  }
  if (activeTask || queue.length > 0) {
    throw new Error("SteamCMD MCP depot size preflight failed: SteamCMD sidecar is busy");
  }

  try {
    const appInfo = await runSteamcmdCapture([
      ...commonSteamArgs(),
      "+app_info_update",
      "1",
      "+app_info_print",
      appId,
      "+quit",
    ]);
    const preflight = depotManifestPreflightFromAppInfo(appId, depotId, manifestId, appInfo);
    assertMcpDownloadAllowed(preflight);
    return preflight;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`SteamCMD MCP depot size preflight failed: ${message}`);
  }
}

function getMcpTask(id: string): Task {
  const task = tasks.get(id);
  if (!task || task.role !== "mcp") {
    throw new Error(`unknown task: ${id}`);
  }
  return task;
}

function makeMcpServer(): McpServer {
  const server = new McpServer({
    name: "ck3qqbot-steamcmd-sidecar",
    version: "0.1.0",
  });

  server.registerTool("steamcmd_download_depot", {
    description: "Queue a SteamCMD download_depot task into the dedicated MCP download directory.",
    inputSchema: {
      appId: z.string().regex(/^\d+$/),
      depotId: z.string().regex(/^\d+$/),
      manifestId: z.string().regex(/^\d+$/).optional(),
      targetSubdir: z.string().optional(),
    },
  }, async ({ appId, depotId, manifestId, targetSubdir }) => {
    const targetDir = mcpDownloadPath(targetSubdir, `depots/${appId}/${depotId}`);
    const safeAppId = steamId("appId", appId);
    const safeDepotId = steamId("depotId", depotId);
    const safeManifestId = manifestId ? steamId("manifestId", manifestId) : undefined;
    const preflight = await fetchDepotPreflight(safeAppId, safeDepotId, safeManifestId);
    const task = enqueueDepotWithPreflight("mcp", safeAppId, safeDepotId, safeManifestId, targetDir, preflight);
    return { content: [{ type: "text", text: JSON.stringify(publicTask(task, false), null, 2) }] };
  });

  server.registerTool("steamcmd_download_workshop_item", {
    description: "Queue a SteamCMD workshop_download_item task into the dedicated MCP download directory.",
    inputSchema: {
      appId: z.string().regex(/^\d+$/),
      itemId: z.string().regex(/^\d+$/),
      targetSubdir: z.string().optional(),
    },
  }, async ({ appId, itemId, targetSubdir }) => {
    const targetDir = mcpDownloadPath(targetSubdir, `workshop/${appId}`);
    const safeAppId = steamId("appId", appId);
    const safeItemId = steamId("itemId", itemId);
    const preflight = await fetchWorkshopPreflight(safeAppId, safeItemId);
    const task = enqueueWorkshopWithPreflight("mcp", safeAppId, safeItemId, targetDir, preflight);
    return { content: [{ type: "text", text: JSON.stringify(publicTask(task, false), null, 2) }] };
  });

  server.registerTool("steamcmd_get_task_status", {
    description: "Get a SteamCMD task status by task id. This does not expose raw SteamCMD logs.",
    inputSchema: {
      taskId: z.string().uuid(),
    },
  }, async ({ taskId }) => {
    const task = getMcpTask(taskId);
    return { content: [{ type: "text", text: JSON.stringify(publicTask(task, false), null, 2) }] };
  });

  server.registerTool("steamcmd_cancel_task", {
    description: "Cancel a queued or running SteamCMD task by task id.",
    inputSchema: {
      taskId: z.string().uuid(),
    },
  }, async ({ taskId }) => {
    getMcpTask(taskId);
    const task = cancelTask(taskId);
    return { content: [{ type: "text", text: JSON.stringify(publicTask(task, false), null, 2) }] };
  });

  return server;
}

function asyncHandler(fn: (req: any, res: any) => Promise<void>) {
  return (req: any, res: any) => {
    fn(req, res).catch((error: unknown) => {
      const message = error instanceof Error ? error.message : String(error);
      res.status(400).json({ error: message });
    });
  };
}

function main() {
  fs.mkdirSync(config.steamHome, { recursive: true });
  fs.mkdirSync(config.downloadRoot, { recursive: true });

  const app = createMcpExpressApp({ host: config.host });

  app.get("/healthz", (_req, res) => {
    res.json({ ok: true, activeTaskId: activeTask?.id, queued: queue.length });
  });

  app.post("/v1/internal/tasks/check-login", asyncHandler(async (req, res) => {
    if (!isAuthorized(req.headers.authorization, config.internalToken)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    const task = enqueueCheckLogin("internal");
    res.status(202).json(publicTask(task, true));
  }));

  app.post("/v1/internal/tasks/download-depot", asyncHandler(async (req, res) => {
    if (!isAuthorized(req.headers.authorization, config.internalToken)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    const body = req.body || {};
    const targetDir = internalTargetPath(String(body.targetDir || ""));
    const task = enqueueDepot(
      "internal",
      steamId("appId", String(body.appId)),
      steamId("depotId", String(body.depotId)),
      body.manifestId ? steamId("manifestId", String(body.manifestId)) : undefined,
      targetDir,
    );
    res.status(202).json(publicTask(task, true));
  }));

  app.post("/v1/internal/workshop-state/reset", asyncHandler(async (req, res) => {
    if (!isAuthorized(req.headers.authorization, config.internalToken)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    const body = req.body || {};
    const appId = steamId("appId", String(body.appId));
    const removed = resetWorkshopState(appId);
    res.json({ ok: true, appId, removed });
  }));

  app.post("/v1/internal/tasks/download-workshop", asyncHandler(async (req, res) => {
    if (!isAuthorized(req.headers.authorization, config.internalToken)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    const body = req.body || {};
    const targetDir = internalTargetPath(String(body.targetDir || ""));
    const task = enqueueWorkshop(
      "internal",
      steamId("appId", String(body.appId)),
      steamId("itemId", String(body.itemId)),
      targetDir,
    );
    res.status(202).json(publicTask(task, true));
  }));

  app.get("/v1/internal/tasks/:id", (req, res) => {
    if (!isAuthorized(req.headers.authorization, config.internalToken)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    const task = tasks.get(req.params.id);
    if (!task) {
      res.status(404).json({ error: "unknown task" });
      return;
    }
    res.json(publicTask(task, true));
  });

  app.post("/v1/internal/tasks/:id/cancel", (req, res) => {
    if (!isAuthorized(req.headers.authorization, config.internalToken)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }
    res.json(publicTask(cancelTask(req.params.id), true));
  });

  app.post("/mcp", async (req, res) => {
    if (!isAuthorized(req.headers.authorization, config.mcpToken)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }

    const server = makeMcpServer();
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
    });
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
    res.on("close", () => {
      transport.close();
      server.close();
    });
  });

  app.get("/mcp", (_req, res) => {
    res.status(405).set("Allow", "POST").send("Method Not Allowed");
  });

  app.delete("/mcp", (_req, res) => {
    res.status(405).set("Allow", "POST").send("Method Not Allowed");
  });

  app.listen(config.port, config.host, error => {
    if (error) {
      console.error("failed to start steamcmd-sidecar", error);
      process.exit(1);
    }
    console.log(`steamcmd-sidecar listening on ${config.host}:${config.port}`);
  });
}

main();
