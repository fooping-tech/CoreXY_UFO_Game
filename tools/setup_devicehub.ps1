# UFO-DeviceHub (the peripherals' hub: its PC client is a Python dependency of the backend, #159)
# as an ordinary git clone in external\UFO-DeviceHub. Not a submodule, never committed here.
# The same as tools/setup_devicehub.sh, for Windows.
#
#   .\tools\setup_devicehub.ps1            # no clone yet: clone it at the verified commit. Then uv sync
#   .\tools\setup_devicehub.ps1 -Pinned    # put the clone at the verified commit (the exhibit's PC)
#   .\tools\setup_devicehub.ps1 -Status    # where the clone is, against the verified commit
#   .\tools\setup_devicehub.ps1 -NoSync    # (with the above) do not run uv sync
#
# The verified commit is tools/devicehub.pin. A clone that is already there is left as it is
# unless -Pinned is given, and -Pinned refuses a clone with uncommitted changes: your work in it
# is never thrown away. Editing its Python needs no uv sync, only a restart of the backend.
param([switch]$Pinned, [switch]$Status, [switch]$NoSync)
# every git / uv call is checked by its exit code (Windows PowerShell 5.1 turns a native
# command's stderr into an error under 'Stop')
$ErrorActionPreference = 'Continue'

$ROOT = Split-Path -Parent $PSScriptRoot
# SETUP_DEVICEHUB_DIR / SETUP_DEVICEHUB_PIN: tests only (tools/test_setup_devicehub.sh)
$DIR = if ($env:SETUP_DEVICEHUB_DIR) { $env:SETUP_DEVICEHUB_DIR } else { Join-Path (Join-Path $ROOT 'external') 'UFO-DeviceHub' }
$PIN_FILE = if ($env:SETUP_DEVICEHUB_PIN) { $env:SETUP_DEVICEHUB_PIN } else { Join-Path $PSScriptRoot 'devicehub.pin' }

function Write-Err([string]$msg) { [Console]::Error.WriteLine($msg) }
function Fail([string]$msg) { Write-Err $msg; exit 1 }
function Get-Pin([string]$key) {
  foreach ($line in Get-Content -Encoding UTF8 $PIN_FILE) {
    if ($line.StartsWith("$key=")) { return $line.Substring($key.Length + 1).Trim() }
  }
  return ''
}

# CXUFO_DEVICEHUB_URL: another place to clone from (a local clone, for a PC without the network)
$REPO = if ($env:CXUFO_DEVICEHUB_URL) { $env:CXUFO_DEVICEHUB_URL } else { Get-Pin 'repo' }
$COMMIT = Get-Pin 'commit'
if (-not $REPO -or $COMMIT -notmatch '^[0-9a-f]{40}$') { Fail 'tools/devicehub.pin を読めない（repo= と 40 桁の commit= が必要）' }
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { Fail 'git が見つかりません: winget install Git.Git' }

function Test-Clone { return (Test-Path (Join-Path $DIR '.git')) }
function Get-Head { return ((& git -C $DIR rev-parse HEAD 2>$null) | Select-Object -First 1) }
function Test-Dirty { return [bool](& git -C $DIR status --porcelain 2>$null) }
function Test-Commit { & git -C $DIR cat-file -e "$COMMIT^{commit}" 2>$null; return ($LASTEXITCODE -eq 0) }

function Show-Report {
  if (-not (Test-Clone)) { Write-Output "UFO-DeviceHub: まだ clone していない（${DIR}）"; return }
  $head = Get-Head
  $short = $COMMIT.Substring(0, 7)
  if ($head -eq $COMMIT) {
    $more = if (Test-Dirty) { '（未コミットの変更あり）' } else { '' }
    Write-Output "UFO-DeviceHub: 確認済みのコミット $short です$more"
  } else {
    $branch = (& git -C $DIR rev-parse --abbrev-ref HEAD) | Select-Object -First 1
    $more = if (Test-Dirty) { '。未コミットの変更あり' } else { '' }
    Write-Output "UFO-DeviceHub: $($head.Substring(0, 7))（$branch）。確認済みのコミットは $short$more"
    Write-Output '  確認済みのコミットに合わせる: .\tools\setup_devicehub.ps1 -Pinned'
  }
}

if ($Status) {
  Show-Report
  exit ([int](-not (Test-Clone)))
}

if (-not (Test-Clone)) {
  if ((Test-Path $DIR) -and (Get-ChildItem -Force $DIR | Select-Object -First 1)) {
    Fail "$DIR があるが git の clone ではない。中身を確かめて、どかしてからやり直してください"
  }
  New-Item -ItemType Directory -Force -Path (Join-Path $ROOT 'external') | Out-Null
  Write-Output "UFO-DeviceHub を clone します: $REPO -> external\UFO-DeviceHub"
  & git clone --quiet $REPO $DIR
  if ($LASTEXITCODE -ne 0) { Fail 'clone に失敗しました（ネットワークと URL を確かめる）' }
  $Pinned = $true  # a new clone starts at the commit this game is verified with
}

if ($Pinned -and (Get-Head) -ne $COMMIT) {
  if (Test-Dirty) {
    Write-Err 'external\UFO-DeviceHub に未コミットの変更があるので、コミットを切り替えません。'
    Fail '  変更をコミットするか退避してから、もう一度 -Pinned を実行してください'
  }
  if (-not (Test-Commit)) {
    & git -C $DIR fetch --quiet origin
    if ($LASTEXITCODE -ne 0) { Fail 'fetch に失敗しました（ネットワークを確かめる）' }
  }
  if (-not (Test-Commit)) { & git -C $DIR fetch --quiet origin $COMMIT 2>$null }
  & git -C $DIR checkout --quiet --detach $COMMIT
  if ($LASTEXITCODE -ne 0) { Fail "コミット $COMMIT が見つかりません（tools/devicehub.pin を確かめる）" }
  Write-Output '  開発を続けるときは: git -C external\UFO-DeviceHub switch main（または作業ブランチ）'
}
Show-Report

if (-not (Test-Path (Join-Path $DIR 'pyproject.toml'))) {
  Fail 'external\UFO-DeviceHub に pyproject.toml がない（古いコミット）。.\tools\setup_devicehub.ps1 -Pinned で確認済みのコミットにする'
}

if (-not $NoSync) {
  if (-not (Get-Command uv -CommandType Application -ErrorAction SilentlyContinue)) { Fail 'uv が見つかりません: winget install astral-sh.uv' }
  $env:VIRTUAL_ENV = $null
  Push-Location (Join-Path $ROOT 'backend')
  try {
    # --inexact: the extras start.ps1 installed (camera, hand tracking) stay
    & uv sync --quiet --inexact
    if ($LASTEXITCODE -ne 0) { Fail 'uv sync に失敗しました' }
  } finally {
    Pop-Location
  }
  Write-Output 'backend: uv sync 済み（UFO-DeviceHub は editable。Python の編集はバックエンドの再起動で反映）'
}
