# Environment

Welcome. You're on a NixOS 26.05 machine where many things are already installed, including:

ripgrep, ripgrep-all, node, deno, pnpm, jq, python3, uv, google-chrome, curl-impersonate, gcc, go, rustc, cargo, patchelf, zip, unzip, zstd.

# Avoid consuming tokens in excess

When verifying how something works, use e.g. `rg -B2 -A10` until you need the whole file.

# There's plenty of time

If more external information is needed, think and keep iterating on web search queries to thoroughly check things. Tips: try site-specific searches e.g. site:github.com, reddit.com, news.ycombinator.com; try combinations of quoted items.

If you can't fetch something, try with headless google-chrome or curl_chrome146 on this machine.

If you need some information from e.g. Twitter or Discord or IRC or web archives which still fail to fetch, stop and ask the user.

# Tracking AI authorship

Files with any LLM-authored code (not counting mechanistic sed-like changes) begin with `// Model-output: <model name>`, one per model that contributed (e.g. "Claude Fable 5", "ChatGPT 5.5 Pro"). Keep existing lines.

# Code conventions

When writing _any_ kind of code, including for the above:

- Think about invariants and add asserts or domain-specific errors where they might prevent misbehavior.
- Except where very obvious or redundant, write a docstring describing each argument, and the return value when not void. What do they really represent?
- The "main" function goes at the end and depends on functions above, which depend on functions further above, etc.
- Scan the functions and generalize if that makes a good result; evict any deadbeats: humans with a small context window need to review and maintain this code.
- Abstraction boundaries are important. Comments should reflect the current abstraction and generally avoid talking about other things.

Minutae:

- Use the { } curlies even for one-statement blocks.
- Block contents should not be on the same line that opened the block.
- Put `return`, `continue`, `break`, `throw` statements on their own line so that they're obvious.
- Blank lines inside functions should only be used to separate different ideas or groups of steps.
- Used space-based alignment only where it looks good: on adjacent lines with a very similar structure, add spaces after shorter identifiers (or the syntax to the right of them) to align things.

# Programming thoughts

The real difficulty with programming is not getting a program that runs, but a coherent, maintainable artifact that humans are happy with.

A program can be:
- shorter.
- easier to read by a human.
- more correct around edge cases.
- faster than another which does the same thing.
- much easier to change when the requirements change.

These are sometimes in conflict.

It can help to do it different ways and see which version is better.

Sometimes a program can e.g. log or assert to generate interesting observations which feed into further development of the program. Thus, the program births its own artificial science.

When there are multiple good ways to implement something, especially involving state or the definition of a type: please ask the user. User loves AskUserQuestion.

# After making changes

Automatically commit your changes with this commit template:

	subsystem: short one-line description; semicolon if multiple changes

	Model-output: model name e.g. Claude Fable 5

	<prompt>

	user prompt, verbatim

	AskUserQuestion question-answers, if any

	</prompt>

	<slop>

	model's response at the end of the dialogue, verbatim, in markdown format

	</slop>

"(mid-turn)" if I added something mid-turn; multiple <prompt></prompt> <slop></slop> ... if the conversation had several real turns.

# Codex code review after each commit

After each commit you make, get it reviewed by Codex (GPT-5.6-Sol at xhigh reasoning):

	codex review --commit <sha> -c model="gpt-5.6-sol" -c model_reasoning_effort="xhigh"

Notes:

- Codex is configured globally in `~/.codex/config.toml` (`approval_policy = "never"`, `sandbox_mode = "danger-full-access"`) to never ask for permission and run unsandboxed, so reviews and `codex exec` runs never block on prompts. If codex ever stalls waiting for approval, check that file.
- A review can take several minutes; run it in the background and continue if you have other work.
- Sol often nitpicks, or cares about bizarre, irrelevant edge cases. Ignore those findings; they should not stop you from making progress.
- For oversights that are true and interesting, fix them and make another commit (using the usual commit template). If you fixed nothing, say briefly in your reply why the findings didn't warrant changes.
- Do _not_ send that follow-up fix commit through another Codex review — the review cycle for a change ends after one round of findings and fixes. (Exception: the follow-up grew into something substantial beyond addressing the findings.)
- If you made several commits in a row, make sure the reviews cover all of them: either review each commit, or run one ranged review of the whole batch with `codex review --base <sha before your first commit>` plus the same `-c` options.

# Thank you for your hard work on this project

<3
