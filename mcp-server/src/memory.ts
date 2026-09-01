// Voice log and knowledge graph, exposed to agents.
//
// Chats are what the user typed. These are the two things they didn't: what
// they said out loud, and what Visor has worked out from talking to them. An
// agent that can read a transcript but not either of those is missing most of
// what the app knows.
import { promises as fs } from "node:fs";
import { join } from "node:path";
import { dataRoot } from "./chats.js";

export interface VoiceEntry {
  id: string;
  text: string;
  date: string;
  duration?: number;
  conversation?: string;
}

export interface MemoryNode {
  id: string;
  name: string;
  kind: string;
  mentions: number;
  firstSeen: string;
  lastSeen: string;
}

export interface MemoryEdge {
  id: string;
  from: string;
  relation: string;
  to: string;
  conversation?: string;
  createdAt: string;
}

/** Parse JSON Lines, skipping anything unreadable. */
async function readJsonl<T>(path: string): Promise<T[]> {
  let text: string;
  try {
    text = await fs.readFile(path, "utf8");
  } catch {
    return [];
  }
  const out: T[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line) as T);
    } catch {
      // A half-written final line costs that line, not the file.
    }
  }
  return out;
}

export async function voiceEntries(): Promise<VoiceEntry[]> {
  const entries = await readJsonl<VoiceEntry>(join(dataRoot(), "voice-log.jsonl"));
  return entries.sort((a, b) => (a.date < b.date ? 1 : -1));
}

export async function graphNodes(): Promise<MemoryNode[]> {
  return readJsonl<MemoryNode>(join(dataRoot(), ".graph", "nodes.jsonl"));
}

export async function graphEdges(): Promise<MemoryEdge[]> {
  return readJsonl<MemoryEdge>(join(dataRoot(), ".graph", "edges.jsonl"));
}

/** Claims touching an entity, rendered as readable lines. */
export async function claimsAbout(name: string): Promise<string[]> {
  const [nodes, edges] = await Promise.all([graphNodes(), graphEdges()]);
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const needle = name.trim().toLowerCase();
  const matched = nodes.filter((n) => n.id.includes(needle) || needle.includes(n.id));
  if (matched.length === 0) return [];
  const ids = new Set(matched.map((n) => n.id));
  return edges
    .filter((e) => ids.has(e.from) || ids.has(e.to))
    .map((e) => `${byId.get(e.from)?.name ?? e.from} ${e.relation} ${byId.get(e.to)?.name ?? e.to}`);
}
