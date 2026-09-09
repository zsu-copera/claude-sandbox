#!/usr/bin/env node
//
// preToolUse guardrail for the Copilot CLI inside the sandbox.
//
// Installed by the Dockerfile as MACHINE POLICY (/etc/github-copilot/policy.d/),
// not as user config, which is the whole point: policy hooks load before every
// other hook, cannot be switched off by `disableAllHooks`, and are root-owned so
// the agent cannot rewrite them. run-copilot.sh runs the CLI with
// --allow-all-tools, so this hook is the layer that keeps that defensible.
//
// It exists for two jobs:
//
// 1. Obfuscation. An autonomous agent has no legitimate reason to escape quotes,
//    pipe base64 into an interpreter, or assemble a command from character
//    codes. All three defeat human review of the transcript, which is the last
//    control in this design.
//
// 2. The no-push barrier. run-copilot.sh passes --deny-tool 'shell(git push)',
//    but that rule matches a command-identifier PREFIX and is evaded by
//    `git -C . push` (verified 2026-09-09). The deny-tool flags are kept because
//    they give a clearer message for the common case; these rules are what
//    actually close the hole, because a hook sees the whole command string.
//
// Protocol (verified against CLI 1.0.83):
//   stdin  {"sessionId","timestamp","cwd","toolName","toolArgs":{"command",...}}
//   stdout {} for no opinion, or
//          {"permissionDecision":"deny","permissionDecisionReason":"..."}
//          The decision keys are TOP LEVEL. A Claude-style
//          {"hookSpecificOutput":{...}} envelope is silently ignored.
//   exit   0. Non-zero denies but reports as a hook error and hides the reason.
//
// Fail behaviour, which is not symmetrical and matters here: a crash or any
// non-zero exit fails CLOSED, but a TIMEOUT always fails OPEN — even for policy
// hooks. Hence the deliberately generous timeoutSec in the policy file and the
// absence of any I/O below.

"use strict";

const SHELL_TOOLS = new Set(["bash", "powershell", "local_shell", "shell"]);

// Command position: start of input, after a separator, or after a wrapper that
// execs its argument. Without this, `echo 'git push' >> notes.txt` would trip
// the git rules.
const LEAD = String.raw`(?:^|[;&|\n(]|\$\(|\`|\b(?:env|sudo|nohup|time|xargs|exec)\s+)\s*`;
// Global git options that may sit between `git` and its subcommand.
const GIT_GLOBALS = String.raw`(?:\s+(?:-[cC]\s*\S+|--[a-z-]+(?:=\S+)?|-\w))*`;

const RULES = [
  {
    id: "escaped-quote",
    test: /\\["']|`["']/,
    message:
      'Escaped quotation marks (\\" \\\' or backtick-quote) are not allowed. They obscure the ' +
      "command from the human review this sandbox depends on. Rewrite so no quote needs " +
      "escaping: swap the outer quote style, or write the payload to a file and run the file.",
  },
  {
    id: "base64-decode",
    test: /base64\s+(?:-d\b|--decode\b|-D\b)|FromBase64String|b64decode/i,
    message:
      "Decoding base64 into an interpreter hides what is being run. Write the script out in " +
      "plain text and run that file instead.",
  },
  {
    id: "encoded-command",
    test: /-e(?:nc|ncoded|ncodedcommand)?\s+[A-Za-z0-9+/=]{24,}/i,
    message: "Encoded commands are not allowed: they hide what is being run.",
  },
  {
    id: "char-code-assembly",
    test: /\[char\]\s*\d+|String\.fromCharCode|\$\(\s*printf\s+'\\[0-7x]/i,
    message:
      "Assembling a command from character codes hides what is being run. Write it out literally.",
  },
  {
    id: "git-push",
    test: new RegExp(LEAD + String.raw`git\b` + GIT_GLOBALS + String.raw`\s+push\b`, "i"),
    message:
      "Pushing is not possible from this sandbox and not permitted: the repositories have no " +
      "remotes, the agent holds no git credentials, and egress excludes the forge. Commit " +
      "locally and leave the branch for a human to review and push.",
  },
  {
    id: "git-remote-mutation",
    test: new RegExp(
      LEAD + String.raw`git\b` + GIT_GLOBALS + String.raw`\s+remote\s+(?:add|set-url|rename)\b`,
      "i"
    ),
    message:
      "Adding or repointing a git remote is not permitted: the absence of remotes is one of the " +
      "barriers preventing work from leaving this sandbox. `git remote -v` is fine.",
  },
];

function commandOf(payload) {
  const toolName = String(payload.toolName || payload.tool_name || "").toLowerCase();
  if (!SHELL_TOOLS.has(toolName)) return null;

  const args = payload.toolArgs || payload.tool_input || payload.toolInput || {};
  const parts = [args.command, args.script, args.cmd].filter((v) => typeof v === "string");
  return parts.length ? parts.join("\n") : null;
}

function emit(obj) {
  process.stdout.write(JSON.stringify(obj));
}

function deny(reason) {
  emit({ permissionDecision: "deny", permissionDecisionReason: reason });
}

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => (raw += chunk));
process.stdin.on("end", () => {
  let command;
  try {
    command = commandOf(JSON.parse(raw || "{}"));
  } catch (err) {
    // Fail closed: if the guardrail cannot read the command, do not run it.
    deny(
      "Blocked by sandbox policy: the guardrail could not inspect this call " +
        `(${err && err.message}). This is a bug in the sandbox image, not something to work around.`
    );
    return;
  }

  if (!command) {
    emit({});
    return;
  }

  for (const rule of RULES) {
    if (rule.test.test(command)) {
      deny(`Blocked by sandbox policy "${rule.id}". ${rule.message}`);
      return;
    }
  }
  emit({});
});
