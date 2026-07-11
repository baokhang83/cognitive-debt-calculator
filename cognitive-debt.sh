#!/usr/bin/env bash
#
# cognitive-debt.sh — Measure a repository's "cognitive debt" as a trend over time.
#
# Three metric families, bucketed into time windows (weekly by default):
#   1. Context Deficit    — code churn vs documentation changes ("massive code, 0% docs").
#   2. Velocity Blindness — blast radius of unreviewed work + multi-file architectural mutations.
#   3. Code Churn         — AI-generated files that needed a bug-fix within N days.
#
# Output is JSON by default (a trend series); `--format md` renders the same data as Markdown.
# Analysis is 100% local git history — no GitHub API, no `gh` required.
#
# Usage:
#   ./cognitive-debt.sh [options] <max-commits> <target-repo>
#
#   <max-commits>  Max number of most-recent commits to consider.
#   <target-repo>  Local path, git URL, or owner/repo (cloned to a temp dir).
#
# Options:
#   --format json|md        Output format (default: json)
#   --window day|week|month Trend bucket size (default: week)
#   --code-threshold N      LOC that makes a commit a "feature" (default: 50)
#   --blast-threshold N     Files touched to count as high blast radius (default: 10)
#   --dir-threshold N       Distinct top-level dirs for an "architectural mutation" (default: 2)
#   --churn-days N          Window for AI file -> later fix (default: 7)
#   --ai-pattern REGEX      Extra AI attribution pattern (appended to defaults)
#   -h, --help              Show this help.

set -eu

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
FORMAT="json"
WINDOW="week"
CODE_TH=50
BLAST_TH=10
DIR_TH=2
CHURN_DAYS=7
AI_EXTRA=""
MAX=""
TARGET=""

AI_DEFAULT='claude|copilot|cursor|aider|chatgpt|devin|codeium|dependabot|renovate|bot'
TAB="$(printf '\t')"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --format)          FORMAT="${2:-}"; shift 2 ;;
    --format=*)        FORMAT="${1#*=}"; shift ;;
    --window)          WINDOW="${2:-}"; shift 2 ;;
    --window=*)        WINDOW="${1#*=}"; shift ;;
    --code-threshold)  CODE_TH="${2:-}"; shift 2 ;;
    --code-threshold=*) CODE_TH="${1#*=}"; shift ;;
    --blast-threshold) BLAST_TH="${2:-}"; shift 2 ;;
    --blast-threshold=*) BLAST_TH="${1#*=}"; shift ;;
    --dir-threshold)   DIR_TH="${2:-}"; shift 2 ;;
    --dir-threshold=*) DIR_TH="${1#*=}"; shift ;;
    --churn-days)      CHURN_DAYS="${2:-}"; shift 2 ;;
    --churn-days=*)    CHURN_DAYS="${1#*=}"; shift ;;
    --ai-pattern)      AI_EXTRA="${2:-}"; shift 2 ;;
    --ai-pattern=*)    AI_EXTRA="${1#*=}"; shift ;;
    -h|--help)         usage 0 ;;
    --)                shift; break ;;
    -*)                die "unknown option: $1 (see --help)" ;;
    *)                 break ;;
  esac
done

[ $# -ge 1 ] || die "missing <max-commits> and <target-repo> (see --help)"
[ $# -ge 2 ] || die "missing <target-repo> (see --help)"
MAX="$1"; TARGET="$2"

case "$FORMAT" in json|md) ;; *) die "--format must be json or md" ;; esac
case "$WINDOW" in day|week|month) ;; *) die "--window must be day, week or month" ;; esac
case "$MAX" in ''|*[!0-9]*) die "<max-commits> must be a positive integer" ;; esac
[ "$MAX" -gt 0 ] || die "<max-commits> must be > 0"

for tool in git awk jq sort; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

AIPAT="$AI_DEFAULT"
[ -n "$AI_EXTRA" ] && AIPAT="$AIPAT|$AI_EXTRA"

# ---------------------------------------------------------------------------
# Portable date -> period label
# ---------------------------------------------------------------------------
if date -r 0 +%Y >/dev/null 2>&1; then DATE_BSD=1; else DATE_BSD=0; fi

epoch_to_period() {
  local ts="$1" fmt
  case "$WINDOW" in
    day)   fmt='+%Y-%m-%d' ;;
    month) fmt='+%Y-%m' ;;
    *)     fmt='+%G-W%V' ;;
  esac
  if [ "$DATE_BSD" = 1 ]; then date -r "$ts" "$fmt"; else date -d "@$ts" "$fmt"; fi
}

# ---------------------------------------------------------------------------
# Working directory + repo resolution
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cogdebt.XXXXXX")"
CLONE=""
cleanup() {
  [ -n "$CLONE" ] && rm -rf "$CLONE" 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

resolve_repo() {
  if [ -d "$TARGET" ] && git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
    REPO="$TARGET"
    return
  fi
  local url="$TARGET"
  case "$TARGET" in
    *://*|git@*) url="$TARGET" ;;
    */*)
      # owner/repo shorthand
      if printf '%s' "$TARGET" | grep -Eq '^[^/[:space:]]+/[^/[:space:]]+$'; then
        url="https://github.com/$TARGET.git"
      else
        die "target is not a git repo and not a recognizable URL: $TARGET"
      fi
      ;;
    *) die "target is not a directory or git URL: $TARGET" ;;
  esac
  CLONE="$WORK/clone"
  printf 'cloning %s ...\n' "$url" >&2
  git clone --quiet --no-tags --depth "$((MAX + 10))" "$url" "$CLONE" \
    || die "git clone failed: $url"
  REPO="$CLONE"
}
resolve_repo

# ---------------------------------------------------------------------------
# Collect raw git data
# ---------------------------------------------------------------------------
git -C "$REPO" log -n "$MAX" --no-color \
  --pretty=tformat:'%H%x09%at%x09%an%x09%ae%x09%P%x09%(trailers:key=Co-authored-by,valueonly,separator=%x2C)%x09%s' \
  > "$WORK/meta.tsv" 2>/dev/null || die "could not read git history"

[ -s "$WORK/meta.tsv" ] || die "no commits found in target repository"

git -C "$REPO" log -n "$MAX" --no-color --numstat \
  --pretty=tformat:'@@%H' > "$WORK/numstat.txt" 2>/dev/null || true

# Per-commit period labels (one date call per commit).
: > "$WORK/periods.tsv"
while IFS="$TAB" read -r h at _rest; do
  [ -n "$h" ] || continue
  printf '%s\t%s\n' "$h" "$(epoch_to_period "$at")" >> "$WORK/periods.tsv"
done < "$WORK/meta.tsv"

: > "$WORK/touches.tsv"

# ---------------------------------------------------------------------------
# Stage A: per-commit reduction + emit AI/fix touches for churn
# ---------------------------------------------------------------------------
awk -F"$TAB" \
    -v metafile="$WORK/meta.tsv" -v perfile="$WORK/periods.tsv" \
    -v aipat="$AIPAT" -v codeth="$CODE_TH" -v blastth="$BLAST_TH" -v dirth="$DIR_TH" \
    -v touchfile="$WORK/touches.tsv" '
function classify(path,   low,base,lb){
  low=tolower(path)
  if(low ~ /(^|\/)docs?\//) return "doc"
  base=path; sub(/.*\//,"",base); lb=tolower(base)
  if(lb ~ /^readme/||lb ~ /^changelog/||lb ~ /^contributing/||lb ~ /^license/||lb ~ /^authors/||lb ~ /^notice/) return "doc"
  if(low ~ /\.(md|mdx|markdown|rst|txt|adoc|org)$/) return "doc"
  if(low ~ /\.(js|jsx|ts|tsx|mjs|cjs|py|go|rs|java|kt|kts|c|cc|cpp|cxx|h|hpp|hh|rb|php|sh|bash|zsh|swift|scala|cs|sql|vue|svelte|lua|pl|pm|r|dart|ex|exs|clj|cljs|erl|hs|m|mm)$/) return "code"
  return "other"
}
function aiflag(h,   hay){ if(h in _ai) return _ai[h]; hay=tolower(NAME[h] "\t" EMAIL[h] "\t" CO[h]); _ai[h]=(aipat!="" && hay ~ aipat)?1:0; return _ai[h] }
function fixflag(h,   s){ if(h in _fx) return _fx[h]; s=tolower(SUB[h]); _fx[h]=(s ~ /fix|bug|regress|revert|hotfix|patch/)?1:0; return _fx[h] }
function revflag(h,   np,a){ if(h in _rev) return _rev[h]; np=split(PAR[h],a," "); _rev[h]=((np>=2)||(SUB[h] ~ /Merge pull request/)||(SUB[h] ~ /\(#[0-9]+\)[ \t]*$/))?1:0; return _rev[h] }
FILENAME==metafile { h=$1; AT[h]=$2; NAME[h]=$3; EMAIL[h]=$4; PAR[h]=$5; CO[h]=$6; SUB[h]=$7; order[++oc]=h; next }
FILENAME==perfile  { PER[$1]=$2; next }
/^@@/ { cur=substr($0,3); next }
(cur!="" && NF>=3 && ($1 ~ /^[0-9-]+$/)) {
  add=$1; del=$2; p=$3
  if(add=="-") add=0; if(del=="-") del=0
  loc=add+del
  if(p ~ /\{.*=>.*\}/){ gsub(/\{[^={}]*=> /,"",p); gsub(/\}/,"",p) }
  else if(p ~ / => /){ sub(/.* => /,"",p) }
  cls=classify(p)
  if(cls=="doc") DOC[cur]+=loc; else if(cls=="code") CODE[cur]+=loc
  FILES[cur]++
  d=p; if(d ~ /\//) sub(/\/[^\/]*$/,"",d); else d="."
  dk=cur SUBSEP d; if(!(dk in dseen)){ dseen[dk]=1; DIRS[cur]++ }
  ai=aiflag(cur); fx=fixflag(cur)
  if(ai||fx) print AT[cur] "\t" p "\t" ai "\t" fx "\t" PER[cur] >> touchfile
}
END{
  for(i=1;i<=oc;i++){ h=order[i]
    code=CODE[h]+0; doc=DOC[h]+0; f=FILES[h]+0; dd=DIRS[h]+0
    rev=revflag(h); ai=aiflag(h); fx=fixflag(h)
    undoc=(code>=codeth && doc==0 && code>0)?1:0
    arch=(f>=blastth && dd>=dirth)?1:0
    sev=undoc*2+arch*2+(rev?0:1)+ai+f*0.001
    subj=SUB[h]; gsub(/\t/," ",subj)
    printf "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%.3f\t%s\n", PER[h],h,AT[h],code,doc,f,dd,rev,ai,fx,undoc,arch,sev,subj
  }
}
' "$WORK/meta.tsv" "$WORK/periods.tsv" "$WORK/numstat.txt" > "$WORK/commits.tsv"

# ---------------------------------------------------------------------------
# Stage B: churn cross-join (AI touch -> later fix on same file within window)
# ---------------------------------------------------------------------------
sort -t"$TAB" -k2,2 -k1,1n "$WORK/touches.tsv" | awk -F"$TAB" -v win="$((CHURN_DAYS * 86400))" '
{
  ts=$1; path=$2; ai=$3; fx=$4; per=$5
  if(path!=cur){ cur=path; pc=0; delete pts; delete pper; delete pu }
  if(fx=="1"){ for(j=1;j<=pc;j++){ if(!pu[j] && ts>pts[j] && (ts-pts[j])<=win){ pu[j]=1; REF[pper[j]]++ } } }
  if(ai=="1"){ pc++; pts[pc]=ts; pper[pc]=per; pu[pc]=0; TOU[per]++ }
}
END{ for(p in TOU) print p "\t" (TOU[p]+0) "\t" (REF[p]+0) }
' > "$WORK/churn.tsv"

# ---------------------------------------------------------------------------
# Stage C: per-window aggregation -> windows.tsv (sorted oldest->newest)
# ---------------------------------------------------------------------------
awk -F"$TAB" -v churnfile="$WORK/churn.tsv" '
FILENAME==churnfile { CT[$1]=$2; CR[$1]=$3; next }
{
  p=$1; code=$4; doc=$5; f=$6; rev=$8; ai=$9; undoc=$11; arch=$12
  C[p]++; CODE[p]+=code; DOC[p]+=doc
  if(doc==0) ZERO[p]+=code
  UNDOC[p]+=undoc
  FILES[p]+=f; if(rev=="0") UNREV[p]+=f
  ARCH[p]+=arch
  if(f>MAXB[p]) MAXB[p]=f
  if(ai=="1") AIC[p]++
  seen[p]=1
}
END{
  for(p in seen){
    code=CODE[p]+0; doc=DOC[p]+0; f=FILES[p]+0
    ratio=(code>0)?doc/code:0
    cs=(code>0)?ZERO[p]/code:0
    vs=(f>0)?UNREV[p]/f:0
    tou=CT[p]+0; ref=CR[p]+0
    crate=(tou>0)?ref/tou:0
    debt=100*(cs+vs+crate)/3
    printf "%s\t%d\t%d\t%d\t%.4f\t%d\t%.4f\t%d\t%d\t%d\t%d\t%.4f\t%d\t%d\t%d\t%.4f\t%.4f\t%.2f\n", \
      p,C[p],code,doc,ratio,UNDOC[p]+0,cs,f,UNREV[p]+0,ARCH[p]+0,MAXB[p]+0,vs,AIC[p]+0,tou,ref,crate,crate,debt
  }
}
' "$WORK/churn.tsv" "$WORK/commits.tsv" | sort -t"$TAB" -k1,1 > "$WORK/windows.tsv"

# Worst offenders (by severity, column 13).
sort -t"$TAB" -k13,13 -gr "$WORK/commits.tsv" | head -8 > "$WORK/worst.tsv"

analyzed="$(awk 'END{print NR}' "$WORK/commits.tsv")"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# Assemble JSON (jq handles all escaping)
# ---------------------------------------------------------------------------
jq -n \
  --arg repo "$TARGET" \
  --arg generated "$NOW" \
  --arg window "$WINDOW" \
  --argjson maxc "$MAX" \
  --argjson analyzed "$analyzed" \
  --argjson codeth "$CODE_TH" \
  --argjson blastth "$BLAST_TH" \
  --argjson dirth "$DIR_TH" \
  --argjson churndays "$CHURN_DAYS" \
  --arg aipat "$AIPAT" \
  --rawfile W "$WORK/windows.tsv" \
  --rawfile Cw "$WORK/worst.tsv" '
  def rows($s): ($s|rtrimstr("\n")) as $t | if ($t|length)==0 then [] else ($t|split("\n")|map(split("\t"))) end;
  def num: if .==null or .=="" then 0 else tonumber end;
  (rows($W) | map({
    period: .[0],
    commits: (.[1]|num),
    context_deficit:    { code_loc:(.[2]|num), doc_loc:(.[3]|num), doc_to_code_ratio:(.[4]|num), undocumented_features:(.[5]|num), score:(.[6]|num) },
    velocity_blindness: { files_touched:(.[7]|num), unreviewed_files:(.[8]|num), arch_mutations:(.[9]|num), max_blast_radius:(.[10]|num), score:(.[11]|num) },
    code_churn:         { ai_commits:(.[12]|num), ai_files_touched:(.[13]|num), ai_files_refixed:(.[14]|num), churn_rate:(.[15]|num), score:(.[16]|num) },
    cognitive_debt_score:(.[17]|num)
  })) as $windows |
  (rows($Cw) | map(select(length>=14)) | map({
    hash:(.[1][0:8]), period:.[0], subject:.[13],
    code_loc:(.[3]|num), doc_loc:(.[4]|num), files_touched:(.[5]|num),
    reviewed:(.[7]=="1"), ai_generated:(.[8]=="1"),
    undocumented:(.[10]=="1"), arch_mutation:(.[11]=="1"),
    severity:(.[12]|num)
  }) | map(select(.severity>0))) as $worst |
  ($windows|map(.commits)|add // 0) as $tc |
  (if $tc>0 then (($windows|map(.cognitive_debt_score*.commits)|add)/$tc) else 0 end) as $overall |
  (if ($windows|length)>=2 then
     ($windows[-1].cognitive_debt_score - $windows[0].cognitive_debt_score) as $d |
     (if $d>2 then "worsening" elif $d<-2 then "improving" else "stable" end)
   else "insufficient-data" end) as $trend |
  {
    repo:$repo, generated_at:$generated,
    params:{ max_commits:$maxc, window:$window, code_threshold:$codeth, blast_threshold:$blastth, dir_threshold:$dirth, churn_days:$churndays, ai_patterns:$aipat },
    commits_analyzed:$analyzed,
    heuristics:"reviewed = merge/PR-style commit (no GitHub API used); ai_generated = author/email/co-author trailer matches AI patterns.",
    windows:$windows,
    summary:{ cognitive_debt_score:(($overall*100|round)/100), trend:$trend, worst_commits:$worst }
  }
' > "$WORK/report.json"

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------
if [ "$FORMAT" = "json" ]; then
  cat "$WORK/report.json"
  exit 0
fi

# Markdown rendering from the same JSON.
jq -r '
  def bar(v): (["▁","▂","▃","▄","▅","▆","▇","█"]) as $b | $b[ ([ ([ ((v/100*7)|floor), 0 ]|max), 7 ]|min) ];
  "# Cognitive Debt Report",
  "",
  "**Repository:** \(.repo)  ",
  "**Generated:** \(.generated_at)  ",
  "**Commits analyzed:** \(.commits_analyzed) · **Window:** \(.params.window)  ",
  "",
  "## Summary",
  "",
  "- **Cognitive debt score:** \(.summary.cognitive_debt_score) / 100",
  "- **Trend:** \(.summary.trend)",
  "- **Debt sparkline:** \(reduce .windows[] as $w (""; . + bar($w.cognitive_debt_score)))",
  "",
  "## Trend by \(.params.window)",
  "",
  "Each score is 0–1 (higher = more debt). Debt is 0–100.",
  "",
  "| Period | Commits | Context | Velocity | Churn | Debt | Δ |",
  "|---|--:|--:|--:|--:|--:|:--:|",
  ( (.windows|to_entries) as $ws | $ws[] | .value as $w | .key as $i |
    ( if $i==0 then "–"
      else ($w.cognitive_debt_score - $ws[$i-1].value.cognitive_debt_score) as $d |
           (if $d>1 then "↑" elif $d<-1 then "↓" else "→" end)
      end ) as $arrow |
    "| \($w.period) | \($w.commits) | \($w.context_deficit.score) | \($w.velocity_blindness.score) | \($w.code_churn.score) | \($w.cognitive_debt_score) | \($arrow) |" ),
  "",
  "## Worst offenders",
  "",
  (if (.summary.worst_commits|length)==0 then "_None flagged._"
   else (.summary.worst_commits[] |
     "- `\(.hash)` **\(.subject)** — files: \(.files_touched), +/-code: \(.code_loc), +/-docs: \(.doc_loc)"
     + (if .undocumented then ", ⚠ undocumented" else "" end)
     + (if .arch_mutation then ", 🏗 arch-mutation" else "" end)
     + (if (.reviewed|not) then ", 👁 unreviewed" else "" end)
     + (if .ai_generated then ", 🤖 AI" else "" end))
   end),
  "",
  "## Metric definitions",
  "",
  "- **Context Deficit** — code LOC shipped with zero documentation changes in the same window.",
  "- **Velocity Blindness** — share of touched files that landed unreviewed, plus multi-file architectural mutations.",
  "- **Code Churn** — AI-generated files that required a later fix within \(.params.churn_days) days.",
  "",
  "> \(.heuristics)"
' "$WORK/report.json"
