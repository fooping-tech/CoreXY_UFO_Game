# Self-test for start.ps1 (Windows), the same cases as tools/test_start_sh.sh: the option form,
# the earlier mode names and the default (CXUFO_START_MODE / CXUFO_START_ARGS, env or .env).
# START_SH_DRY_RUN=1 prints the commands: no Godot, no backend, no ports, no serial.
# Runs under the PowerShell that runs it (pwsh, or Windows PowerShell 5.1):
#   pwsh -NoProfile -File tools/test_start_ps1.ps1
$ErrorActionPreference = 'Continue'

$ROOT = Split-Path -Parent $PSScriptRoot
$START = Join-Path $ROOT 'start.ps1'
$GAME = Join-Path $ROOT 'game'
$PS = (Get-Process -Id $PID).Path
$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ("test_start_ps1_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TMP | Out-Null
$DOTENV = Join-Path $TMP '.env'
$script:fails = 0
$script:OUT = ''
$script:CODE = 0

# Run @{ENV = value} start.ps1-args...: output in $OUT, exit code in $CODE
function Run([hashtable]$envs, [string[]]$a = @(), [switch]$Command) {
  $set = @{ START_SH_DRY_RUN = '1'; START_SH_ENV_FILE = $DOTENV; CXUFO_START_MODE = $null; CXUFO_START_ARGS = $null; START_SH_CONFIG = $null }
  foreach ($k in $envs.Keys) { $set[$k] = $envs[$k] }
  $saved = @{}
  foreach ($k in $set.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
    [Environment]::SetEnvironmentVariable($k, $set[$k])
  }
  try {
    if ($Command) {  # typed at a prompt: PowerShell itself parses the arguments
      $lines = & $PS -NoProfile -ExecutionPolicy Bypass -Command "& '$START' $($a -join ' ')" 2>&1
    } else {
      $lines = & $PS -NoProfile -ExecutionPolicy Bypass -File $START @a 2>&1
    }
    $script:CODE = $LASTEXITCODE
    $script:OUT = (@($lines | ForEach-Object { "$_" }) -join "`n")
  } finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
}
function Check([string]$name, [bool]$ok) {
  if ($ok) { Write-Output "PASS  $name" } else {
    Write-Output "FAIL  $name"
    ($script:OUT -split "`n") | ForEach-Object { Write-Output "      $_" }
    $script:fails++
  }
}
function Has([string]$s) { return $script:OUT.Contains($s) }
function Line([string]$s) { return (($script:OUT -split "`n") -contains $s) }  # a whole output line
function Set-DotEnv([string[]]$lines) { [System.IO.File]::WriteAllLines($DOTENV, $lines) }

try {
  # configs for the Study tab's second switch (#92)
  $cfgText = Get-Content -Raw -Encoding UTF8 (Join-Path $ROOT 'config/game_config.json')
  $studyRe = '("study"\s*:\s*\{\s*"enabled"\s*:\s*)(true|false)'
  $studyOff = Join-Path $TMP 'study_off.json'; $studyOn = Join-Path $TMP 'study_on.json'
  [System.IO.File]::WriteAllText($studyOff, ($cfgText -replace $studyRe, '${1}false'))
  [System.IO.File]::WriteAllText($studyOn, ($cfgText -replace $studyRe, '${1}true'))

  Run @{}
  Check 'nothing set: the real robot + gestures + the game' ((Has '[START_SH_DRY_RUN] backend: corexy-ufo-backend --gesture --gesture-landmarks') -and (Has "[START_SH_DRY_RUN] game: godot --path $GAME -- --source websocket --gesture") -and (Has '起動: 実機') -and (Has 'モーターは無効') -and (Has '--port COM3') -and -not (Has '既定の'))

  Run @{ CXUFO_START_MODE = 'game'; CXUFO_START_ARGS = '--scenario reconnect' }
  Check 'environment: mode and args' ((Has '既定のモードで起動します（環境変数 CXUFO_START_MODE）: game --scenario reconnect') -and (Has '-- --scenario reconnect'))

  Run @{ CXUFO_START_MODE = 'game'; CXUFO_START_ARGS = '--from-env' } @('game', '--from-cli')
  Check 'any argument wins over the default' ((Has '-- --from-cli') -and -not (Has '--from-env') -and -not (Has '既定のモード'))

  Set-DotEnv @('# comment', 'CF_API_TOKEN=should-not-matter', 'export CXUFO_START_MODE="game"', "CXUFO_START_ARGS='--from-dotenv  --two'")
  Run @{}
  Check '.env: quotes, export, extra spaces' ((Has '（.env の CXUFO_START_MODE）: game --from-dotenv --two') -and (Has '-- --from-dotenv --two'))

  Set-DotEnv @('CXUFO_START_MODE=game        # game / mock / real / gesture / backend', 'CXUFO_START_ARGS="--a #b" # comment after quotes')
  Run @{}
  Check '.env: inline comments as in the README example' ((Has '（.env の CXUFO_START_MODE）: game --a #b') -and (Has '-- --a #b'))

  Set-DotEnv @('CXUFO_START_MODE=game', 'CXUFO_START_ARGS=--tag#1')
  Run @{}
  Check '.env: # inside a value is kept' (Has '-- --tag#1')

  Set-DotEnv @('export CXUFO_START_MODE="game"', "CXUFO_START_ARGS='--from-dotenv  --two'")
  Run @{ CXUFO_START_ARGS = '--from-env' }
  Check 'environment wins over .env per key' ((Has '-- --from-env') -and -not (Has '--from-dotenv'))

  $ran = Join-Path $TMP 'ran'
  New-Item -ItemType File -Path (Join-Path $TMP 'somefile') | Out-Null
  Set-DotEnv @('CXUFO_START_MODE=game', "CXUFO_START_ARGS=`$(New-Item $ran) *")
  Run @{}
  Check '.env is not run as code, no wildcard expansion' ((-not (Test-Path $ran)) -and (Has '$(New-Item') -and -not (Has 'somefile'))

  Set-DotEnv @('CXUFO_START_MODE=bogus')
  Run @{}
  Check 'an unknown default mode stops' (($script:CODE -ne 0) -and (Has '不明なモード: bogus'))

  Set-DotEnv @('CXUFO_START_MODE=')
  Run @{}
  Check 'empty value: the usual default' (($script:CODE -eq 0) -and -not (Has '既定の') -and (Has '起動: 実機'))

  Run @{} @('bogus2')
  Check 'an unknown mode argument stops with the message' (($script:CODE -ne 0) -and (Has '不明なモード: bogus2（'))

  # ---- the option form (#88)
  Remove-Item $DOTENV -ErrorAction SilentlyContinue
  Run @{} @('--mock')
  Check '--mock: the virtual crane with gestures' ((Has '[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock --gesture --gesture-landmarks') -and (Has "[START_SH_DRY_RUN] game: godot --path $GAME -- --source websocket --gesture") -and (Has '仮想クレーン'))

  Run @{} @('--mock', '--no-gesture')
  Check '--no-gesture: neither side gets gestures' ((Line '[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock') -and (Line "[START_SH_DRY_RUN] game: godot --path $GAME -- --source websocket --no-gesture") -and (Has 'ジェスチャー OFF'))

  Run @{} @('--port', 'COM7', '--gesture-camera', '1')
  Check '--port and --gesture-camera' ((Has '[START_SH_DRY_RUN] backend: corexy-ufo-backend --port COM7 --gesture 1 --gesture-landmarks') -and (Has 'ポート: COM7') -and -not (Has '--port COM3'))

  Run @{} @('--port=COM8')
  Check '--port=PORT' (Has 'backend: corexy-ufo-backend --port COM8 --gesture')

  Run @{} @('--game-only', '--', '--scenario', 'sudden_stop')
  Check '--game-only: the game alone, -- args go to the game' ((Line "[START_SH_DRY_RUN] game: godot --path $GAME -- --no-gesture --scenario sudden_stop") -and -not (Has 'backend:'))

  Run @{} @('--backend-only', '--', '--list-ports')
  Check '--backend-only: -- args go to the backend' ((Has '[START_SH_DRY_RUN] backend: corexy-ufo-backend --list-ports') -and -not (Has 'game:'))

  Run @{ START_SH_CONFIG = $studyOn } @('--mock', '--study', '--', '-v')
  Check '--study and -- args go to the backend' (Has '[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock --gesture --gesture-landmarks --study -v')

  Run @{} @('--help')
  Check '--help' (($script:CODE -eq 0) -and (Has '使い方: .\start.ps1') -and -not (Has 'backend:'))

  Run @{} @('--bogus')
  Check 'an unknown option stops' (($script:CODE -ne 0) -and (Has '不明なオプション: --bogus') -and -not (Has 'backend:'))
  Run @{} @('--mock', '--game-only')
  Check '--game-only with a robot stops' (($script:CODE -ne 0) -and (Has '--game-only はゲーム内の MockRobot'))
  Run @{} @('--real', '--mock')
  Check '--real and --mock stop' (($script:CODE -ne 0) -and (Has '一緒に使えない'))
  Run @{} @('--game-only', '--backend-only')
  Check '--game-only and --backend-only stop' (($script:CODE -ne 0) -and (Has '一緒に使えない'))
  Run @{} @('--backend-only', '--mock', '--gesture')
  Check '--backend-only --mock --gesture: the mock backend alone' ((Line '[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock --gesture --gesture-landmarks') -and (Has 'バックエンドだけ（仮想クレーン）') -and -not (Has 'game:'))
  Run @{} @('--mock', '--port', 'COM3')
  Check '--port without the real robot stops' (($script:CODE -ne 0) -and (Has '--port は'))
  Run @{} @('--game-only', '--study')
  Check '--study without a backend stops' (($script:CODE -ne 0) -and (Has '--study は'))
  Run @{} @('--port')
  Check '--port without a value stops' (($script:CODE -ne 0) -and (Has 'シリアルポートが要ります'))

  # PowerShell drops an unquoted -- typed at a prompt: say why, and '--' works
  Run @{} @('--mock', '--', '-v') -Command
  Check 'an unquoted -- at a prompt: the reason is given' (($script:CODE -ne 0) -and (Has "'--' と引用符で囲む") -and -not (Has 'backend:'))
  Run @{} @('--mock', "'--'", '-v') -Command
  Check "a quoted '--' at a prompt works" (Line '[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock --gesture --gesture-landmarks -v')

  # ---- #92: start.ps1 decides, the config holds defaults
  Run @{ START_SH_CONFIG = $studyOff } @('--mock', '--study')
  Check '--study with study.enabled false stops with the reason' (($script:CODE -ne 0) -and (Has 'study.enabled: true も要ります') -and -not (Has 'backend:'))
  # #93: the settings screen's config/local_settings.json wins over game_config.json
  $cfgLocal = Join-Path $TMP 'cfg_local'
  New-Item -ItemType Directory -Path $cfgLocal | Out-Null
  Copy-Item $studyOff (Join-Path $cfgLocal 'game_config.json')
  [System.IO.File]::WriteAllText((Join-Path $cfgLocal 'local_settings.json'), "{`n  `"study`": {`n    `"enabled`": true`n  }`n}`n")
  Run @{ START_SH_CONFIG = (Join-Path $cfgLocal 'game_config.json') } @('--mock', '--study')
  Check '--study: study.enabled from local_settings.json counts' (Has 'backend: corexy-ufo-backend --mock --gesture --gesture-landmarks --study')
  Copy-Item $studyOn (Join-Path $cfgLocal 'game_config.json') -Force
  [System.IO.File]::WriteAllText((Join-Path $cfgLocal 'local_settings.json'), '{"study": {"enabled": false, "provider": "codex"}}')
  Run @{ START_SH_CONFIG = (Join-Path $cfgLocal 'game_config.json') } @('--mock', '--study')
  Check '--study: local_settings.json false wins' (($script:CODE -ne 0) -and (Has 'study.enabled: true も要ります'))
  Run @{} @('--game-only', '--gesture')
  Check '--game-only --gesture: the game gets --gesture' (Line "[START_SH_DRY_RUN] game: godot --path $GAME -- --gesture")
  Run @{} @('--mock')
  Check 'gestures on: no --no-gesture' ((Has "game: godot --path $GAME -- --source websocket --gesture") -and -not (Has '--no-gesture'))

  # ---- the study mode (#86)
  Run @{} @('--mock', '--no-gesture', '--study-mode')
  Check '--study-mode starts the game in the study mode' ((Line '[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock') -and (Line "[START_SH_DRY_RUN] game: godot --path $GAME -- --source websocket --no-gesture --study-mode"))
  Run @{} @('--game-only', '--study-mode')
  Check '--game-only --study-mode' (Line "[START_SH_DRY_RUN] game: godot --path $GAME -- --no-gesture --study-mode")
  Run @{} @('--backend-only', '--study-mode')
  Check '--study-mode without a game stops' (($script:CODE -ne 0) -and (Has '--study-mode は'))
  Run @{} @('study')
  Check 'mode study as in #86' ((Line '[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock') -and (Line "[START_SH_DRY_RUN] game: godot --path $GAME -- --source websocket --study-mode"))

  # ---- the earlier mode names still work as they did
  Run @{} @('mock')
  Check 'mode mock as before' ((Line '[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock') -and (Line "[START_SH_DRY_RUN] game: godot --path $GAME -- --source websocket") -and (Has '今までの書き方'))
  Run @{} @('real', 'COM5', '--gesture')
  Check 'mode real PORT --gesture as before' ((Has '[START_SH_DRY_RUN] backend: corexy-ufo-backend --port COM5 --gesture-landmarks --gesture') -and (Has "[START_SH_DRY_RUN] game: godot --path $GAME -- --source websocket --gesture"))
  Run @{} @('gesture')
  Check 'mode gesture as before' (Has '[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock --gesture --gesture-landmarks')
  Run @{} @('backend', '--list-ports')
  Check 'mode backend as before' ((Has '[START_SH_DRY_RUN] backend: corexy-ufo-backend --list-ports') -and -not (Has 'game:'))

  # ---- the default from CXUFO_START_ARGS alone (option form)
  Set-DotEnv @('CXUFO_START_ARGS=--mock --no-gesture')
  Run @{}
  Check '.env CXUFO_START_ARGS alone: the option form' ((Has '既定の引数で起動します（.env の CXUFO_START_ARGS）: --mock --no-gesture') -and (Line '[START_SH_DRY_RUN] backend: corexy-ufo-backend --mock'))
  Run @{} @('--game-only')
  Check 'arguments win over CXUFO_START_ARGS' ((Line "[START_SH_DRY_RUN] game: godot --path $GAME -- --no-gesture") -and -not (Has '既定の'))
} finally {
  Remove-Item -Recurse -Force $TMP -ErrorAction SilentlyContinue
}

if ($script:fails -eq 0) { Write-Output 'start.ps1: all passed' } else { Write-Output "start.ps1: $($script:fails) failed" }
exit ([int]($script:fails -gt 0))
