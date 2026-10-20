#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$directory = Join-Path $root '.discorda/selfhost'
$settings = Join-Path $directory 'settings.json'
$backup = Join-Path $directory 'settings.json.before-native-media'
$nativeConfig = Join-Path $directory 'livekit-native.yaml'
$nativeExe = Join-Path $root 'artifacts/media-lab/server/livekit-server.exe'
$compose = Join-Path $root 'infra/compose/selfhost.yml'
$environmentFile = Join-Path $directory 'compose.env'

if (!(Test-Path -LiteralPath $backup)) { throw 'Backup anterior da API não encontrado.' }
$previous = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
if ($previous.LiveKit.InternalUrl -ne 'http://livekit:7880' -or
    $previous.ReverseProxy.Clusters.livekit.Destinations.local.Address -ne 'http://livekit:7880/') {
    throw 'Backup não corresponde à configuração Docker esperada.'
}

Copy-Item -LiteralPath $backup -Destination $settings -Force
$native = @(Get-CimInstance Win32_Process -Filter "Name='livekit-server.exe'" |
    Where-Object { $_.ExecutablePath -eq $nativeExe -and $_.CommandLine -and $_.CommandLine.Contains($nativeConfig) })
foreach ($process in $native) { Stop-Process -Id $process.ProcessId -ErrorAction Stop }

docker update --restart=unless-stopped discorda-home-livekit-1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível restaurar o reinício automático do LiveKit Docker.' }
docker compose --env-file $environmentFile -f $compose start livekit | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível reiniciar o LiveKit em Docker.' }
docker compose --env-file $environmentFile -f $compose restart api | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível reiniciar a API.' }

$ready = $false
for ($attempt = 0; $attempt -lt 15; $attempt++) {
    try {
        $response = Invoke-WebRequest 'http://localhost:18080/health/ready' -TimeoutSec 3
        if ($response.StatusCode -eq 200) { $ready = $true; break }
    } catch { }
    Start-Sleep -Seconds 2
}
if (!$ready) { throw 'A API ainda não está pronta após a reversão.' }
Remove-Item -LiteralPath $backup, $nativeConfig -ErrorAction Stop
Write-Output 'Mídia restaurada para Docker; API e banco disponíveis.'
