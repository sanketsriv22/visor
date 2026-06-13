#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { promises as fs } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

function expandTilde(p: string): string {
  return p.startsWith("~/") ? join(homedir(), p.slice(2)) : p;
}

const NOTES_FILE = process.env.STICKY_NOTES_FILE
  ? expandTilde(process.env.STICKY_NOTES_FILE)
  : join(homedir(), "StickyNotes", "sticky.md");
// First-seen timestamps per task, maintained lazily by this server so the
// app can stay a dumb text editor. Keyed by exact task text.
const META_FILE = join(dirname(NOTES_FILE), ".meta.json");

async function readNotes(): Promise<string> {
  try {
    return await fs.readFile(NOTES_FILE, "utf8");
  } catch {
    return "";
  }
}

async function writeNotes(content: string): Promise<void> {
  await fs.mkdir(dirname(NOTES_FILE), { recursive: true });
  await fs.writeFile(NOTES_FILE, content, "utf8");
}

type Meta = Record<string, string>;

async function readMeta(): Promise<Meta> {
  try {
    return JSON.parse(await fs.readFile(META_FILE, "utf8"));
  } catch {
    return {};
  }
}

interface Task {
  text: string;
  done: boolean;
  line: number;
}

const TASK_RE = /^\s*-\s*\[( |x|X)\]\s*(.*)$/;

function parseTasks(content: string): Task[] {
  return content.split("\n").flatMap((raw, i) => {
    const m = raw.match(TASK_RE);
    return m ? [{ text: m[2].trim(), done: m[1].toLowerCase() === "x", line: i }] : [];
  });
}

/** Parse tasks and stamp any not-yet-seen ones with a first-seen time. */
async function stampedTasks() {
  const tasks = parseTasks(await readNotes());
  const meta = await readMeta();
  const now = new Date().toISOString();
  const live = new Set(tasks.map((t) => t.text));
  let changed = false;
  for (const t of tasks) {
    if (!meta[t.text]) {
      meta[t.text] = now;
      changed = true;
    }
  }
  for (const key of Object.keys(meta)) {
    if (!live.has(key)) {
      delete meta[key];
      changed = true;
    }
  }
  if (changed) {
    await fs.mkdir(dirname(META_FILE), { recursive: true });
    await fs.writeFile(META_FILE, JSON.stringify(meta, null, 2));
  }
  return tasks.map((t) => {
    const firstSeen = meta[t.text];
    const ageHours = Math.round(((Date.now() - Date.parse(firstSeen)) / 36e5) * 10) / 10;
    return { ...t, firstSeen, ageHours };
  });
}

async function appendLine(line: string): Promise<void> {
  const content = await readNotes();
  const sep = content.length === 0 || content.endsWith("\n") ? "" : "\n";
  await writeNotes(content + sep + line + "\n");
}

function text(s: string) {
  return { content: [{ type: "text" as const, text: s }] };
}

// Tool handlers run concurrently in the SDK; serialize every handler so
// read-modify-write operations on the notes file can't interleave.
let queue: Promise<unknown> = Promise.resolve();
function locked<T>(fn: () => Promise<T>): Promise<T> {
  const run = queue.then(fn, fn);
  queue = run.catch(() => {});
  return run;
}

// CLI mode: `node index.js --stale [hours]` prints open tasks at least
// `hours` old (default 24) as JSON and exits. Used by scripts/devin-check.sh
// so a cron job gets clean structured input without the MCP handshake.
// Side effect: refreshes first-seen timestamps in .meta.json, same as a
// list_tasks call would.
const argv = process.argv.slice(2);
if (argv[0] === "--stale" || argv[0] === "--list") {
  const hours = argv[0] === "--stale" ? Number(argv[1] ?? "24") : 0;
  const tasks = (await stampedTasks())
    .filter((t) => !t.done && t.ageHours >= hours)
    .map(({ line, ...rest }) => rest);
  console.log(JSON.stringify(tasks, null, 2));
  process.exit(0);
}

const server = new McpServer({ name: "visor", version: "0.1.0" });

server.registerTool(
  "read_sticky",
  {
    description:
      "Read the full raw markdown contents of the user's sticky note. " +
      "Lines like '- [ ] thing' are open tasks; '- [x] thing' are done.",
  },
  async () => locked(async () => text((await readNotes()) || "(sticky note is empty)"))
);

server.registerTool(
  "list_tasks",
  {
    description:
      "List checkbox tasks from the sticky note as JSON, each with a firstSeen " +
      "timestamp and ageHours. Use older_than_hours to find stale open tasks " +
      "the user may have forgotten (e.g. 24 for anything older than a day).",
    inputSchema: {
      older_than_hours: z
        .number()
        .optional()
        .describe("Only return open tasks first seen at least this many hours ago"),
      include_done: z.boolean().optional().describe("Also include completed tasks (default false)"),
    },
  },
  async ({ older_than_hours, include_done }) => locked(async () => {
    let tasks = await stampedTasks();
    if (!include_done) tasks = tasks.filter((t) => !t.done);
    if (older_than_hours !== undefined) {
      tasks = tasks.filter((t) => !t.done && t.ageHours >= older_than_hours);
    }
    const out = tasks.map(({ line, ...rest }) => rest);
    return text(JSON.stringify(out, null, 2));
  })
);

server.registerTool(
  "add_task",
  {
    description: "Append a new open task ('- [ ] …') to the sticky note.",
    inputSchema: {
      text: z.string().min(1).describe("Task description, without the checkbox prefix"),
    },
  },
  async ({ text: taskText }) => locked(async () => {
    await appendLine(`- [ ] ${taskText.trim()}`);
    return text(`Added task: ${taskText.trim()}`);
  })
);

server.registerTool(
  "add_note",
  {
    description: "Append a free-form line of text (not a task) to the sticky note.",
    inputSchema: {
      text: z.string().min(1).describe("Line to append"),
    },
  },
  async ({ text: noteText }) => locked(async () => {
    await appendLine(noteText.trim());
    return text(`Added note: ${noteText.trim()}`);
  })
);

server.registerTool(
  "complete_task",
  {
    description:
      "Mark an open task as done. 'match' is matched case-insensitively against " +
      "open task text; it must match exactly one task.",
    inputSchema: {
      match: z.string().min(1).describe("Substring identifying the task to complete"),
    },
  },
  async ({ match }) => locked(async () => {
    const content = await readNotes();
    const open = parseTasks(content).filter((t) => !t.done);
    const hits = open.filter((t) => t.text.toLowerCase().includes(match.toLowerCase()));
    if (hits.length === 0) {
      return text(`No open task matches "${match}". Open tasks:\n${open.map((t) => `- ${t.text}`).join("\n") || "(none)"}`);
    }
    if (hits.length > 1) {
      return text(`"${match}" is ambiguous; it matches:\n${hits.map((t) => `- ${t.text}`).join("\n")}\nBe more specific.`);
    }
    const lines = content.split("\n");
    lines[hits[0].line] = lines[hits[0].line].replace(/\[( )\]/, "[x]");
    await writeNotes(lines.join("\n"));
    return text(`Completed: ${hits[0].text}`);
  })
);

const transport = new StdioServerTransport();
await server.connect(transport);
console.error(`sticky-notes MCP server running (notes: ${NOTES_FILE})`);
