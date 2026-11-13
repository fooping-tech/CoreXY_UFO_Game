# CoreXY UFO Game launcher (Windows)。start.sh（macOS）と同じ動き。使い方は .\start.ps1 --help（下の Show-Usage と同じ）。
#
#   .\start.ps1                    実機 + ハンドジェスチャー + ゲーム（いつもの起動）
#   .\start.ps1 --mock             仮想クレーン（バックエンド --mock）+ ジェスチャー + ゲーム
#   .\start.ps1 --no-gesture       ジェスチャーなし（--mock とも組み合わせられる）
#   .\start.ps1 --game-only        ゲームだけ（ゲーム内の MockRobot。バックエンドなし）
#   .\start.ps1 --backend-only     バックエンドだけ（--mock と組み合わせられる）
#   .\start.ps1 ... '--' <引数>    '--' の後ろはバックエンドへ（--game-only ではゲームへ）そのまま渡す。
#                                  PowerShell は引用符のない -- を取り除くので '--' と書く
#
# 今までの書き方（game / mock / real [PORT] / gesture / study / backend）もそのまま使える。
#
# 引数なしで起動したときの引数は、環境変数かリポジトリ直下の .env の CXUFO_START_ARGS で決められる
# （例: CXUFO_START_ARGS=--mock --no-gesture）。今までの CXUFO_START_MODE（モード名）も使える。
# 環境変数が .env より優先。引数を 1 つでも渡したら引数が優先で、CXUFO_START_* は使わない。
#
# 環境変数 GODOT で Godot 実行ファイルを上書きできます。
# 環境変数 START_SH_WAIT_S でバックエンドの起動を待つ秒数を変えられます（既定 60。--gesture は約 12 秒かかる）。
# 環境変数 START_SH_STOP_WAIT_S でバックエンドが自分で止まるのを待つ秒数を変えられます（既定 15）。
# 環境変数 START_SH_NO_GAME=1 なら Godot を起動せず、起動コマンドを表示するだけ（確認用）。
# 環境変数 START_SH_DRY_RUN=1 ならバックエンドもゲームも起動せず、起動コマンドを表示するだけ（確認用）。
# 実行が禁止されていると言われたら: powershell -ExecutionPolicy Bypass -File .\start.ps1 ...
#
# バックエンドの WebSocket のアドレスは config/game_config.json の network.websocket_url
# （--ws-host / --ws-port を渡したらそちら）。起動前にそのポートが使われていたら止める:
# 別のバックエンド（例: 起動したままの実機用）にゲームがつながるのを防ぐため。
#
# ゲームを閉じたら（Ctrl-C でも）バックエンドを止める。まずバックエンドの標準入力を閉じて、
# Ctrl-C と同じ順番（サーバー → ロボット。動作中なら ABORT）で自分で止まらせる。Windows には
# 送れる SIGTERM がないため（--stop-on-stdin-close）。START_SH_STOP_WAIT_S 秒以内に終わらない
# ときだけ、プロセスツリーを強制終了する。
$ErrorActionPreference = 'Stop'

$ROOT = $PSScriptRoot
$GAME_DIR = Join-Path $ROOT 'game'
$BACKEND_DIR = Join-Path $ROOT 'backend'
$CONFIG_FILE = if ($env:START_SH_CONFIG) { $env:START_SH_CONFIG } else { Join-Path $ROOT (Join-Path 'config' 'game_config.json') }  # START_SH_CONFIG: tests only
$ENV_FILE = if ($env:START_SH_ENV_FILE) { $env:START_SH_ENV_FILE } else { Join-Path $ROOT '.env' }  # START_SH_ENV_FILE: tests only
# 他プロジェクトの venv が有効でも backend/.venv を使わせる
Remove-Item Env:VIRTUAL_ENV -ErrorAction SilentlyContinue

function Write-Err([string]$msg) { [Console]::Error.WriteLine($msg) }
function Fail([string]$msg) {
  Write-Err $msg
  exit 1
}

# The console build waits for the game to exit and prints its log here (the GUI
# build returns at once from PowerShell).
function Find-Godot {
  if ($env:GODOT) { return $env:GODOT }
  foreach ($name in 'godot_console', 'godot') {
    $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
  }
  # winget without admin rights installs here but creates no `godot` alias
  $dirs = @()
  if ($env:LOCALAPPDATA) { $dirs += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') }
  if ($env:ProgramFiles) { $dirs += (Join-Path $env:ProgramFiles 'WinGet\Packages') }
  foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) { continue }
    $exe = Get-ChildItem -Path $dir -Directory -Filter 'GodotEngine.GodotEngine_*' -ErrorAction SilentlyContinue |
      ForEach-Object { Get-ChildItem -Path $_.FullName -Filter 'Godot_v*_win64_console.exe' -ErrorAction SilentlyContinue } |
      Sort-Object Name -Descending | Select-Object -First 1
    if ($exe) { return $exe.FullName }
  }
  Fail 'Godot が見つかりません: winget install GodotEngine.GodotEngine（または環境変数 GODOT に実行ファイルを指定）'
}

function Assert-Uv {
  if (-not (Get-Command uv -CommandType Application -ErrorAction SilentlyContinue)) {
    Fail 'uv が見つかりません: winget install astral-sh.uv'
  }
}

# Same rule as the backend (config.py::load_config, then --ws-host / --ws-port).
function Resolve-WsEndpoint([string[]]$argv) {
  $url = ''
  if (Test-Path $CONFIG_FILE) {
    $m = [regex]::Match((Get-Content -Raw -Encoding UTF8 $CONFIG_FILE), '"websocket_url"\s*:\s*"([^"]*)"')
    if ($m.Success) { $url = $m.Groups[1].Value }
  }
  if (-not $url) { $url = 'ws://127.0.0.1:8765' }
  $hostport = $url -replace '^[^:]*://', ''
  $hostport = ($hostport -split '/', 2)[0]
  if ($hostport -match '^(.*):([^:]*)$') {
    $script:WS_HOST = $Matches[1]
    $script:WS_PORT = $Matches[2]
  } else {
    $script:WS_HOST = $hostport
    $script:WS_PORT = '8765'
  }
  if (-not $script:WS_HOST) { $script:WS_HOST = '127.0.0.1' }
  $prev = ''
  foreach ($a in $argv) {
    if ($prev -eq '--ws-host') { $script:WS_HOST = $a }
    if ($prev -eq '--ws-port') { $script:WS_PORT = $a }
    if ($a -like '--ws-host=*') { $script:WS_HOST = $a.Substring(10) }
    if ($a -like '--ws-port=*') { $script:WS_PORT = $a.Substring(10) }
    $prev = $a
  }
}

# study.enabled: 'true' / 'false' / '' (not found). The same reading as start.sh: "enabled"
# is the study section's first key (the settings screen writes local_settings.json with sorted
# keys). config/local_settings.json (the settings screen, #93) wins over game_config.json.
function Get-JsonStudyEnabled([string]$path) {
  if (-not (Test-Path $path)) { return '' }
  $text = (Get-Content -Raw -Encoding UTF8 $path) -replace "[`r`n]", ''
  $ms = [regex]::Matches($text, '"study"\s*:\s*\{\s*"enabled"\s*:\s*(true|false)')
  if ($ms.Count -eq 0) { return '' }
  return $ms[$ms.Count - 1].Groups[1].Value
}
function Get-ConfigStudyEnabled {
  $v = Get-JsonStudyEnabled (Join-Path (Split-Path -Parent $CONFIG_FILE) 'local_settings.json')
  if (-not $v) { $v = Get-JsonStudyEnabled $CONFIG_FILE }
  return $v
}

function Test-PortOpen {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $task = $client.ConnectAsync($script:WS_HOST, [int]$script:WS_PORT)
    return ($task.Wait(200) -and $client.Connected)
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Get-PortListener {  # pid of the process listening on WS_PORT ($null if none)
  try {
    $c = Get-NetTCPConnection -State Listen -LocalPort ([int]$script:WS_PORT) -ErrorAction Stop | Select-Object -First 1
    if ($c) { return [int]$c.OwningProcess }
  } catch {}
  return $null
}

function Assert-PortFree {
  $listener = Get-PortListener
  if ((Test-PortOpen) -or $listener) {
    Write-Err "ポート $($script:WS_HOST):$($script:WS_PORT) はすでに使われています。別のバックエンドが起動したままかもしれません。"
    if ($listener) {
      $p = Get-CimInstance Win32_Process -Filter "ProcessId = $listener" -ErrorAction SilentlyContinue
      $line = if ($p -and $p.CommandLine) { $p.CommandLine } elseif ($p) { $p.Name } else { '' }
      if ($line.Length -gt 160) { $line = $line.Substring(0, 160) }
      Write-Err "  使用中のプロセス: $listener $line"
      Write-Err '  そのプロセスを終了してから再実行してください（意図したものなら .\start.ps1 --game-only でゲームだけ起動）。'
    }
    exit 1
  }
}

# Is the listener our backend (BACKEND or one of its descendants)?
function Test-ListenerIsOurs {
  $id = Get-PortListener
  if (-not $id) { return $true }  # unknown: the pre-start check already ruled out others
  $seen = @{}
  while ($id -and -not $seen.ContainsKey($id)) {
    if ($id -eq $script:BACKEND.Id) { return $true }
    $seen[$id] = $true
    $p = Get-CimInstance Win32_Process -Filter "ProcessId = $id" -ErrorAction SilentlyContinue
    if (-not $p) { break }
    $id = [int]$p.ParentProcessId
  }
  return $false
}

# How long to wait for the backend's WebSocket. With --gesture, MediaPipe takes
# ~11 s to load (GPU delegate) before the port opens.
$WAIT_S = if ($env:START_SH_WAIT_S) { [int]$env:START_SH_WAIT_S } else { 60 }
# How long the backend gets to stop by itself (server, then the robot) before it is killed.
$STOP_WAIT_S = if ($env:START_SH_STOP_WAIT_S) { [int]$env:START_SH_STOP_WAIT_S } else { 15 }

function Wait-ForPort {
  for ($i = 1; $i -le $WAIT_S * 10; $i++) {
    if ($i % 50 -eq 0) { Write-Err "バックエンドの起動を待っています（$([int]($i / 10)) 秒）..." }
    if ($script:BACKEND.HasExited) { Fail 'バックエンドが起動に失敗しました' }
    if (Test-PortOpen) {
      # The port being open is not enough: the process we started must still be alive
      # and be the one listening.
      Start-Sleep -Milliseconds 300
      if ($script:BACKEND.HasExited) { Fail 'バックエンドが起動直後に終了しました' }
      if (-not (Test-ListenerIsOurs)) {
        Fail "ポート $($script:WS_HOST):$($script:WS_PORT) で待ち受けているのは起動したバックエンドではありません"
      }
      return
    }
    Start-Sleep -Milliseconds 100
  }
  Fail "バックエンドの WebSocket ($($script:WS_HOST):$($script:WS_PORT)) が $WAIT_S 秒以内に開きませんでした（START_SH_WAIT_S で延ばせます）"
}

# A process command line from separate arguments: quote what needs it (CommandLineToArgvW rules).
function Join-Args([string[]]$argv) {
  ($argv | ForEach-Object {
    if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ }
  }) -join ' '
}

$script:BACKEND = $null
$script:GAME = $null
function Stop-Backend {
  $p = $script:BACKEND
  if (-not $p -or $p.HasExited) { return }
  # Ask first: with stdin closed the backend stops as on Ctrl-C (the server, then the robot:
  # ABORT if it is moving). A forced kill skips that, and queued motion would go on.
  Write-Err 'バックエンドを止めています...'
  try { $p.StandardInput.Close() } catch {}
  $deadline = (Get-Date).AddSeconds($STOP_WAIT_S)
  while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
  if ($p.HasExited) { return }
  Write-Err "バックエンドが $STOP_WAIT_S 秒以内に止まらないので強制終了します（START_SH_STOP_WAIT_S で延ばせます）。"
  Write-Err '  実機が動いていたら、非常停止ボタンか電源で止めてください（USB が切れても実機の動きは止まらない）。'
  # uv runs the backend as a child process: end the whole tree
  & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
}

function Stop-Game {  # Ctrl-C with the window still open: do not leave the game behind
  $p = $script:GAME
  if ($p -and -not $p.HasExited) {
    try { $p.Kill() } catch {}
  }
}

$DRY_RUN = $env:START_SH_DRY_RUN

function Test-GameNeedsImport {  # no class cache, or a script newer than it
  $cache = Join-Path $GAME_DIR '.godot\global_script_class_cache.cfg'
  if (-not (Test-Path (Join-Path $GAME_DIR '.godot\imported')) -or -not (Test-Path $cache)) { return $true }
  $t = (Get-Item $cache).LastWriteTimeUtc
  $newer = Get-ChildItem -Path $GAME_DIR -Recurse -File -Filter '*.gd' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -gt $t } | Select-Object -First 1
  return [bool]$newer
}

function Invoke-Game([string[]]$gameArgs) {
  $shown = "godot --path $GAME_DIR -- " + ($gameArgs -join ' ')
  if ($DRY_RUN -eq '1') {
    Write-Output "[START_SH_DRY_RUN] game: $shown"
    return
  }
  if ($env:START_SH_NO_GAME -eq '1') {
    $backend = if ($script:BACKEND) { "（バックエンド $($script:WS_HOST):$($script:WS_PORT) は起動済み）" } else { '' }
    Write-Output "[START_SH_NO_GAME] $shown$backend"
    return
  }
  $godot = Find-Godot
  # a fresh checkout has no class cache yet, and after a pull it lacks the new scripts: their
  # class_name types would not resolve. Running the game does not update it, an import does.
  if (Test-GameNeedsImport) {
    Write-Output 'Godot のインポートを実行しています（新しいチェックアウトか、スクリプトが更新されたため）...'
    & $godot --headless --path $GAME_DIR --import 2>&1 | Out-Null
  }
  $argv = @('--path', $GAME_DIR, '--') + $gameArgs
  # Start-Process + polling, not `& $godot`: a GUI build (GODOT=...Godot_v*_win64.exe) would
  # return at once, and a blocking wait would not let Ctrl-C through
  $script:GAME = Start-Process -FilePath $godot -ArgumentList (Join-Args $argv) -NoNewWindow -PassThru
  $null = $script:GAME.Handle  # without the handle, ExitCode stays empty after the exit
  while (-not $script:GAME.WaitForExit(200)) {}
  $script:GAME_EXIT = $script:GAME.ExitCode
}

function Start-Backend([string[]]$argv) {
  if ($DRY_RUN -eq '1') {
    Write-Output ("[START_SH_DRY_RUN] backend: corexy-ufo-backend " + ($argv -join ' '))
    return
  }
  Assert-Uv
  Resolve-WsEndpoint $argv
  Assert-PortFree
  # camera / hand tracking need the optional extras; a plain sync would remove them
  $sync = @('sync', '--quiet')
  foreach ($a in $argv) {
    if ($a -in '--gesture', '--hands', '--camera' -or $a -like '--gesture=*' -or $a -like '--camera=*') {
      $sync = @('sync', '--quiet', '--extra', 'vision', '--extra', 'hands')
      break
    }
  }
  Push-Location $BACKEND_DIR
  try {
    & uv @sync
    if ($LASTEXITCODE -ne 0) { Fail 'uv sync に失敗しました' }
  } finally {
    Pop-Location
  }
  # stdin is a pipe that only Stop-Backend closes (also closed if this script dies)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Command uv -CommandType Application | Select-Object -First 1).Source
  $psi.Arguments = Join-Args (@('run', 'corexy-ufo-backend', '--stop-on-stdin-close') + $argv)
  $psi.WorkingDirectory = $BACKEND_DIR
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $script:BACKEND = [System.Diagnostics.Process]::Start($psi)
  Wait-ForPort
}

function Invoke-BackendOnly([string[]]$argv) {  # in the foreground (no game)
  if ($DRY_RUN -eq '1') {
    Write-Output ("[START_SH_DRY_RUN] backend: corexy-ufo-backend " + ($argv -join ' '))
    return
  }
  Assert-Uv
  Push-Location $BACKEND_DIR
  try {
    & uv run corexy-ufo-backend @argv
    $script:GAME_EXIT = $LASTEXITCODE
  } finally {
    Pop-Location
  }
}

# One KEY=VALUE from .env, without running it as code (the file also holds tokens, which
# stay out of this process's environment). The last line wins.
function Read-DotEnv([string]$key) {
  $value = ''
  if (-not (Test-Path $ENV_FILE)) { return $value }
  foreach ($line in (Get-Content -Encoding UTF8 $ENV_FILE)) {
    $line = $line.TrimEnd("`r").TrimStart()
    if ($line.StartsWith('export ')) { $line = $line.Substring(7) }
    if (-not $line.StartsWith("$key=")) { continue }
    $val = $line.Substring($key.Length + 1).TrimStart()
    $q = if ($val.Length -gt 0) { $val.Substring(0, 1) } else { '' }
    if (($q -eq '"' -or $q -eq "'") -and $val.Substring(1).Contains($q)) {
      $val = $val.Substring(1)
      $val = $val.Substring(0, $val.IndexOf($q))                # quoted: up to the closing quote
    } else {
      $val = ($val -replace '\s#.*$', '').TrimEnd()             # unquoted: drop an inline " # comment"
    }
    $value = $val
  }
  return $value
}

# The environment wins over .env (same rule as the homework watch's CF_* keys).
function Get-StartSetting([string]$key) {
  $envVal = [Environment]::GetEnvironmentVariable($key)
  if ($envVal) { return @{ Value = $envVal; From = "環境変数 $key" } }
  return @{ Value = (Read-DotEnv $key); From = ".env の $key" }
}

function Show-Usage {
  Write-Output @'
使い方: .\start.ps1 [オプション] ['--' バックエンド（--game-only ではゲーム）への引数]

ロボット（省くと --real）
  --real            実機（USB シリアル）
  --mock            仮想クレーン（バックエンドの --mock）。実機には何も送らない

起動するもの（省くとバックエンド + ゲーム）
  --game-only       ゲームだけ（ゲーム内の MockRobot。バックエンドなし）
  --backend-only    バックエンドだけ（ゲームなし。例: '--' --list-ports）

オプション
  --no-gesture      ハンドジェスチャーを使わない（--real / --mock では既定で ON）
  --gesture         ハンドジェスチャーを使う（--game-only / --backend-only でも ON にする）
  --gesture-camera CAM   ジェスチャーに使うカメラ（番号。省くと config の gesture.camera）
  --port PORT       実機のシリアルポート（COM3 など。省くと config か自動検出）
  --study           Study タブ（カメラ学習アシスタント。config の study.enabled も必要）
  --study-mode      UFOくん 勉強モードで開始する（ゲーム中はいつでも F5 で開始・終了）
  -h, --help        この説明

例
  .\start.ps1 --port COM3                     実機 + ジェスチャー + ゲーム
  .\start.ps1 --mock                          実機なしで（仮想クレーン + ジェスチャー）
  .\start.ps1 --mock --no-gesture             実機もカメラもなしで
  .\start.ps1 --mock --no-gesture --study-mode   勉強モードのデモ（実機なし）
  .\start.ps1 --game-only '--' --scenario sudden_stop
  .\start.ps1 --backend-only '--' --list-ports

PowerShell は引用符のない -- を取り除くので、'--' と引用符で囲む。
今までの書き方も使えます: game / mock / real [PORT] / gesture / study / backend [引数]
引数なしのときの既定は .env か環境変数の CXUFO_START_ARGS（例: CXUFO_START_ARGS=--mock）。
実機のモーターは、どの起動でも最初は無効（デバッグパネルの「実機」タブで有効にするまで動かない）。
'@
}

function Exit-Usage([string]$msg) { Fail "$msg（.\start.ps1 --help を参照）" }

# PowerShell drops an unquoted `--` from the arguments of a script called from a prompt.
function Test-DashDashDropped([string[]]$argv) {
  if ($argv -contains '--') { return $false }
  return ($script:INVOCATION_LINE -match '(^|\s)--(\s|$)')
}

# The option form: sets TARGET (real / mock / game / backend), the backend's and the game's arguments.
function Read-Options([string[]]$argv) {
  $robot = ''; $parts = ''; $gesture = ''; $camera = ''; $port = ''; $study = $false; $studyMode = $false
  $script:EXTRA = @()
  $i = 0
  while ($i -lt $argv.Count) {
    $a = $argv[$i]
    switch -Regex ($a) {
      '^--(real|mock)$' {
        $r = $a.Substring(2)
        if ($robot -and $robot -ne $r) { Exit-Usage '--real と --mock は一緒に使えない' }
        $robot = $r; break
      }
      '^--(game-only|backend-only)$' {
        if ($parts -and $parts -ne $a) { Exit-Usage '--game-only と --backend-only は一緒に使えない' }
        $parts = $a; break
      }
      '^--gesture$' { $gesture = '1'; break }
      '^--no-gesture$' { $gesture = '0'; break }
      '^--gesture-camera$' {
        if ($i + 1 -ge $argv.Count) { Exit-Usage '--gesture-camera にはカメラが要ります' }
        $i++; $camera = $argv[$i]; $gesture = '1'; break
      }
      '^--gesture-camera=' { $camera = $a.Substring($a.IndexOf('=') + 1); $gesture = '1'; break }
      '^--port$' {
        if ($i + 1 -ge $argv.Count) { Exit-Usage '--port にはシリアルポートが要ります' }
        $i++; $port = $argv[$i]; break
      }
      '^--port=' { $port = $a.Substring($a.IndexOf('=') + 1); break }
      '^--study$' { $study = $true; break }
      '^--study-mode$' { $studyMode = $true; break }
      '^(-h|--help)$' { Show-Usage; exit 0 }
      '^--$' {
        if ($i + 1 -lt $argv.Count) { $script:EXTRA = @($argv[($i + 1)..($argv.Count - 1)]) }
        $i = $argv.Count; break
      }
      default {
        if (Test-DashDashDropped $argv) {
          Exit-Usage "不明なオプション: $a（PowerShell は引用符のない -- を取り除くので、'--' と引用符で囲む）"
        }
        Exit-Usage "不明なオプション: $a（バックエンド・ゲームへの引数は '--' の後ろに書く）"
      }
    }
    $i++
  }
  switch ($parts) {
    '--game-only' {
      if ($robot) { Exit-Usage '--game-only はゲーム内の MockRobot を使う（--real / --mock は要らない）' }
      if ($port) { Exit-Usage '--port はバックエンドを起動するときだけ（--game-only では使えない）' }
      if ($study) { Exit-Usage '--study はバックエンドを起動するときだけ（--game-only では使えない）' }
      $script:TARGET = 'game'
    }
    '--backend-only' { $script:TARGET = 'backend' }
    default { $script:TARGET = if ($robot) { $robot } else { 'real' } }
  }
  if ($port -and $robot -eq 'mock') { Exit-Usage '--port は実機のときだけ（--mock では使えない）' }
  # gestures: on by default when the backend and the game both start
  if (-not $gesture) { $gesture = if ($script:TARGET -in 'real', 'mock') { '1' } else { '0' } }
  $script:GESTURE = $gesture; $script:PORT = $port
  $script:BACKEND_MOCK = ($robot -eq 'mock')

  $b = @()
  if ($script:BACKEND_MOCK) { $b += '--mock' }
  if ($port) { $b += @('--port', $port) }
  if ($gesture -eq '1' -and $script:TARGET -ne 'game') {
    if ($camera) { $b += @('--gesture', $camera) } else { $b += '--gesture' }
    # the landmarks too: the debug panel draws the hand skeleton over the camera view
    $b += '--gesture-landmarks'
  }
  if ($study) {
    # the Study tab sends camera images to the assistant: it needs both switches, this
    # option and study.enabled in the config. Say so now, not as a backend log line.
    if ((Get-ConfigStudyEnabled) -eq 'false') {
      Fail '--study には study.enabled: true も要ります（タイトル画面の歯車の設定画面か config/game_config.json で。Study タブはカメラの画像を AI に送るので、2 か所で有効にする）'
    }
    $b += '--study'
  }
  $script:BACKEND_ARGS = $b
  $g = @()
  if ($script:TARGET -ne 'game') { $g += @('--source', 'websocket') }
  # always say it: the config's gesture.enabled is only the default of a game started
  # without start.ps1
  if ($script:TARGET -ne 'backend') {
    if ($gesture -eq '1') { $g += '--gesture' } else { $g += '--no-gesture' }
  }
  if ($studyMode) {
    if ($script:TARGET -eq 'backend') { Exit-Usage '--study-mode はゲームを起動するときだけ（--backend-only では使えない）' }
    $g += '--study-mode'
  }
  $script:GAME_ARGS = $g
}

function Show-Describe {  # one line: what starts (above all, whether it is the real robot)
  switch ($script:TARGET) {
    'real' {
      $p = if ($script:PORT) { $script:PORT } else { 'config / 自動検出' }
      $what = "実機（ポート: $p）+ ゲーム"
    }
    'mock' { $what = '仮想クレーン（実機には送らない）+ ゲーム' }
    'game' { $what = 'ゲームだけ（ゲーム内の MockRobot）' }
    'backend' { $what = if ($script:BACKEND_MOCK) { 'バックエンドだけ（仮想クレーン）' } else { 'バックエンドだけ（実機用）' } }
  }
  $g = if ($script:GESTURE -eq '1') { ' / ジェスチャー ON' } else { ' / ジェスチャー OFF' }
  Write-Err "起動: $what$g"
  if ($script:TARGET -eq 'real') {
    Write-Err '  実機のモーターは無効で起動します（「実機」タブで有効にするまで動きません）'
    if (-not $script:PORT) {
      Write-Err '  ポートは --port COM3 のように指定すると確実です（自動検出は macOS のポート名向け。番号は .\start.ps1 --backend-only ''--'' --list-ports）'
    }
  }
}

function Invoke-Options([string[]]$argv) {
  Read-Options $argv
  Show-Describe
  switch ($script:TARGET) {
    { $_ -in 'real', 'mock' } {
      Start-Backend ($script:BACKEND_ARGS + $script:EXTRA)
      Invoke-Game $script:GAME_ARGS
    }
    'game' { Invoke-Game ($script:GAME_ARGS + $script:EXTRA) }
    'backend' { Invoke-BackendOnly ($script:BACKEND_ARGS + $script:EXTRA) }
  }
}

# The earlier form: a mode name first (kept as it was, so .env files and notes still work).
function Invoke-Mode([string]$mode, [string[]]$rest) {
  if ($mode -ne 'help') {
    $shownArgs = if ($rest.Count -gt 0) { ' ' + ($rest -join ' ') } else { '' }
    Write-Err "起動（今までの書き方）: $mode$shownArgs"
  }
  switch ($mode) {
    'game' { Invoke-Game $rest }
    'mock' {
      Start-Backend (@('--mock') + $rest)
      Invoke-Game @('--source', 'websocket')
    }
    'real' {
      $backendArgs = @()
      $extra = $rest
      if ($extra.Count -gt 0 -and -not $extra[0].StartsWith('-')) {
        $backendArgs = @('--port', $extra[0])
        $extra = @($extra | Select-Object -Skip 1)
      }
      $gameArgs = @('--source', 'websocket')
      foreach ($a in $extra) {
        # --gesture: the game starts with the hand joystick on, the backend sends the
        # landmarks for the HUD / debug view
        if ($a -eq '--gesture' -or $a -like '--gesture=*') {
          $gameArgs += '--gesture'
          $backendArgs += '--gesture-landmarks'
        }
      }
      Start-Backend ($backendArgs + $extra)
      Invoke-Game $gameArgs
    }
    'study' {
      # the study mode (#86) on the mock robot: simulated / camera comes from study_mode.demo.source
      Start-Backend (@('--mock') + $rest)
      Invoke-Game @('--source', 'websocket', '--study-mode')
    }
    'gesture' {
      Start-Backend (@('--mock', '--gesture', '--gesture-landmarks') + $rest)
      Invoke-Game @('--source', 'websocket', '--gesture')
    }
    'backend' { Invoke-BackendOnly $rest }
    'help' { Show-Usage }
  }
}

$MODES = @('game', 'mock', 'real', 'gesture', 'study', 'backend', 'help')
$script:INVOCATION_LINE = $MyInvocation.Line
$script:GAME_EXIT = 0
$argv = @($args | ForEach-Object { [string]$_ })

if ($argv.Count -eq 0) {
  # No arguments: the configured default (CXUFO_START_MODE / CXUFO_START_ARGS), else the
  # real robot with gestures.
  $modeSetting = Get-StartSetting 'CXUFO_START_MODE'
  $argsSetting = Get-StartSetting 'CXUFO_START_ARGS'
  # whitespace splitting only: nothing in the value is run or expanded
  $defaultArgs = @(([string]$argsSetting.Value).Trim() -split '\s+' | Where-Object { $_ -ne '' })
  if ($modeSetting.Value) {
    $shownArgs = if ($defaultArgs.Count -gt 0) { ' ' + ($defaultArgs -join ' ') } else { '' }
    Write-Err "既定のモードで起動します（$($modeSetting.From)）: $($modeSetting.Value)$shownArgs"
    $argv = @([string]$modeSetting.Value) + $defaultArgs
  } elseif ($defaultArgs.Count -gt 0) {
    Write-Err "既定の引数で起動します（$($argsSetting.From)）: $($defaultArgs -join ' ')"
    $argv = $defaultArgs
  }
}

try {
  if ($argv.Count -gt 0 -and $MODES -contains $argv[0]) {
    $rest = @(if ($argv.Count -gt 1) { $argv[1..($argv.Count - 1)] })
    Invoke-Mode $argv[0] $rest
  } elseif ($argv.Count -gt 0 -and -not $argv[0].StartsWith('-')) {
    Fail "不明なモード: $($argv[0])（.\start.ps1 --help を参照）"
  } else {
    Invoke-Options $argv
  }
} finally {
  Stop-Game
  Stop-Backend
}
exit $script:GAME_EXIT
