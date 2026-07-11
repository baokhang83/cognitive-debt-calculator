# cognitive-debt-calculator

📊 Measure your repository's comprehension deficit. Calculate documentation-to-code ratios for AI-assisted codebases.

`cognitive-debt.sh` analyzes a repository's git history and reports **cognitive debt** — the gap
between how fast code is shipped and how well it's documented, reviewed, and stabilized — as a
**trend over time** (weekly windows by default), so you can see whether debt is accumulating or
being paid down.

It runs entirely on **local git history**: no GitHub API, no `gh`, no auth, no rate limits.

## Metrics

1. **Context Deficit** — code churn vs documentation changes. Flags "massive code, 0% docs"
   features (score = code LOC shipped with zero doc changes ÷ total code LOC in the window).
2. **Velocity Blindness** — blast radius of unreviewed work plus multi-file architectural
   mutations in a single commit (score = unreviewed files touched ÷ total files touched).
3. **Code Churn** — AI-generated files that needed a later fix within N days
   (score = AI files re-fixed ÷ AI files touched).

Each window also gets a combined **cognitive debt score** (0–100, higher = more debt), the mean
of the three metric scores.

## Usage

```bash
./cognitive-debt.sh [options] <max-commits> <target-repo>
```

- `<max-commits>` — max number of most-recent commits to consider.
- `<target-repo>` — a local path, a git URL, or `owner/repo` (cloned to a temp dir, auto-removed).

### Options

| Option | Default | Description |
|---|---|---|
| `--format json\|md`        | `json` | Output format. `md` renders the same data as a Markdown report. |
| `--window day\|week\|month`| `week` | Trend bucket size. |
| `--code-threshold N`       | `50`   | LOC that makes a commit a "feature" for Context Deficit. |
| `--blast-threshold N`      | `10`   | Files touched to count as high blast radius. |
| `--dir-threshold N`        | `2`    | Distinct directories for an "architectural mutation". |
| `--churn-days N`           | `7`    | Window for an AI-touched file to be re-fixed. |
| `--ai-pattern REGEX`       | —      | Extra AI attribution pattern, appended to the defaults. |
| `-h`, `--help`             |        | Show help. |

### Examples

```bash
# Trend of the last 200 commits of a local repo, as JSON
./cognitive-debt.sh 200 .

# Monthly Markdown report for a remote repo
./cognitive-debt.sh --format md --window month 500 owner/repo > report.md

# Feed the JSON into other tooling
./cognitive-debt.sh 300 https://github.com/owner/repo.git | jq '.summary'
```

## Output

JSON contains `params`, `commits_analyzed`, a `windows[]` trend series (oldest → newest), and a
`summary` with the overall score, trend direction, and worst-offending commits. `--format md`
renders a summary, a debt sparkline, a per-window trend table with ↑/↓/→ indicators, and a
worst-offenders list.

## How signals are derived (heuristics)

Because analysis is local-only, two signals are heuristic:

- **reviewed** — a commit is treated as reviewed if it's a merge commit or a PR/squash-style
  commit (`Merge pull request …`, or a subject ending in `(#123)`). Everything else is
  "unreviewed".
- **ai_generated** — a commit is attributed to AI if its author name/email or a
  `Co-Authored-By` trailer matches known AI tools
  (`claude`, `copilot`, `cursor`, `aider`, `chatgpt`, `devin`, `codeium`, `dependabot`,
  `renovate`, `bot`; extend with `--ai-pattern`).

## Requirements

`git`, `jq`, `awk`, and `sort`. Portable to macOS (bash 3.2, BSD date) and Linux (GNU date).
