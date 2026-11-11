# CoreXY UFO Game launcher (Windows)
#
#   .\start.ps1                     ゲームのみ（Godot 内蔵 MockRobot）
#   .\start.ps1 mock [backend args] Python バックエンド --mock + ゲーム（WebSocket 経由）
#   .\start.ps1 real [PORT] [args]  実機バックエンド + ゲーム（PORT は COM3 など。省略時は config / 自動検出。--gesture でハンドジェスチャー ON）
#   .\start.ps1 gesture [args]      バックエンド --mock --gesture（カメラでピンチ操作）+ ゲーム（ジェスチャー ON）
#   .\start.ps1 backend [args]      バックエンドのみ（例: .\start.ps1 backend --list-ports）
#
# 環境変数 GODOT で Godot 実行ファイルを上書きできます。
# 環境変数 START_SH_WAIT_S でバックエンドの起動を待つ秒数を変えられます（既定 60。--gesture は約 12 秒かかる）。
# 環境変数 START_SH_NO_GAME=1 なら Godot を起動せず、起動コマンドを表示するだけ（確認用）。
# 実行が禁止されていると言われたら: powershell -ExecutionPolicy Bypass -File .\start.ps1 ...
#
# start.sh（macOS）と同じ動き。バックエンドの WebSocket のアドレスは config/game_config.json の
# network.websocket_url（--ws-host / --ws-port を渡したらそちら）。起動前にそのポートが使われていたら止める:
# 別のバックエンド（例: 起動したままの実機用）にゲームがつながるのを防ぐため。
$ErrorActionPreference = 'Stop'

$ROOT = $PSScriptRoot
$GAME_DIR = Join-Path $ROOT 'game'
$BACKEND_DIR = Join-Path $ROOT 'backend'
$CONFIG_FILE = Join-Path $ROOT 'config\game_config.json'
# 他プロジェクトの venv が有効でも backend/.venv を使わせる
Remove-Item Env:VIRTUAL_ENV -ErrorAction SilentlyContinue

function Fail([string]$msg) {
  [Console]::Error.WriteLine($msg)
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
  $dirs = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
    (Join-Path $env:ProgramFiles 'WinGet\Packages')
  )
  foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) { continue }
    $exe = Get-ChildItem -Path $dir -Directory -Filter 'GodotEngine.GodotEngine_*' -ErrorAction SilentlyContinue |
      ForEach-Object { Get-ChildItem -Path $_.FullName -Filter 'Godot_v*_win64_console.exe' -ErrorAction SilentlyContinue } |
      Sort-Object Name -Descending | Select-Object -First 1
    if ($exe) { return $exe.FullName }
  }
  Fail 'Godot が見つかりません: winget install GodotEngine.GodotEngine（または環境変数 GODOT に実行ファイルを指定）'
}

function Require-Uv {
  if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
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

function Ensure-PortFree {
  $listener = Get-PortListener
  if ((Test-PortOpen) -or $listener) {
    [Console]::Error.WriteLine("ポート $($script:WS_HOST):$($script:WS_PORT) はすでに使われています。別のバックエンドが起動したままかもしれません。")
    if ($listener) {
      $p = Get-CimInstance Win32_Process -Filter "ProcessId = $listener" -ErrorAction SilentlyContinue
      $line = if ($p -and $p.CommandLine) { $p.CommandLine } elseif ($p) { $p.Name } else { '' }
      if ($line.Length -gt 160) { $line = $line.Substring(0, 160) }
      [Console]::Error.WriteLine("  使用中のプロセス: $listener $line")
      [Console]::Error.WriteLine('  そのプロセスを終了してから再実行してください（意図したものなら .\start.ps1 game でゲームだけ起動）。')
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

function Wait-ForPort {
  for ($i = 1; $i -le $WAIT_S * 10; $i++) {
    if ($i % 50 -eq 0) { [Console]::Error.WriteLine("バックエンドの起動を待っています（$([int]($i / 10)) 秒）...") }
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

# Start-Process joins the argument list with spaces: quote what needs it.
function Join-Args([string[]]$argv) {
  ($argv | ForEach-Object {
    if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ }
  }) -join ' '
}

$script:BACKEND = $null
function Stop-Backend {
  if ($script:BACKEND -and -not $script:BACKEND.HasExited) {
    # uv runs the backend as a child process: end the whole tree
    & taskkill.exe /PID $script:BACKEND.Id /T /F 2>&1 | Out-Null
  }
}

function Invoke-Game([string[]]$gameArgs) {
  if ($env:START_SH_NO_GAME -eq '1') {
    $backend = if ($script:BACKEND) { "（バックエンド $($script:WS_HOST):$($script:WS_PORT) は起動済み）" } else { '' }
    Write-Output "[START_SH_NO_GAME] godot --path $GAME_DIR -- $($gameArgs -join ' ')$backend"
    return
  }
  $godot = Find-Godot
  # a fresh checkout has no class cache yet: the scripts' class_name types would not resolve
  if (-not (Test-Path (Join-Path $GAME_DIR '.godot\imported'))) {
    Write-Output 'Godot の初回インポートを実行しています...'
    & $godot --headless --path $GAME_DIR --import 2>&1 | Out-Null
  }
  $argv = @('--path', $GAME_DIR, '--') + $gameArgs
  & $godot @argv
}

function Start-Backend([string[]]$argv) {
  Require-Uv
  Resolve-WsEndpoint $argv
  Ensure-PortFree
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
  $runArgs = @('run', 'corexy-ufo-backend') + $argv
  $script:BACKEND = Start-Process -FilePath (Get-Command uv).Source -ArgumentList (Join-Args $runArgs) `
    -WorkingDirectory $BACKEND_DIR -NoNewWindow -PassThru
  Wait-ForPort
}

$MODE = if ($args.Count -gt 0) { [string]$args[0] } else { 'game' }
$rest = @(if ($args.Count -gt 1) { $args[1..($args.Count - 1)] | ForEach-Object { [string]$_ } })

try {
  switch ($MODE) {
    'game' {
      Invoke-Game $rest
    }
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
    'gesture' {
      # landmarks too: the debug panel draws the hand skeleton over the camera view
      Start-Backend (@('--mock', '--gesture', '--gesture-landmarks') + $rest)
      Invoke-Game @('--source', 'websocket', '--gesture')
    }
    'backend' {
      Require-Uv
      Push-Location $BACKEND_DIR
      try {
        & uv run corexy-ufo-backend @rest
        exit $LASTEXITCODE
      } finally {
        Pop-Location
      }
    }
    { $_ -in '-h', '--help', 'help' } {
      Get-Content -Encoding UTF8 $PSCommandPath | Select-Object -Skip 1 -First 11 | ForEach-Object { $_ -replace '^# ?', '' }
    }
    default {
      Fail "不明なモード: $MODE（.\start.ps1 --help を参照）"
    }
  }
} finally {
  Stop-Backend
}
