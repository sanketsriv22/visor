// Chat-side of the Visor MCP server: lets an agent read the user's
// conversations, search them, and post into one so the user sees it in the
// notch.
//
// Chats are one JSON file per conversation plus an index.json cache. The
// index is only a cache — every read here goes to the chat files themselves,
// so an agent never sees a stale listing if the app hasn't rewritten the
// index yet.
import { promises as fs } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

function expandTilde(p: string): string {
  return p.startsWith("~/") ? join(homedir(), p.slice(2)) : p;
}

/** Matches ChatStore.defaultRoot on the Swift side. */
export function dataRoot(): string {
  const custom = process.env.VISOR_DATA_DIR;
  if (custom) return expandTilde(custom);
  return join(homedir(), "StickyNotes");
}

export function chatsDir(): string {
  return join(dataRoot(), "chats");
}

export type Role = "system" | "user" | "assistant";

export interface ChatMessage {
  id: string;
  role: Role;
  content: string;
  createdAt: string;
  model?: string;
}

export interface Conversation {
  id: string;
  title: string;
  agentName: string;
  model: string;
  messages: ChatMessage[];
  createdAt: string;
  updatedAt: string;
}

async function chatFiles(): Promise<string[]> {
  let names: string[];
  try {
    names = await fs.readdir(chatsDir());
  } catch {
    return [];
  }
  return names
    .filter((n) => n.endsWith(".json") && n !== "index.json")
    .map((n) => join(chatsDir(), n));
}

export async function allChats(): Promise<Conversation[]> {
  const files = await chatFiles();
  const chats: Conversation[] = [];
  for (const file of files) {
    try {
      const parsed = JSON.parse(await fs.readFile(file, "utf8")) as Conversation;
      // A hand-edited or half-written file shouldn't take down the listing.
      if (parsed && Array.isArray(parsed.messages)) chats.push(parsed);
    } catch {
      /* skip unreadable chat */
    }
  }
  return chats.sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1));
}

/** Resolve a chat by id, or by a case-insensitive title match. */
export async function findChat(ref: string): Promise<Conversation | null> {
  const chats = await allChats();
  const needle = ref.trim().toLowerCase();
  return (
    chats.find((c) => c.id.toLowerCase() === needle) ??
    chats.find((c) => c.title.toLowerCase() === needle) ??
    chats.find((c) => c.title.toLowerCase().includes(needle)) ??
    null
  );
}

export async function writeChat(chat: Conversation): Promise<void> {
  await fs.mkdir(chatsDir(), { recursive: true });
  const target = join(chatsDir(), `${chat.id}.json`);
  // Write-then-rename: the app may read this file at any moment, and a
  // half-written chat would fail to parse.
  const tmp = `${target}.tmp`;
  await fs.writeFile(tmp, JSON.stringify(chat, null, 2), "utf8");
  await fs.rename(tmp, target);
  await invalidateIndex();
}

/**
 * Drop the index cache after a write.
 *
 * Rewriting it here would mean duplicating the app's summary logic in a second
 * language and keeping the two in step forever. The app rebuilds the index from
 * the chat files whenever it's missing, so deleting it is both correct and
 * cheaper to maintain.
 */
async function invalidateIndex(): Promise<void> {
  try {
    await fs.unlink(join(chatsDir(), "index.json"));
  } catch {
    /* no index to invalidate */
  }
}

export function newChat(title: string, agentName: string, model: string): Conversation {
  const now = new Date().toISOString();
  return {
    id: randomUUID().toUpperCase(),
    title,
    agentName,
    model,
    messages: [],
    createdAt: now,
    updatedAt: now,
  };
}

export function message(role: Role, content: string, model?: string): ChatMessage {
  return {
    id: randomUUID().toUpperCase(),
    role,
    content,
    createdAt: new Date().toISOString(),
    ...(model ? { model } : {}),
  };
}

/** One line per chat, for listings. */
export function summarise(chat: Conversation) {
  return {
    id: chat.id,
    title: chat.title || "Untitled",
    agent: chat.agentName,
    model: chat.model,
    messages: chat.messages.length,
    updatedAt: chat.updatedAt,
  };
}
