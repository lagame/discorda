#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$compose = Join-Path $root 'infra/compose/selfhost.yml'
$environmentFile = Join-Path $root '.discorda/selfhost/compose.env'
if (!(Test-Path -LiteralPath $environmentFile)) { throw 'Execute tools/setup-selfhost.ps1 primeiro.' }
& (Join-Path $PSScriptRoot 'harden-database.ps1')
$nativeConfig = Join-Path $root '.discorda/selfhost/livekit-native.yaml'
if (Test-Path -LiteralPath $nativeConfig) {
    $nativeExe = Join-Path $root 'artifacts/media-lab/server/livekit-server.exe'
    if (!(Test-Path -LiteralPath $nativeExe)) { throw 'LiveKit nativo ausente. Execute tools/media-lab/setup-windows.ps1.' }
    $settings = Get-Content -LiteralPath (Join-Path $root '.discorda/selfhost/settings.json') -Raw | ConvertFrom-Json
    if ($settings.LiveKit.InternalUrl -ne 'http://host.docker.internal:7880' -or
        $settings.ReverseProxy.Clusters.livekit.Destinations.local.Address -ne 'http://host.docker.internal:7880/') {
        throw 'Configuração da API não aponta para o LiveKit nativo. Revise settings.json antes de iniciar.'
    }
    docker compose --env-file $environmentFile -f $compose stop livekit
    if ($LASTEXITCODE -ne 0) { throw 'Não foi possível parar o LiveKit Docker.' }
    docker update --restart=no discorda-home-livekit-1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Não foi possível impedir o reinício automático do LiveKit Docker.' }
    $nativeProcess = @(Get-CimInstance Win32_Process -Filter "Name='livekit-server.exe'" |
        Where-Object { $_.ExecutablePath -eq $nativeExe -and $_.CommandLine -and $_.CommandLine.Contains($nativeConfig) })
    if ($nativeProcess.Count -eq 0) {
        $privateDirectory = Split-Path $nativeConfig -Parent
        Start-Process -FilePath $nativeExe -ArgumentList "--config `"$nativeConfig`"" -WorkingDirectory $privateDirectory -WindowStyle Hidden -RedirectStandardOutput (Join-Path $privateDirectory 'livekit-native-out.log') -RedirectStandardError (Join-Path $privateDirectory 'livekit-native-error.log')
    }
    $mediaReady = $false
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        try { if ((Invoke-WebRequest 'http://127.0.0.1:7880/' -TimeoutSec 2).StatusCode -eq 200) { $mediaReady = $true; break } } catch { }
        Start-Sleep -Seconds 2
    }
    if (!$mediaReady) { throw 'LiveKit nativo não iniciou. Consulte .discorda/selfhost/livekit-native-error.log.' }
    docker compose --env-file $environmentFile -f $compose up -d --wait postgres
    if ($LASTEXITCODE -ne 0) { throw 'Não foi possível iniciar o banco.' }
    docker compose --env-file $environmentFile -f $compose build api
    if ($LASTEXITCODE -ne 0) { throw 'Não foi possível compilar a API.' }
    docker compose --env-file $environmentFile -f $compose run --rm --no-deps migrate
    if ($LASTEXITCODE -ne 0) { throw 'Não foi possível aplicar as migrations.' }
    docker compose --env-file $environmentFile -f $compose up -d --no-deps api
    if ($LASTEXITCODE -ne 0) { throw 'Não foi possível iniciar a API.' }
} else {
    docker compose --env-file $environmentFile -f $compose up -d --build
    if ($LASTEXITCODE -ne 0) { throw 'Não foi possível iniciar o servidor. Consulte docker compose logs (instruções no README).' }
}
$ready = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    try { $response = Invoke-WebRequest 'http://localhost:18080/health/ready' -TimeoutSec 3; if ($response.StatusCode -eq 200) { $ready = $true; break } } catch { }
    Start-Sleep -Seconds 2
}
if (!$ready) { throw 'Os containers iniciaram, mas a API ainda não está pronta. Consulte os logs antes de convidar amigos.' }
Write-Output 'Servidor pronto. Painel: http://localhost:18080/admin/index.html'
Write-Output 'Entre com Google, autorize os e-mails e gere a política de Firewall para os IPs Radmin dos amigos.'
Write-Output 'Antes de convidar amigos, execute pwsh -File tools/check-selfhost.ps1 e teste uma chamada em dois computadores.'
