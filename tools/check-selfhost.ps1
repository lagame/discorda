#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$environmentFile = Join-Path $root '.discorda/selfhost/compose.env'
$compose = Join-Path $root 'infra/compose/selfhost.yml'
$nativeConfig = Join-Path $root '.discorda/selfhost/livekit-native.yaml'
$nativeMode = Test-Path -LiteralPath $nativeConfig
$failed = $false

function Report([string]$status, [string]$message) {
    Write-Output "[$status] $message"
    if ($status -eq 'FALHA') { $script:failed = $true }
}

function Test-PortMatch($ports, [int]$target) {
    foreach ($port in @($ports)) {
        if ($port -eq 'Any' -or $port -eq [string]$target) { return $true }
        if ($port -match '^(\d+)-(\d+)$' -and $target -ge [int]$Matches[1] -and $target -le [int]$Matches[2]) { return $true }
    }
    return $false
}

if (!(Test-Path -LiteralPath $environmentFile)) {
    Report 'FALHA' 'Configuração ausente. Execute tools/setup-selfhost.ps1.'
    exit 1
}
$hostIp = ((Get-Content -LiteralPath $environmentFile | Where-Object { $_ -match '^DISCORDA_HOST_IP=' } | Select-Object -First 1) -split '=', 2)[1]
$parsed = $null
if (![Net.IPAddress]::TryParse($hostIp, [ref]$parsed) -or $parsed.GetAddressBytes()[0] -ne 26) {
    Report 'FALHA' 'IP do servidor inválido em .discorda/selfhost/compose.env.'
    exit 1
}
$radminIp = @(Get-NetIPAddress -InterfaceAlias 'Radmin VPN' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $hostIp })
if ($radminIp.Count -eq 1) { Report 'OK' 'IP do servidor pertence à interface Radmin VPN.' }
else { Report 'FALHA' 'IP configurado não está na interface Radmin VPN deste computador.' }

if (!(Get-Command docker -ErrorAction SilentlyContinue)) {
    Report 'FALHA' 'Docker não instalado. Instale Docker Desktop com Linux containers.'
    exit 1
}
docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Report 'FALHA' 'Docker indisponível. Inicie o Docker Desktop com Linux containers.'
    exit 1
}
$running = @(docker compose --env-file $environmentFile -f $compose ps --services --status running 2>$null)
if ($LASTEXITCODE -ne 0) {
    Report 'FALHA' 'Não foi possível consultar os serviços Docker do Discorda.'
} else {
    $services = if ($nativeMode) { @('postgres', 'api') } else { @('postgres', 'livekit', 'api') }
    foreach ($service in $services) {
        if ($running -contains $service) { Report 'OK' "Serviço $service ativo." }
        else { Report 'FALHA' "Serviço $service parado. Execute tools/start-selfhost.ps1 e consulte os logs." }
    }
}

try {
    $response = Invoke-WebRequest 'http://localhost:18080/health/ready' -UseBasicParsing -TimeoutSec 5
    if ($response.StatusCode -eq 200) { Report 'OK' 'API e banco respondem.' }
    else { Report 'FALHA' 'API ou banco não estão prontos.' }
} catch { Report 'FALHA' 'API ou banco não estão prontos.' }

if ($nativeMode) {
    $nativeExe = Join-Path $root 'artifacts/media-lab/server/livekit-server.exe'
    $nativeProcess = @(Get-CimInstance Win32_Process -Filter "Name='livekit-server.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $nativeExe -and $_.CommandLine -and $_.CommandLine.Contains($nativeConfig) })
    if ($nativeProcess.Count -eq 1) {
        Report 'OK' 'LiveKit nativo ativo.'
        $pidValue = $nativeProcess[0].ProcessId
        $tcp = @(Get-NetTCPConnection -LocalPort 7881 -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -eq $pidValue })
        $udp = @(Get-NetUDPEndpoint -LocalPort 7882 -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -eq $pidValue -and $_.LocalAddress -eq $hostIp })
        if ($tcp.Count) { Report 'OK' 'LiveKit nativo escuta TCP 7881.' }
        else { Report 'FALHA' 'LiveKit nativo não escuta TCP 7881.' }
        if ($udp.Count) { Report 'OK' 'LiveKit nativo escuta UDP 7882 no IP Radmin.' }
        else { Report 'FALHA' 'LiveKit nativo não escuta UDP 7882 no IP Radmin.' }
    } else { Report 'FALHA' 'LiveKit nativo não está ativo. Execute tools/start-selfhost.ps1.' }
} else {
    foreach ($entry in @(@{ Port = '7881/tcp'; Label = 'TCP 7881' }, @{ Port = '7882/udp'; Label = 'UDP 7882' })) {
        $binding = @(docker port discorda-home-livekit-1 $entry.Port 2>$null)
        if ($LASTEXITCODE -eq 0 -and $binding -contains "${hostIp}:$($entry.Port.Split('/')[0])") {
            Report 'OK' "LiveKit publica $($entry.Label) no IP Radmin."
        } else { Report 'FALHA' "LiveKit não publica $($entry.Label) no IP Radmin." }
    }
}

$profile = Get-NetConnectionProfile -InterfaceAlias 'Radmin VPN' -ErrorAction SilentlyContinue
$dockerPaths = @(Get-CimInstance Win32_Process -Filter "Name='com.docker.backend.exe'" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty ExecutablePath -Unique)
$programPaths = @(if ($nativeMode) { $nativeExe } else { $dockerPaths })
$programLabel = if ($nativeMode) { 'LiveKit nativo' } else { 'Docker' }
if ($profile -and $programPaths.Count -eq 1) {
    $programRules = @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -Program $programPaths[0] -ErrorAction SilentlyContinue |
        Get-NetFirewallRule | Where-Object {
            $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and
            ($_.Profile.ToString() -eq 'Any' -or
                @($_.Profile.ToString().Split(',').Trim()) -contains [string]$profile.NetworkCategory)
        })
    $blocks = @($programRules | Where-Object { $_.Action -eq 'Block' })
    $ports = @(@{ Protocol = 'TCP'; Port = 7881 }, @{ Protocol = 'UDP'; Port = 7882 })
    if (!$nativeMode) { $ports += @{ Protocol = 'TCP'; Port = 7443 } }
    foreach ($entry in $ports) {
        $conflict = @($blocks | Where-Object {
            $filter = $_ | Get-NetFirewallPortFilter
            $filter.Protocol -eq $entry.Protocol -and (Test-PortMatch $filter.LocalPort $entry.Port)
        })
        if ($conflict.Count) {
            $status = if ($nativeMode) { 'FALHA' } else { 'AVISO' }
            Report $status "Regra de bloqueio do $programLabel em $($entry.Protocol) $($entry.Port) no perfil $($profile.NetworkCategory). Confirme a conexão em outro computador."
        } else {
            Report 'OK' "Nenhum bloqueio explícito do $programLabel encontrado em $($entry.Protocol) $($entry.Port)."
        }
    }
    if ($nativeMode) {
        $broadAllows = @($programRules | Where-Object {
            if ($_.Action -ne 'Allow') { return $false }
            $port = $_ | Get-NetFirewallPortFilter
            $address = $_ | Get-NetFirewallAddressFilter
            $port.LocalPort -eq 'Any' -and $address.RemoteAddress -eq 'Any'
        })
        if ($broadAllows.Count) {
            Report 'FALHA' 'Firewall permite LiveKit nativo de qualquer IP/porta. Restrinja as regras automáticas antes de convidar amigos.'
        }
    }
} else {
    Report 'AVISO' "Não foi possível verificar regras do $programLabel no Firewall. Confira-as manualmente."
}
if ($nativeMode -and $profile -and $dockerPaths.Count -eq 1) {
    $dockerBlocks = @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -Program $dockerPaths[0] -ErrorAction SilentlyContinue |
        Get-NetFirewallRule | Where-Object {
            $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Block' -and
            ($_.Profile.ToString() -eq 'Any' -or
                @($_.Profile.ToString().Split(',').Trim()) -contains [string]$profile.NetworkCategory)
        })
    $apiBlock = @($dockerBlocks | Where-Object {
        $filter = $_ | Get-NetFirewallPortFilter
        $filter.Protocol -eq 'TCP' -and (Test-PortMatch $filter.LocalPort 7443)
    })
    if ($apiBlock.Count) {
        Report 'AVISO' 'Existe bloqueio do Docker em TCP 7443 no perfil Radmin. Confirme o acesso em outro computador; essa regra pode não afetar o encaminhamento da API.'
    } else { Report 'OK' 'Nenhum bloqueio explícito do Docker em TCP 7443.' }
}

Report 'AVISO' 'Login Google e mídia ainda exigem teste real com duas contas em computadores distintos.'
if ($failed) { exit 1 }
