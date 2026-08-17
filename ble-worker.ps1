param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("status", "connect", "disconnect", "send")]
  [string]$Action,
  [string]$BytesJson,
  [string]$DeviceId,
  [string]$NamePrefix = "LEDBLE-01"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$script:LedServiceUuid = "0000ffe0-0000-1000-8000-00805f9b34fb"
$script:LedCharacteristicUuid = "0000ffe1-0000-1000-8000-00805f9b34fb"
$script:StatePath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) ".aurable-device.json"

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

function Find-LedDevices {
  param([string]$Prefix = "LEDBLE-01")

  $selector = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]::GetDeviceSelectorFromPairingState($false)
  $findOp = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]::FindAllAsync($selector)
  $devices = Await $findOp ([Windows.Devices.Enumeration.DeviceInformationCollection, Windows.Devices.Enumeration, ContentType=WindowsRuntime])

  $matches = @()
  foreach ($device in $devices) {
    if ([string]::IsNullOrWhiteSpace($device.Name)) {
      continue
    }

    if ($Prefix -and -not $device.Name.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
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

function Load-SelectedDevice {
  if (-not (Test-Path $script:StatePath)) {
    return $null
  }

  return (Get-Content -Raw $script:StatePath) | ConvertFrom-Json
}

function Save-SelectedDevice {
  param([Parameter(Mandatory = $true)]$Device)

  $payload = [pscustomobject]@{
    id = $Device.id
    name = $Device.name
  }
  $payload | ConvertTo-Json -Compress | Set-Content -Path $script:StatePath -Encoding UTF8
}

function Clear-SelectedDevice {
  Remove-Item $script:StatePath -Force -ErrorAction SilentlyContinue
}

function Open-LedResources {
  param([Parameter(Mandatory = $true)][string]$TargetDeviceId)

  $deviceOp = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]::FromIdAsync($TargetDeviceId)
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

  return @{
    Characteristic = $characteristic
    Device = $device
    Name = $device.Name
    Service = $service
  }
}

function Close-LedResources {
  param($Resources)

  if (-not $Resources) {
    return
  }

  foreach ($key in @("Characteristic", "Service", "Device")) {
    if ($Resources[$key]) {
      try {
        $Resources[$key].Dispose()
      } catch {
      }
    }
  }
}

function Write-LedPacket {
  param(
    [Parameter(Mandatory = $true)]$Characteristic,
    [Parameter(Mandatory = $true)][byte[]]$Bytes
  )

  $writer = [Windows.Storage.Streams.DataWriter, Windows.Storage.Streams, ContentType=WindowsRuntime]::new()
  $writer.WriteBytes($Bytes)
  $buffer = $writer.DetachBuffer()
  $writer.Dispose()

  $signature = [Type[]]@(
    [Windows.Storage.Streams.IBuffer, Windows.Storage.Streams, ContentType=WindowsRuntime],
    [Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteOption, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
  )

  $method = $Characteristic.GetType().GetMethod("WriteValueAsync", $signature)
  $writeOption = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteOption, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]::WriteWithoutResponse
  $writeOp = $method.Invoke($Characteristic, @($buffer, $writeOption))
  $status = Await $writeOp ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCommunicationStatus, Windows.Devices.Bluetooth, ContentType=WindowsRuntime])

  if ($status.ToString() -ne "Success") {
    throw "Falha ao enviar comando para a fita: $status."
  }

  return $status.ToString()
}

function Resolve-TargetDevice {
  param(
    [string]$ExplicitDeviceId,
    [string]$Prefix = "LEDBLE-01"
  )

  if ($ExplicitDeviceId) {
    $devices = Find-LedDevices -Prefix $Prefix
    return $devices | Where-Object { $_.id -eq $ExplicitDeviceId } | Select-Object -First 1
  }

  $saved = Load-SelectedDevice
  if ($saved) {
    return [pscustomobject]@{
      id = $saved.id
      name = $saved.name
    }
  }

  return Find-LedDevices -Prefix $Prefix | Select-Object -First 1
}

try {
  switch ($Action) {
    "status" {
      $devices = Find-LedDevices -Prefix $NamePrefix
      $saved = Load-SelectedDevice
      [pscustomobject]@{
        backend = "windows-ble"
        connected = [bool]$saved
        device = $saved
        devices = $devices
        ok = $true
      } | ConvertTo-Json -Depth 8 -Compress
      break
    }

    "connect" {
      $target = Resolve-TargetDevice -ExplicitDeviceId $DeviceId -Prefix $NamePrefix
      if (-not $target) {
        throw "Nenhuma fita LED compativel foi encontrada. Deixe a fita ligada e desconecte o celular dela."
      }

      $resources = $null
      try {
        $resources = Open-LedResources -TargetDeviceId $target.id
        $device = [pscustomobject]@{
          id = $target.id
          name = $resources.Name
        }
        Save-SelectedDevice -Device $device

        [pscustomobject]@{
          connected = $true
          device = $device
          ok = $true
        } | ConvertTo-Json -Depth 8 -Compress
      } finally {
        Close-LedResources -Resources $resources
      }
      break
    }

    "disconnect" {
      Clear-SelectedDevice
      [pscustomobject]@{
        connected = $false
        ok = $true
      } | ConvertTo-Json -Depth 8 -Compress
      break
    }

    "send" {
      $target = Resolve-TargetDevice -ExplicitDeviceId $DeviceId -Prefix $NamePrefix
      if (-not $target) {
        throw "Nenhuma fita LED foi selecionada para envio."
      }

      if ([string]::IsNullOrWhiteSpace($BytesJson)) {
        throw "Nenhum pacote foi informado."
      }

      $rawBytes = $BytesJson | ConvertFrom-Json
      $byteList = [System.Collections.Generic.List[byte]]::new()
      foreach ($value in $rawBytes) {
        $byteList.Add([byte]$value)
      }

      $resources = $null
      try {
        $resources = Open-LedResources -TargetDeviceId $target.id
        $device = [pscustomobject]@{
          id = $target.id
          name = $resources.Name
        }
        Save-SelectedDevice -Device $device
        $status = Write-LedPacket -Characteristic $resources.Characteristic -Bytes $byteList.ToArray()

        [pscustomobject]@{
          ok = $true
          status = $status
        } | ConvertTo-Json -Depth 8 -Compress
      } finally {
        Close-LedResources -Resources $resources
      }
      break
    }
  }
} catch {
  [pscustomobject]@{
    error = $_.Exception.Message
    ok = $false
  } | ConvertTo-Json -Depth 8 -Compress
}
