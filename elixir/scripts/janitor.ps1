# SUPERSEDED by `mix janitor` (lib/symphony_elixir/janitor*.ex).
#
# Kept in the tree because it is the measured record: the comments below name eleven Windows
# PowerShell 5.1 traps that cost real time, and none of them are obvious from reading the code
# (BOM-vs-ANSI script decoding, the static Regex.Replace overload with no count, multi-line argv
# splitting, console-codepage stdout decoding, $_ shadowing, pipe truncation, catastrophic regex
# backtracking, and a native call that hung a whole round for 62 minutes).
#
# If you need the janitor today, use `mix janitor`. Use this file only to read the history.<#
  symphony janitor -- the host-side caretaker. Five things, every 30 seconds:

    1 receive     a new GitHub issue (labelled agent-task) becomes a ticket
    2 mirror      ticket <-> issue: state as a plain-language label, comments into the ticket,
                  assignee into the ticket; closing the issue means the ticket is done
    3 boards      README.md (table + counts) and BOARD-<state>.md (one view per state)
    4 sync        commit local ticket changes -> pull --rebase --autostash -> push
    5 publish     ticket in-review and (workspace dirty OR the branch has no PR) -> commit,
                  push a branch, open a PR, and comment the PR link back onto the issue

  Why it has to exist (measured, do not remove):
    * codex's workspaceWrite sandbox makes .git/ read-only and gh cannot read its own config,
      so **the agent cannot commit, push or open a PR**. Publishing is the host's job.
    * the run task does not trap exits and reconcile kills it from the outside with
      Process.exit(pid, :shutdown), so `hooks.after_run` never runs on the path that matters.

  Design note for people who do not know git: **the issue is the only surface**. The ticket files
  (git, YAML front matter, the state vocabulary) are implementation detail on this machine.
  A person only ever: opens an issue, fills in one box, waits for a comment, presses Close.

  Usage:
      .\symphony-janitor.ps1              # resident loop
      .\symphony-janitor.ps1 -Once        # one round (debugging)
      .\symphony-janitor.ps1 -SkipMirror  # do not talk to GitHub

  ENCODING -- two rules that pull in opposite directions; both are forced by the reader:
    * ticket files must be UTF-8 WITHOUT a BOM. With a BOM the front-matter regex (\A---) fails
      and the ticket **silently disappears** -- the failure mode this project fears most.
    * this script must be UTF-8 WITH a BOM. Windows PowerShell 5.1 decodes a BOM-less .ps1 as
      ANSI, which shreds the non-ASCII comments and the whole script fails to parse.
    * always read/write tickets with [System.IO.File] and an explicit UTF8 encoding.
      Get-Content/Set-Content defaults mangle non-ASCII and add a BOM.
#>
[CmdletBinding()]
param(
  [string]$Tickets = (Join-Path $env:USERPROFILE 'code\symphony-tickets'),
  [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE 'code\symphony-file-workspaces'),
  [string]$Repo = 'lanhaolong20161111/beekeeper',
  [string]$TicketsRepo = 'lanhaolong20161111/beekeeper-tickets',
  [string]$StateFile = (Join-Path $env:USERPROFILE 'code\symphony-janitor-state.json'),
  [string]$Log = (Join-Path $env:TEMP 'tickets-sync.log'),
  [int]$IntervalSeconds = 30,
  [int]$RoundTimeoutSeconds = 240,
  [switch]$Once,
  [switch]$SkipMirror
)

# Windows PowerShell 5.1 decodes a native command's stdout with the CONSOLE codepage (GBK here)
# while gh emits UTF-8, so every non-ASCII title/comment came back as mojibake (measured:
# "杩欐潯璇勮..."). Set both directions to UTF-8 before shelling out.
try {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }

$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)

# internal state (the ticket's `state:`) <-> the label a person actually reads
$friendly = [ordered]@{
  'ready'       = '等 agent 做'
  'in-progress' = '正在做'
  'in-review'   = '等你看'
  'paused'      = '暂停'
  'done'        = '已完成'
  'cancelled'   = '已取消'
}
$toInternal = @{}
foreach ($k in $friendly.Keys) { $toInternal[$friendly[$k]] = $k }

# board view order = the order a person cares about; "waiting for you" first
$views = @(
  @{ s = 'in-review';   t = 'Waiting on you' },
  @{ s = 'in-progress'; t = 'Agent working' },
  @{ s = 'ready';       t = 'Queued' },
  @{ s = 'paused';      t = 'Paused' },
  @{ s = 'done';        t = 'Done' },
  @{ s = 'cancelled';   t = 'Cancelled' }
)
$rowsort = @{ 'in-review' = 0; 'in-progress' = 1; 'ready' = 2; 'paused' = 3; 'done' = 8; 'cancelled' = 9 }

function Write-Log([string]$m) {
  "$(Get-Date -Format 'HH:mm:ss') $m" | Add-Content -LiteralPath $Log -Encoding UTF8
}

function Read-Utf8([string]$p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function Write-Utf8([string]$p, [string]$c) { [System.IO.File]::WriteAllText($p, $c, $utf8) }

# GitHub labels must EXIST before they can be attached, and attaching a missing one fails the
# whole `gh issue create` (measured: "could not add label: 'state:in-review' not found").
function Initialize-Labels {
  gh label create 'agent-task' --repo $Repo --color '0E8A16' --description 'task for the agent' 2>&1 | Out-Null
  gh label create 'symphony' --repo $Repo --color '5319E7' --description 'managed by symphony' 2>&1 | Out-Null
  foreach ($k in $friendly.Keys) {
    gh label create $friendly[$k] --repo $Repo --color 'C2E0C6' --description 'symphony state' 2>&1 | Out-Null
  }
}

function Get-Fm([string]$fm, [string]$key) {
  if ($fm -match "(?m)^\s*$key\s*:\s*(.+?)\s*$") { return $Matches[1].Trim().Trim('"').Trim("'") }
  return ''
}

function Split-Ticket([string]$txt) {
  if ($txt -match '(?s)\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n?(.*)\z') {
    return @{ fm = $Matches[1]; body = $Matches[2] }
  }
  return $null
}

# Set or add a front-matter key.
#
# !!! Two traps, both measured:
#  1. Insert AFTER the opening `---`. Inserting before it means the file no longer starts with
#     `---`, so the tracker's \A--- fails and the ticket silently disappears.
#  2. Use the INSTANCE form ([regex]$p).Replace($s, $r, 1). The static
#     [regex]::Replace($s, $p, $r, 1) has NO count overload: that trailing 1 becomes
#     RegexOptions (1 = IgnoreCase) and EVERY match is replaced -- which once put a second
#     `issue:` line into a ticket's body.
function Set-FmKey([string]$txt, [string]$key, [string]$value) {
  $esc = [regex]::Escape($key)
  if ($txt -match "(?m)^\s*$esc\s*:") {
    return ([regex]("(?m)^\s*$esc\s*:.*$")).Replace($txt, "$key`: $value", 1)
  }
  return ([regex]('(?m)^---\s*$')).Replace($txt, "---`n$key`: $value", 1)
}

function Read-State {
  if (Test-Path -LiteralPath $StateFile) {
    try { return (Read-Utf8 $StateFile | ConvertFrom-Json) } catch { }
  }
  return [pscustomobject]@{}
}
function Write-State($obj) { Write-Utf8 $StateFile ($obj | ConvertTo-Json -Depth 6) }

function Get-Tickets {
  $rows = @()
  foreach ($f in (Get-ChildItem -LiteralPath $Tickets -Filter '*.md' -File |
                  Where-Object { $_.Name -notlike 'BOARD-*' -and $_.Name -ne 'README.md' })) {
    $txt = Read-Utf8 $f.FullName
    $parts = Split-Ticket $txt
    if (-not $parts) { continue }                      # no front matter => not a ticket
    $id = Get-Fm $parts.fm 'id'; if (-not $id) { $id = [IO.Path]::GetFileNameWithoutExtension($f.Name) }
    $st = Get-Fm $parts.fm 'state'; if (-not $st) { $st = 'open' }
    $pr = Get-Fm $parts.fm 'priority'
    $rows += [pscustomobject]@{
      file = $f.FullName; id = $id; st = $st; pr = $pr
      ti = (Get-Fm $parts.fm 'title')
      dep = ((Get-Fm $parts.fm 'blocked_by') -replace '[\[\]]', '')
      asg = (Get-Fm $parts.fm 'assignee_id')
      issue = (Get-Fm $parts.fm 'issue')
      body = $parts.body
      t = $f.LastWriteTime.ToString('MM-dd HH:mm')
      p = $(if ($pr -match '^\d+$') { [int]$pr } else { 999 })
    }
  }
  return $rows
}

# 1. Receive: a newly opened issue becomes a ticket.
# This is the entry point for someone who does not know git. They fill one box: what to do.
# "How to tell it is done" is optional -- when it is given it becomes the ticket's `## Validation`
# section, and when it is left blank the agent derives a check itself (see the workflow prompt).
function Receive-Issues($rows) {
  $open = gh issue list --repo $Repo --label 'agent-task' --state open --json number,title,body --limit 50 2>$null
  if (-not $open) { return }
  foreach ($i in ($open | ConvertFrom-Json)) {
    $num = "$($i.number)"
    if ($rows | Where-Object { $_.issue -eq $num }) { continue }   # a ticket already points at it

    $id = "SYM-$num"                    # the issue number IS the ticket number: deterministic
    $body = [string]$i.body
    $what = ''
    $done = ''
    # GitHub renders form answers as "### <label>\n<answer>"
    foreach ($pair in @(@('要做什么', 'what'), @('怎么算做完了', 'done'))) {
      $label = $pair[0]
      if ($body -match ("(?s)###\s*" + [regex]::Escape($label) + "\s*\r?\n(.*?)(?=\r?\n###|\z)")) {
        if ($pair[1] -eq 'what') { $what = $Matches[1].Trim() } else { $done = $Matches[1].Trim() }
      }
    }
    if (-not $what) { $what = $body.Trim() }                        # not filled via the form

    $ticket = "---`nid: $id`nissue: $num`ntitle: ""$($i.title -replace '"', '\"')""`nstate: ready`n---`n`n$what`n"
    if ($done -and $done -ne '_No response_' -and $done -ne 'No response') {
      $ticket += "`n## Validation`n`n$done`n"
    }
    Write-Utf8 (Join-Path $Tickets "$id.md") $ticket
    Write-Log "[$id] ticket created from issue #$num"
  }
}

# 2. Mirror: ticket <-> issue.
function Sync-Issues($rows, $state) {
  foreach ($r in $rows) {
    try {
      $key = $r.id
      # @(...) -contains, NOT .Name.Contains(): with a single property .Name is a STRING and
      # String.Contains does substring matching, which silently misjudges.
      if (-not (@($state.PSObject.Properties.Name) -contains $key)) {
        $state | Add-Member -NotePropertyName $key -NotePropertyValue ([pscustomobject]@{ label = ''; comment = 0 }) -Force
      }
      $sv = $state.$key

      if (-not $r.issue) {
        # A ticket with no issue (created by hand): give it one, and record the number in the
        # ticket so the link is stable in both directions without title searching.
        #
        # Must use --body-file: Windows PowerShell 5.1 splits a multi-line argument to a native
        # command on whitespace, so gh saw fragments of the body as flags (measured:
        # "unknown flag: --> README.md` exits 0"). Backticks in the body were also eaten as
        # PowerShell escapes.
        $tmpBody = Join-Path $env:TEMP "symphony-issue-body-$($r.id).md"
        Write-Utf8 $tmpBody ("Ticket file: https://github.com/$TicketsRepo/blob/master/$($r.id).md`n`n" + $r.body)
        $out = gh issue create --repo $Repo --title ([string]::Format("[{0}] {1}", $r.id, $r.ti)) `
          --body-file $tmpBody --label 'symphony' --label $friendly[$r.st] 2>&1
        Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue
        if ($out -match '/issues/(\d+)') {
          $n = $Matches[1]
          Write-Utf8 $r.file (Set-FmKey (Read-Utf8 $r.file) 'issue' $n)
          $sv.label = $friendly[$r.st]; $sv.comment = 0
          Write-Log "[$($r.id)] issue #$n created"
        } else {
          Write-Log "[$($r.id)] issue create failed: $($out -join ' ')"
        }
        continue
      }

      $j = (gh issue view $r.issue --repo $Repo --json state,labels,assignees,comments 2>$null) | ConvertFrom-Json
      if (-not $j) { continue }

      $names = @($j.labels | ForEach-Object { $_.name })

      # human write surface 1: closing the issue means this ticket is done
      if ($j.state -eq 'CLOSED' -and $r.st -notin @('done', 'cancelled')) {
        Write-Utf8 $r.file (Set-FmKey (Read-Utf8 $r.file) 'state' 'done')
        Write-Log "[$($r.id)] state <- issue closed: done"
        $r.st = 'done'
        $sv.label = $friendly['done']
      }

      # human write surface 2: a state label
      # The test is "the label is not the one we last wrote", otherwise the two sides overwrite
      # each other every 30 seconds.
      $lbl = $names | Where-Object { $toInternal.ContainsKey($_) } | Select-Object -First 1
      if ($j.state -ne 'CLOSED' -and $lbl -and $lbl -ne $sv.label) {
        $internal = $toInternal[$lbl]
        if ($internal -ne $r.st) {
          Write-Utf8 $r.file (Set-FmKey (Read-Utf8 $r.file) 'state' $internal)
          Write-Log "[$($r.id)] state <- issue label: $internal ($lbl)"
          $r.st = $internal
        }
        $sv.label = $lbl
      }

      # human write surface 3: assignee
      $asg = ($j.assignees | Select-Object -First 1).login
      if ($asg -and $asg -ne $r.asg) {
        Write-Utf8 $r.file (Set-FmKey (Read-Utf8 $r.file) 'assignee_id' $asg)
        Write-Log "[$($r.id)] assignee_id <- issue: $asg"
      }

      # human write surface 4: comment threads, appended to the ticket so the agent sees them
      # Comment ids are 64-bit (measured 5845913451 > Int32 max) so they must be [long].
      $new = @($j.comments | Where-Object { $_.url -and ([long]($_.url -replace '.*#issuecomment-', '')) -gt [long]$sv.comment })
      if ($new.Count -gt 0) {
        $txt = Read-Utf8 $r.file
        $block = ($new | ForEach-Object {
          $who = if ($_.author.login) { $_.author.login } else { 'unknown' }
          "- **$who** ($($_.createdAt)): " + (($_.body -replace "`r?`n", ' ').Trim())
        }) -join "`n"
        if ($txt -notmatch '(?m)^## Discussion') { $txt = $txt.TrimEnd() + "`n`n## Discussion`n" }
        Write-Utf8 $r.file ($txt.TrimEnd() + "`n" + $block + "`n")
        $sv.comment = [long](($new | ForEach-Object { [long]($_.url -replace '.*#issuecomment-', '') } | Measure-Object -Maximum).Maximum)
        Write-Log "[$($r.id)] +$($new.Count) comment(s) appended to ticket"
      }

      # ticket -> issue: keep the state label in step (the ticket file is the single source)
      $want = $friendly[$r.st]
      if ($want -and $lbl -ne $want) {
        gh issue edit $r.issue --repo $Repo --add-label $want 2>&1 | Out-Null
        foreach ($n in ($names | Where-Object { $toInternal.ContainsKey($_) -and $_ -ne $want })) {
          gh issue edit $r.issue --repo $Repo --remove-label $n 2>&1 | Out-Null
        }
        $sv.label = $want
      }
    } catch {
      Write-Log "[$($r.id)] mirror error: $($_.Exception.Message)"
    }
  }
  Write-State $state
}

# 3. Boards.
function Write-Boards($rows) {
  $hdr = "| Ticket | Title | State | Pri | Assignee | Blocked by | Updated |`n|---|---|---|---|---|---|---|"
  $byState = @{}
  foreach ($v in $views) { $sv2 = $v.s; $byState[$sv2] = @($rows | Where-Object { $_.st -eq $sv2 }) }

  $line = {
    param($x)
    "| [{0}]({0}.md) | {1} | ``{2}`` | {3} | {4} | {5} | {6} |" -f $x.id, $x.ti, $x.st, $x.pr, $x.asg, $x.dep, $x.t
  }
  $all = ($rows | Sort-Object @{e = { if ($rowsort.ContainsKey($_.st)) { $rowsort[$_.st] } else { 7 } } }, p, id |
          ForEach-Object { & $line $_ }) -join "`n"
  $links = ($views | ForEach-Object { "[{0} ({1})](BOARD-{0}.md)" -f $_.s, $byState[$_.s].Count }) -join ' - '

  Write-Utf8 (Join-Path $Tickets 'README.md') @"
# Tickets

**Views:** [all ($($rows.Count))](README.md) - $links

> Auto-generated every $IntervalSeconds seconds by the host janitor; do not edit these boards.
> **You never need to touch these files.** To ask for work, open an issue at
> https://github.com/$Repo/issues -- there is a fill-in-the-blank form. Everything here is the
> mechanical half: the issue is what a person owns, and the ``state`` above mirrors its label.

$hdr
$all
"@

  foreach ($v in $views) {
    $sv2 = $v.s
    $sel = $byState[$sv2]
    $shown = if ($sv2 -in @('done', 'cancelled')) { @($sel | Select-Object -First 20) } else { $sel }
    $b = ($shown | ForEach-Object { & $line $_ }) -join "`n"
    if (-not $b) { $b = '| _none_ | | | | | | |' }
    $note = if ($sel.Count -gt $shown.Count) { "`n_Showing the 20 most recent of $($sel.Count)._`n" } else { '' }
    Write-Utf8 (Join-Path $Tickets "BOARD-$sv2.md") @"
# $($v.t) -- ``$sv2`` ($($sel.Count))

[<- all views](README.md)
$note
$hdr
$b
"@
  }
}

# 4. Ticket repo sync.
function Sync-TicketsRepo {
  Push-Location $Tickets
  git add -A 2>&1 | Out-Null
  $staged = git diff --cached --name-only
  if ($staged) {
    git commit -q -m "tickets: sync ($($staged -join ', '))" 2>&1 | Out-Null
    Write-Log "committed: $($staged -join ', ')"
  }
  git pull --rebase --autostash 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { git rebase --abort 2>&1 | Out-Null }
  git push 2>&1 | Out-Null
  Pop-Location
}

# 5. Publish sweep.
# Criterion: the ticket is in-review AND (the workspace is dirty OR the branch has no PR yet).
# The second half is not redundant: when the push succeeds and `gh pr create` fails, the
# workspace is already clean, so a dirty-only trigger would never retry.
function Publish-Sweep {
  foreach ($d in (Get-ChildItem -LiteralPath $WorkspaceRoot -Directory -ErrorAction SilentlyContinue)) {
    $id = $d.Name; $ws = $d.FullName
    if (-not (Test-Path (Join-Path $ws '.git'))) { continue }
    $tf = Join-Path $Tickets "$id.md"
    if (-not (Test-Path -LiteralPath $tf)) { continue }
    $ticketText = Read-Utf8 $tf
    if ($ticketText -notmatch '(?m)^state:\s*in-review\s*$') { continue }

    $branch = "symphony/$id"
    $dirty = git -C $ws status --porcelain
    $hasPr = (gh pr list --repo $Repo --head $branch --state all --json number 2>$null) -match '"number"'
    if (-not $dirty -and $hasPr) { continue }

    Push-Location $ws
    if ($dirty) {
      git checkout -B $branch 2>&1 | Out-Null
      git add -A 2>&1 | Out-Null
      git -c user.name=symphony -c user.email=symphony@local commit -q -m "symphony/${id}: automated change" 2>&1 | Out-Null
      Write-Log "[$id] committed on $branch"
    }
    if (-not ((git ls-remote --heads origin $branch 2>&1) -match [regex]::Escape($branch))) {
      git push -u origin $branch 2>&1 | Out-Null
      Write-Log "[$id] push exit=$LASTEXITCODE"
    }
    if (-not $hasPr) {
      # gh must run with the WORKSPACE as cwd: --fill would run `git log main...branch` and the
      # janitor's cwd is the tickets repo, which has neither. Explicit title/body removes the
      # dependency on git context entirely.
      $url = gh pr create --repo $Repo --head $branch --base main --label symphony `
        --title "symphony/${id}: automated change" `
        --body "Automated by symphony for ticket ${id}.`n`nSee the ticket: https://github.com/$TicketsRepo/blob/master/${id}.md" 2>&1
      Write-Log "[$id] pr: $($url -join ' ')"
      # Comment the PR link back onto the issue: this is what lets a person follow progress
      # without ever leaving the issue.
      if ($url -match 'https://\S+/pull/\d+') {
        $prUrl = $Matches[0]
        $issueNum = if ($ticketText -match '(?m)^issue:\s*(\d+)') { $Matches[1] } else { '' }
        if ($issueNum) {
          gh issue comment $issueNum --repo $Repo --body "干完了，改动在这里：$prUrl" 2>&1 | Out-Null
          Write-Log "[$id] pr link posted to issue #$issueNum"
        }
      }
    }
    Pop-Location
  }
}

function Invoke-Round {
  $state = Read-State
  $rows = Get-Tickets

  if (-not $SkipMirror) {
    Receive-Issues $rows
    $rows = Get-Tickets                     # pick up tickets created this round
    Sync-Issues $rows $state
    $rows = Get-Tickets                     # the mirror may have changed state/assignee
  }

  Write-Boards $rows
  Sync-TicketsRepo
  Publish-Sweep
}

Initialize-Labels
Write-Log "janitor started (receive+mirror+board+sync+publish)"
if ($Once) {
  try { Invoke-Round } catch { Write-Log "round error: $($_.Exception.Message)" }
} else {
  # Every round runs in a CHILD process with a watchdog.
  #
  # Measured 2026-09-26: a round hung for 62 minutes with no gh/git child left alive and the CPU
  # flat. That is the classic shape of a native command whose process exited but whose stdout pipe
  # stayed open -- PowerShell then waits forever. Fixing each call site is whack-a-mole; a watchdog
  # contains any such hang to one round and lets the loop carry on.
  while ($true) {
    $round = Start-Job -ScriptBlock { param($s) & $s -Once } -ArgumentList $PSCommandPath

    if (Wait-Job $round -Timeout $RoundTimeoutSeconds) {
      Receive-Job $round 2>&1 | Out-Null
    } else {
      Write-Log "round TIMED OUT after ${RoundTimeoutSeconds}s -> killed (a native call hung)"
      Stop-Job $round -ErrorAction SilentlyContinue
    }

    Remove-Job $round -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds $IntervalSeconds
  }
}
