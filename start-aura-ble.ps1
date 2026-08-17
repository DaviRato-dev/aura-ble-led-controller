param(
  [int[]]$PreferredPorts = @(8765, 8766, 3000, 5173)
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$script:BleState = @{
  Characteristic = $null
  Device = $null
  DeviceId = $null
  DeviceName = $null
  Service = $null
}

$script:LedServiceUuid = "0000ffe0-0000-1000-8000-00805f9b34fb"
$script:LedCharacteristicUuid = "0000ffe1-0000-1000-8000-00805f9b34fb"
$script:BleWorkerPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "ble-worker.ps1"

function Await {
  param(
    [Parameter(Mandatory = $true)]$Operation,
    [Parameter(Mandatory = $true)][Type]$ResultType
  )

  $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
      $_.Name -eq "AsTask" -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1
    } |
    Select-Object -First 1

  $generic = $method.MakeGenericMethod($ResultType)
  $task = $generic.Invoke($null, @($Operation))
  $task.Wait()
  return $task.Result
}

function Get-ContentType {
  param([string]$Path)

  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    ".html" { return "text/html; charset=utf-8" }
    ".css" { return "text/css; charset=utf-8" }
    ".js" { return "application/javascript; charset=utf-8" }
    ".json" { return "application/json; charset=utf-8" }
    ".png" { return "image/png" }
    ".jpg" { return "image/jpeg" }
    ".jpeg" { return "image/jpeg" }
    ".svg" { return "image/svg+xml" }
    ".ico" { return "image/x-icon" }
    default { return "application/octet-stream" }
  }
}

function Test-LocalPortOpen {
  param([int]$Port)

  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $asyncResult = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
    if (-not $asyncResult.AsyncWaitHandle.WaitOne(250)) {
      return $false
    }

    $client.EndConnect($asyncResult) | Out-Null
    return $true
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Write-Response {
  param(
    [Parameter(Mandatory = $true)]$Context,
    [int]$StatusCode,
    [string]$Body,
    [string]$ContentType = "text/plain; charset=utf-8"
  )

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $Context.Response.StatusCode = $StatusCode
  $Context.Response.ContentType = $ContentType
  $Context.Response.KeepAlive = $false
  $Context.Response.Close($bytes, $true)
}

function Write-JsonResponse {
  param(
    [Parameter(Mandatory = $true)]$Context,
    [int]$StatusCode,
    [Parameter(Mandatory = $true)]$Data
  )

  $json = $Data | ConvertTo-Json -Depth 8 -Compress
  Write-Response -Context $Context -StatusCode $StatusCode -Body $json -ContentType "application/json; charset=utf-8"
}

function Read-JsonBody {
  param([Parameter(Mandatory = $true)]$Context)

  if (-not $Context.Request.HasEntityBody) {
    return $null
  }

  $reader = [System.IO.StreamReader]::new(
    $Context.Request.InputStream,
    $Context.Request.ContentEncoding
  )

  try {
    $raw = $reader.ReadToEnd()
  } finally {
    $reader.Dispose()
  }

  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $null
  }

  return $raw | ConvertFrom-Json
}

function ConvertTo-ByteArray {
  param([Parameter(Mandatory = $true)]$InputBytes)

  $list = [System.Collections.Generic.List[byte]]::new()
  foreach ($value in $InputBytes) {
    $list.Add([byte]$value)
  }
  return $list.ToArray()
}

function Invoke-BleWorker {
  param(
    [Parameter(Mandatory = $true)][string]$Action,
    [string]$BytesJson,
    [string]$DeviceId,
    [string]$NamePrefix = "LEDBLE-01"
  )

  $arguments = @(
    "-NoProfile"
    "-ExecutionPolicy"
    "Bypass"
    "-File"
    $script:BleWorkerPath
    "-Action"
    $Action
    "-NamePrefix"
    $NamePrefix
  )

  if (-not [string]::IsNullOrWhiteSpace($DeviceId)) {
    $arguments += @("-DeviceId", $DeviceId)
  }

  if (-not [string]::IsNullOrWhiteSpace($BytesJson)) {
    $arguments += @("-BytesJson", $BytesJson)
  }

  $workerOutput = & powershell @arguments

  $raw = ($workerOutput | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "O worker BLE nao devolveu resposta."
  }

  $parsed = $raw | ConvertFrom-Json
  if (-not $parsed.ok) {
    throw [string]$parsed.error
  }

  return $parsed
}

function Get-LedDeviceSelector {
  return [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]::GetDeviceSelectorFromPairingState($false)
}

function Find-LedDevices {
  param([string]$NamePrefix = "LEDBLE-01")

  $selector = Get-LedDeviceSelector
  $findOp = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]::FindAllAsync($selector)
  $devices = Await $findOp ([Windows.Devices.Enumeration.DeviceInformationCollection, Windows.Devices.Enumeration, ContentType=WindowsRuntime])

  $matches = @()
  foreach ($device in $devices) {
    if ([string]::IsNullOrWhiteSpace($device.Name)) {
      continue
    }

    if ($NamePrefix -and -not $device.Name.StartsWith($NamePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      continue
    }

    $matches += [pscustomobject]@{
      id = $device.Id
      isEnabled = [bool]$device.IsEnabled
      isPaired = [bool]$device.Pairing.IsPaired
      name = $device.Name
    }
  }

  return $matches
}

function Disconnect-LedDevice {
  foreach ($key in @("Characteristic", "Service", "Device")) {
    $item = $script:BleState[$key]
    if ($item) {
      try {
        $item.Dispose()
      } catch {
      }
      $script:BleState[$key] = $null
    }
  }

  $script:BleState.DeviceId = $null
  $script:BleState.DeviceName = $null
}

function Connect-LedDevice {
  param(
    [string]$DeviceId,
    [string]$NamePrefix = "LEDBLE-01"
  )

  if (-not $DeviceId) {
    $DeviceId = (Find-LedDevices -NamePrefix $NamePrefix | Select-Object -First 1).id
  }

  if (-not $DeviceId) {
    throw "Nenhuma fita LED compativel foi encontrada. Deixe a fita ligada e desconecte o celular dela."
  }

  if ($script:BleState.DeviceId -eq $DeviceId -and $script:BleState.Characteristic) {
    return [pscustomobject]@{
      id = $script:BleState.DeviceId
      name = $script:BleState.DeviceName
    }
  }

  Disconnect-LedDevice

  $deviceOp = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]::FromIdAsync($DeviceId)
  $device = Await $deviceOp ([Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime])

  if (-not $device) {
    throw "O Windows encontrou a fita, mas nao conseguiu abrir a conexao BLE."
  }

  $cacheMode = [Windows.Devices.Bluetooth.BluetoothCacheMode, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]::Uncached
  $serviceResult = Await ($device.GetGattServicesAsync($cacheMode)) ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceServicesResult, Windows.Devices.Bluetooth, ContentType=WindowsRuntime])

  if ($serviceResult.Status.ToString() -ne "Success") {
    throw "Falha ao abrir os servicos GATT da fita: $($serviceResult.Status)."
  }

  $service = $serviceResult.Services |
    Where-Object { $_.Uuid.ToString().ToLowerInvariant() -eq $script:LedServiceUuid } |
    Select-Object -First 1

  if (-not $service) {
    throw "A fita foi encontrada, mas o servico FFE0 nao apareceu."
  }

  $characteristicResult = Await ($service.GetCharacteristicsAsync($cacheMode)) ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult, Windows.Devices.Bluetooth, ContentType=WindowsRuntime])

  if ($characteristicResult.Status.ToString() -ne "Success") {
    throw "Falha ao abrir as caracteristicas da fita: $($characteristicResult.Status)."
  }

  $characteristic = $characteristicResult.Characteristics |
    Where-Object { $_.Uuid.ToString().ToLowerInvariant() -eq $script:LedCharacteristicUuid } |
    Select-Object -First 1

  if (-not $characteristic) {
    throw "A fita foi encontrada, mas a caracteristica FFE1 nao apareceu."
  }

  $script:BleState.Device = $device
  $script:BleState.DeviceId = $DeviceId
  $script:BleState.DeviceName = $device.Name
  $script:BleState.Service = $service
  $script:BleState.Characteristic = $characteristic

  return [pscustomobject]@{
    id = $script:BleState.DeviceId
    name = $script:BleState.DeviceName
  }
}

function Ensure-LedConnection {
  if ($script:BleState.Characteristic) {
    return
  }

  if ($script:BleState.DeviceId) {
    Connect-LedDevice -DeviceId $script:BleState.DeviceId | Out-Null
    return
  }

  throw "Nenhuma fita LED conectada."
}

function Write-LedPacket {
  param([byte[]]$Bytes)

  Ensure-LedConnection

  $writer = [Windows.Storage.Streams.DataWriter, Windows.Storage.Streams, ContentType=WindowsRuntime]::new()
  $writer.WriteBytes($Bytes)
  $buffer = $writer.DetachBuffer()
  $writer.Dispose()

  $signature = [Type[]]@(
    [Windows.Storage.Streams.IBuffer, Windows.Storage.Streams, ContentType=WindowsRuntime],
    [Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteOption, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
  )

  $method = $script:BleState.Characteristic.GetType().GetMethod("WriteValueAsync", $signature)
  $writeOption = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteOption, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]::WriteWithoutResponse
  $writeOp = $method.Invoke($script:BleState.Characteristic, @($buffer, $writeOption))
  $status = Await $writeOp ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCommunicationStatus, Windows.Devices.Bluetooth, ContentType=WindowsRuntime])

  if ($status.ToString() -ne "Success") {
    throw "Falha ao enviar comando para a fita: $status."
  }

  return $status.ToString()
}

function Get-StatusPayload {
  $devices = Find-LedDevices -NamePrefix "LEDBLE-01"

  return [pscustomobject]@{
    backend = "windows-ble"
    connected = [bool]$script:BleState.Characteristic
    device = if ($script:BleState.DeviceId) {
      [pscustomobject]@{
        id = $script:BleState.DeviceId
        name = $script:BleState.DeviceName
      }
    } else {
      $null
    }
    devices = $devices
    ok = $true
  }
}

function Handle-ApiRequest {
  param(
    [Parameter(Mandatory = $true)]$Context,
    [Parameter(Mandatory = $true)][string]$RequestPath
  )

  $method = $Context.Request.HttpMethod.ToUpperInvariant()

  try {
    switch ("$method $RequestPath") {
      "GET api/status" {
        $status = Invoke-BleWorker -Action "status" -NamePrefix "LEDBLE-01"
        Write-JsonResponse -Context $Context -StatusCode 200 -Data $status
        return
      }
      "POST api/connect" {
        $body = Read-JsonBody -Context $Context
        $namePrefix = if ($body -and $body.namePrefix) { [string]$body.namePrefix } else { "LEDBLE-01" }
        $deviceId = if ($body -and $body.deviceId) { [string]$body.deviceId } else { $null }
        $response = Invoke-BleWorker -Action "connect" -NamePrefix $namePrefix -DeviceId $deviceId
        Write-JsonResponse -Context $Context -StatusCode 200 -Data $response
        return
      }
      "POST api/disconnect" {
        $response = Invoke-BleWorker -Action "disconnect" -NamePrefix "LEDBLE-01"
        Write-JsonResponse -Context $Context -StatusCode 200 -Data $response
        return
      }
      "POST api/send" {
        $body = Read-JsonBody -Context $Context
        if (-not $body -or -not $body.bytes) {
          throw "Nenhum pacote foi informado."
        }

        $deviceId = if ($body.deviceId) { [string]$body.deviceId } else { $null }
        $namePrefix = if ($body.namePrefix) { [string]$body.namePrefix } else { "LEDBLE-01" }
        $response = Invoke-BleWorker -Action "send" -NamePrefix $namePrefix -DeviceId $deviceId -BytesJson (($body.bytes | ConvertTo-Json -Compress))
        Write-JsonResponse -Context $Context -StatusCode 200 -Data $response
        return
      }
      default {
        Write-JsonResponse -Context $Context -StatusCode 404 -Data ([pscustomobject]@{
          error = "Rota nao encontrada."
          ok = $false
        })
        return
      }
    }
  } catch {
    Write-JsonResponse -Context $Context -StatusCode 500 -Data ([pscustomobject]@{
      error = $_.Exception.Message
      ok = $false
    })
  }
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootFull = [System.IO.Path]::GetFullPath($root)

$listener = $null
$baseUrl = $null
$usingExistingServer = $false

foreach ($port in $PreferredPorts) {
  $url = "http://127.0.0.1:$port/"

  if (Test-LocalPortOpen -Port $port) {
    $baseUrl = $url
    $usingExistingServer = $true
    break
  }

  try {
    $candidate = [System.Net.HttpListener]::new()
    $candidate.Prefixes.Add("http://127.0.0.1:$port/")
    $candidate.Prefixes.Add("http://localhost:$port/")
    $candidate.Start()
    $listener = $candidate
    $baseUrl = $url
    break
  } catch {
    if ($candidate) {
      $candidate.Close()
    }
  }
}

if (-not $baseUrl) {
  throw "Nao foi possivel iniciar o servidor local."
}

Write-Host ""
Write-Host "Aura BLE iniciado em $baseUrl" -ForegroundColor Cyan
Write-Host "Agora o painel usa o Bluetooth do Windows direto, sem seletor do navegador." -ForegroundColor Green
Write-Host "Deixe esta janela aberta enquanto usa o painel. Feche com Ctrl+C." -ForegroundColor DarkYellow
Write-Host ""

try {
  Start-Process $baseUrl | Out-Null
} catch {
  Write-Host "Nao consegui abrir o navegador automaticamente. Use: $baseUrl" -ForegroundColor Yellow
}

if ($usingExistingServer) {
  Write-Host "Um servidor Aura BLE ja estava ativo. Reaproveitando a instancia existente." -ForegroundColor Green
  return
}

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $requestPath = [Uri]::UnescapeDataString($context.Request.Url.AbsolutePath.TrimStart("/"))

    if ($requestPath.StartsWith("api/", [System.StringComparison]::OrdinalIgnoreCase)) {
      Handle-ApiRequest -Context $context -RequestPath $requestPath.ToLowerInvariant()
      continue
    }

    if ([string]::IsNullOrWhiteSpace($requestPath)) {
      $requestPath = "index.html"
    }

    $relativePath = $requestPath -replace "/", "\"
    $filePath = [System.IO.Path]::GetFullPath((Join-Path $rootFull $relativePath))

    if (-not $filePath.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      Write-Response -Context $context -StatusCode 403 -Body "Acesso negado."
      continue
    }

    if (-not [System.IO.File]::Exists($filePath)) {
      Write-Response -Context $context -StatusCode 404 -Body "Arquivo nao encontrado."
      continue
    }

    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    $context.Response.StatusCode = 200
    $context.Response.ContentType = Get-ContentType -Path $filePath
    $context.Response.AddHeader("Cache-Control", "no-store")
    $context.Response.KeepAlive = $false
    $context.Response.Close($bytes, $true)
  }
} finally {
  Disconnect-LedDevice

  if ($listener -and $listener.IsListening) {
    $listener.Stop()
  }
  if ($listener) {
    $listener.Close()
  }
}
