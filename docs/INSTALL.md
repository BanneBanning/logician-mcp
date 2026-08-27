# Installation Guide

**~10 minutes, most of it waiting for a build.** No prior setup knowledge needed. Every step tells you what you should see, and there is one tool — `logic_health` — that checks your work and names the fix for anything still wrong. If you get stuck, jump to [Troubleshooting](#troubleshooting); it is keyed to exactly what `logic_health` tells you.

You will do four things:

1. [Build the app](#1-build-the-app) (one command)
2. [Connect it to your AI](#2-connect-it-to-your-ai) (one command)
3. [Let Logic see it](#3-let-logic-see-it) (a few clicks in Logic, once)
4. [Check it works](#4-check-it-works) (ask the agent to run `logic_health`)

---

## Before you start

You need:

- **macOS 13 or newer** (Apple menu → About This Mac).
- **Logic Pro**, with a project open.
- **An MCP client** — the app your AI runs in. This guide covers [Antigravity CLI](#option-a-antigravity-cli--gemini-recommended) (recommended, because the agent can *hear* your mix), [Claude Code](#option-b-claude-code), and [Gemini CLI](#option-c-gemini-cli).

One prerequisite most Macs already have — the Swift build tools. Check by pasting this into Terminal (⌘-Space, type "Terminal", Enter):

```bash
swift --version
```

If it prints a version, you are set. If it says "command not found", install the tools (a few minutes, click through Apple's prompt), then run the check again:

```bash
xcode-select --install
```

---

## 1. Build the app

Paste these three lines into Terminal, one block, and press Enter. It downloads Logician and compiles it. The compile takes a minute or two — a wall of text scrolling is normal.

```bash
git clone https://github.com/BanneBanning/logician-mcp.git
cd logician-mcp
swift build -c release
```

**You should see:** `Build complete!` on the last line.

Now print the full path to the app and **copy it** — you need it in the next step:

```bash
echo "$(pwd)/.build/release/logician"
```

It looks like `/Users/you/logician-mcp/.build/release/logician`. Keep it on your clipboard.

---

## 2. Connect it to your AI

Do the one block that matches your client. Replace `PASTE_PATH_HERE` with the path you just copied.

### Option A — Antigravity CLI + Gemini (recommended)

Recommended because Gemini can actually listen to your mix. In Terminal:

```bash
agy mcp add logician PASTE_PATH_HERE
```

Then **fully quit and reopen** Antigravity (it only loads MCP servers when it starts). Confirm it registered:

```bash
agy mcp list
```

**You should see:** a `logician` row marked `enabled`.

### Option B — Claude Code

```bash
claude mcp add logician -- PASTE_PATH_HERE
```

### Option C — Gemini CLI

Open `~/.gemini/settings.json` in any text editor and add this (create the file if it does not exist):

```json
{ "mcpServers": { "logician": { "command": "PASTE_PATH_HERE" } } }
```

Then restart the Gemini CLI.

---

## 3. Let Logic see it

This is the one manual part, and you only ever do it once. It tells Logic to treat Logician as a control surface — the same way you would connect a hardware mixing desk.

**First, wake up the connection.** Open your AI client and ask it, in plain language:

> Run logic_health

This starts Logician's background helper the first time, which creates three MIDI ports Logic needs to see. The health check will report two things still missing — Accessibility and the Mackie Control — which is exactly what the next two steps fix. (If it already says everything is fine, you are done — skip to [step 4](#4-check-it-works).)

**Grant Accessibility.** The first time Logician reads Logic, macOS asks permission — this is macOS letting an app observe another app, and it is required. If a popup appears, click **Open System Settings** and turn the switch **on** for your client (or Terminal). If no popup appeared and health said accessibility is not trusted, open it yourself:

- System Settings → Privacy & Security → **Accessibility**
- Turn on the switch next to your MCP client (Antigravity, Claude, your terminal app, …). If it is not in the list, click **+**, and add the app.

**Add the Mackie Control in Logic:**

1. In Logic, click the **Logic Pro** menu (top-left) → **Control Surfaces** → **Setup…**
2. In the window that opens, click **New ▾** (top-left) → **Install…**
3. In the list, find **Mackie Designs** → **Mackie Control**. Click it, then **Add**.
4. A Mackie Control device appears. Click it to select it. On the right, set **both** ports:
   - **Output Port:** `Logic MCP MCU`
   - **Input Port:** `Logic MCP MCU`

   > Don't see `Logic MCP MCU` in the dropdown? The background helper isn't running yet. Ask the agent to `Run logic_health` once, then reopen this dropdown.
5. Close the window. That's it — you never touch this again.

---

## 4. Check it works

Ask your agent one more time:

> Run logic_health

**You should see** something like: `bridge_running: true`, `mcu_connected: true`, `accessibility_trusted: true`, and no `*_fix` messages. That means hands and ears are both connected.

Try it for real — with a track in your project selected:

> Bounce bars 1 to 4 and tell me what you hear.

If the agent describes the audio, you're done. 🎧

> **The Logic key commands** the tools rely on (Save, Freeze, Undo, …) are learned into your Logic **automatically** the first time a tool needs one — you'll see the Key Commands window flash open for a second. That's expected, it's one-time, and everything it adds is removable in Logic's Key Commands window. You can also do it all up front by asking the agent to `Run logic_setup_key_commands`.

---

## Troubleshooting

`logic_health` is the doctor — it returns a `_fix` line for anything wrong. Here are the common ones:

| `logic_health` says | What to do |
|---|---|
| `accessibility_trusted: false` | System Settings → Privacy & Security → Accessibility → turn on your MCP client (or Terminal). Add it with **+** if it's missing. |
| `mcu_connected: false`, fresh install | You haven't added the Mackie Control yet, or its ports aren't set to `Logic MCP MCU`. Redo [step 3](#3-let-logic-see-it). |
| `mcu_connected: false`, *used to work* | Logic doesn't reopen the port after a restart. Logic → Control Surfaces → Setup → re-pick `Logic MCP MCU` in the Input/Output Port dropdowns. Or just restart Logic. |
| `duplicate_ports: [...]` | Two identical `Logic MCP MCU` entries in Logic's port menu confuse it. Quit your MCP client, run `killall MIDIServer` in Terminal, reopen the client, re-pick the port, then ask the agent to `Run logic_setup_key_commands with relearn true`. |
| a key command "fires but nothing happens" | `Run logic_setup_key_commands with relearn true` — recreated MIDI ports can orphan Logic's bindings. |
| `agy mcp list` doesn't show logician | You edited settings.json by hand — use `agy mcp add` instead, then fully restart Antigravity. |
| the agent says it can't see the `logic_*` tools | Restart the client (MCP servers load only at startup), and ask it to list its tools to confirm. |
| `swift build` fails | Run `xcode-select --install`, let it finish, then `swift build -c release` again. |

Still stuck? Open an issue with the full `logic_health` output pasted in — it contains everything needed to diagnose.

---

## Uninstalling

Nothing was installed system-wide. To remove Logician completely:

1. Remove it from your client: `agy mcp remove logician` (or `claude mcp remove logician`, or delete the entry from `~/.gemini/settings.json`).
2. In Logic → Control Surfaces → Setup, select the Mackie Control device and delete it.
3. Delete the repo folder and `~/Library/Application Support/LogicMCPMCU` (its cache and key-command registry).
4. The key commands it learned are removable in Logic's Key Commands window if you want them gone.
