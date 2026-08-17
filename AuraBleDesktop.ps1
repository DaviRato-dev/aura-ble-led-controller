Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:LedServiceUuid = "0000ffe0-0000-1000-8000-00805f9b34fb"
$script:LedCharacteristicUuid = "0000ffe1-0000-1000-8000-00805f9b34fb"
$script:DiscoveredDevices = @()
$script:BleDevice = $null
$script:BleService = $null
$script:BleCharacteristic = $null
$script:IsOn = $false
$script:CurrentColor = [System.Drawing.Color]::FromArgb(255, 90, 95)

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

function Write-Log {
  param([string]$Message)

  $timestamp = Get-Date -Format "HH:mm:ss"
  $logTextBox.AppendText("[$timestamp] $Message`r`n")
  $logTextBox.SelectionStart = $logTextBox.TextLength
  $logTextBox.ScrollToCaret()
}

function Set-Status {
  param(
    [string]$Text,
    [System.Drawing.Color]$Color
  )

  $statusValueLabel.Text = $Text
  $statusValueLabel.ForeColor = $Color
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
      Id = $device.Id
      Name = $device.Name
    }
  }

  return $matches
}

function Disconnect-LedDevice {
  foreach ($item in @($script:BleCharacteristic, $script:BleService, $script:BleDevice)) {
    if ($item) {
      try {
        $item.Dispose()
      } catch {
      }
    }
  }

  $script:BleCharacteristic = $null
  $script:BleService = $null
  $script:BleDevice = $null
  $script:IsOn = $false
}

function Connect-LedDevice {
  param([Parameter(Mandatory = $true)][string]$DeviceId)

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
    throw "O servico FFE0 nao foi encontrado."
  }

  $characteristicResult = Await ($service.GetCharacteristicsAsync($cacheMode)) ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicsResult, Windows.Devices.Bluetooth, ContentType=WindowsRuntime])

  if ($characteristicResult.Status.ToString() -ne "Success") {
    throw "Falha ao abrir as caracteristicas da fita: $($characteristicResult.Status)."
  }

  $characteristic = $characteristicResult.Characteristics |
    Where-Object { $_.Uuid.ToString().ToLowerInvariant() -eq $script:LedCharacteristicUuid } |
    Select-Object -First 1

  if (-not $characteristic) {
    throw "A caracteristica FFE1 nao foi encontrada."
  }

  $script:BleDevice = $device
  $script:BleService = $service
  $script:BleCharacteristic = $characteristic
}

function Send-LedPacket {
  param(
    [Parameter(Mandatory = $true)][byte[]]$Bytes,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not $script:BleCharacteristic) {
    throw "Conecte a fita antes de enviar comandos."
  }

  $writer = [Windows.Storage.Streams.DataWriter, Windows.Storage.Streams, ContentType=WindowsRuntime]::new()
  $writer.WriteBytes($Bytes)
  $buffer = $writer.DetachBuffer()
  $writer.Dispose()

  $signature = [Type[]]@(
    [Windows.Storage.Streams.IBuffer, Windows.Storage.Streams, ContentType=WindowsRuntime],
    [Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteOption, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
  )

  $method = $script:BleCharacteristic.GetType().GetMethod("WriteValueAsync", $signature)
  $writeOption = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteOption, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]::WriteWithoutResponse
  $writeOp = $method.Invoke($script:BleCharacteristic, @($buffer, $writeOption))
  $status = Await $writeOp ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCommunicationStatus, Windows.Devices.Bluetooth, ContentType=WindowsRuntime])

  if ($status.ToString() -ne "Success") {
    throw "Falha ao enviar comando: $status."
  }

  $lastActionValueLabel.Text = $Label
  Write-Log("$Label -> " + (($Bytes | ForEach-Object { $_.ToString("X2") }) -join " "))
}

function Get-HexColor {
  param([System.Drawing.Color]$Color)

  return "#{0:X2}{1:X2}{2:X2}" -f $Color.R, $Color.G, $Color.B
}

function Turn-On {
  Send-LedPacket -Bytes ([byte[]](0x7E, 0xFF, 0x04, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF)) -Label "Ligar"
  $script:IsOn = $true
}

function Turn-Off {
  Send-LedPacket -Bytes ([byte[]](0x7E, 0xFF, 0x04, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF)) -Label "Desligar"
  $script:IsOn = $false
}

function Apply-Color {
  param([System.Drawing.Color]$Color)

  if (-not $script:IsOn) {
    Turn-On
  }

  $script:CurrentColor = $Color
  $colorPreview.BackColor = $Color
  $colorValueLabel.Text = Get-HexColor -Color $Color
  Send-LedPacket -Bytes ([byte[]](0x7E, 0xFF, 0x05, 0x03, $Color.R, $Color.G, $Color.B, 0xFF, 0xEF)) -Label ("Cor " + (Get-HexColor -Color $Color))
}

function Apply-Brightness {
  $value = [byte]$brightnessTrackBar.Value
  $brightnessValueLabel.Text = "$value%"
  Send-LedPacket -Bytes ([byte[]](0x7E, 0xFF, 0x01, $value, 0x00, 0xFF, 0xFF, 0xFF, 0xEF)) -Label "Brilho $value%"
}

function Apply-Speed {
  $value = [byte]$speedTrackBar.Value
  $speedValueLabel.Text = "$value%"
  Send-LedPacket -Bytes ([byte[]](0x7E, 0xFF, 0x02, $value, 0x00, 0xFF, 0xFF, 0xFF, 0xEF)) -Label "Velocidade $value%"
}

function Apply-Effect {
  if ($effectComboBox.SelectedIndex -lt 0) {
    throw "Escolha um efeito antes de aplicar."
  }

  if (-not $script:IsOn) {
    Turn-On
  }

  $effectCode = [byte](0x87 + $effectComboBox.SelectedIndex)
  Send-LedPacket -Bytes ([byte[]](0x7E, 0xFF, 0x03, $effectCode, 0x03, 0xFF, 0xFF, 0xFF, 0xEF)) -Label ("Efeito 0x" + $effectCode.ToString("X2"))
  Apply-Speed
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Aura BLE Desktop"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(760, 720)
$form.MinimumSize = New-Object System.Drawing.Size(760, 720)
$form.BackColor = [System.Drawing.Color]::FromArgb(14, 22, 34)
$form.ForeColor = [System.Drawing.Color]::White

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Aura BLE Desktop"
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(24, 20)
$titleLabel.Size = New-Object System.Drawing.Size(320, 40)
$form.Controls.Add($titleLabel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Status:"
$statusLabel.Location = New-Object System.Drawing.Point(28, 70)
$statusLabel.Size = New-Object System.Drawing.Size(60, 22)
$form.Controls.Add($statusLabel)

$statusValueLabel = New-Object System.Windows.Forms.Label
$statusValueLabel.Text = "Desconectado"
$statusValueLabel.ForeColor = [System.Drawing.Color]::LightSalmon
$statusValueLabel.Location = New-Object System.Drawing.Point(90, 70)
$statusValueLabel.Size = New-Object System.Drawing.Size(220, 22)
$form.Controls.Add($statusValueLabel)

$devicePrefixLabel = New-Object System.Windows.Forms.Label
$devicePrefixLabel.Text = "Prefixo do nome:"
$devicePrefixLabel.Location = New-Object System.Drawing.Point(28, 110)
$devicePrefixLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($devicePrefixLabel)

$devicePrefixTextBox = New-Object System.Windows.Forms.TextBox
$devicePrefixTextBox.Text = "LEDBLE-01"
$devicePrefixTextBox.Location = New-Object System.Drawing.Point(150, 108)
$devicePrefixTextBox.Size = New-Object System.Drawing.Size(160, 24)
$form.Controls.Add($devicePrefixTextBox)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "Buscar fitas"
$refreshButton.Location = New-Object System.Drawing.Point(330, 105)
$refreshButton.Size = New-Object System.Drawing.Size(110, 30)
$form.Controls.Add($refreshButton)

$deviceComboBox = New-Object System.Windows.Forms.ComboBox
$deviceComboBox.DropDownStyle = "DropDownList"
$deviceComboBox.Location = New-Object System.Drawing.Point(28, 150)
$deviceComboBox.Size = New-Object System.Drawing.Size(412, 26)
$form.Controls.Add($deviceComboBox)

$connectButton = New-Object System.Windows.Forms.Button
$connectButton.Text = "Conectar"
$connectButton.Location = New-Object System.Drawing.Point(460, 105)
$connectButton.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($connectButton)

$disconnectButton = New-Object System.Windows.Forms.Button
$disconnectButton.Text = "Desconectar"
$disconnectButton.Location = New-Object System.Drawing.Point(596, 105)
$disconnectButton.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($disconnectButton)

$deviceNameLabel = New-Object System.Windows.Forms.Label
$deviceNameLabel.Text = "Dispositivo atual: nenhum"
$deviceNameLabel.Location = New-Object System.Drawing.Point(28, 188)
$deviceNameLabel.Size = New-Object System.Drawing.Size(420, 22)
$form.Controls.Add($deviceNameLabel)

$powerOnButton = New-Object System.Windows.Forms.Button
$powerOnButton.Text = "Ligar"
$powerOnButton.Location = New-Object System.Drawing.Point(28, 230)
$powerOnButton.Size = New-Object System.Drawing.Size(100, 36)
$form.Controls.Add($powerOnButton)

$powerOffButton = New-Object System.Windows.Forms.Button
$powerOffButton.Text = "Desligar"
$powerOffButton.Location = New-Object System.Drawing.Point(142, 230)
$powerOffButton.Size = New-Object System.Drawing.Size(100, 36)
$form.Controls.Add($powerOffButton)

$chooseColorButton = New-Object System.Windows.Forms.Button
$chooseColorButton.Text = "Escolher cor"
$chooseColorButton.Location = New-Object System.Drawing.Point(260, 230)
$chooseColorButton.Size = New-Object System.Drawing.Size(120, 36)
$form.Controls.Add($chooseColorButton)

$colorPreview = New-Object System.Windows.Forms.Panel
$colorPreview.Location = New-Object System.Drawing.Point(398, 230)
$colorPreview.Size = New-Object System.Drawing.Size(36, 36)
$colorPreview.BackColor = $script:CurrentColor
$form.Controls.Add($colorPreview)

$colorValueLabel = New-Object System.Windows.Forms.Label
$colorValueLabel.Text = Get-HexColor -Color $script:CurrentColor
$colorValueLabel.Location = New-Object System.Drawing.Point(446, 238)
$colorValueLabel.Size = New-Object System.Drawing.Size(100, 22)
$form.Controls.Add($colorValueLabel)

$brightnessLabel = New-Object System.Windows.Forms.Label
$brightnessLabel.Text = "Brilho"
$brightnessLabel.Location = New-Object System.Drawing.Point(28, 292)
$brightnessLabel.Size = New-Object System.Drawing.Size(60, 22)
$form.Controls.Add($brightnessLabel)

$brightnessTrackBar = New-Object System.Windows.Forms.TrackBar
$brightnessTrackBar.Location = New-Object System.Drawing.Point(28, 320)
$brightnessTrackBar.Size = New-Object System.Drawing.Size(340, 45)
$brightnessTrackBar.Minimum = 0
$brightnessTrackBar.Maximum = 100
$brightnessTrackBar.TickFrequency = 10
$brightnessTrackBar.Value = 100
$form.Controls.Add($brightnessTrackBar)

$brightnessValueLabel = New-Object System.Windows.Forms.Label
$brightnessValueLabel.Text = "100%"
$brightnessValueLabel.Location = New-Object System.Drawing.Point(380, 320)
$brightnessValueLabel.Size = New-Object System.Drawing.Size(50, 22)
$form.Controls.Add($brightnessValueLabel)

$applyBrightnessButton = New-Object System.Windows.Forms.Button
$applyBrightnessButton.Text = "Aplicar brilho"
$applyBrightnessButton.Location = New-Object System.Drawing.Point(446, 314)
$applyBrightnessButton.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($applyBrightnessButton)

$speedLabel = New-Object System.Windows.Forms.Label
$speedLabel.Text = "Velocidade"
$speedLabel.Location = New-Object System.Drawing.Point(28, 372)
$speedLabel.Size = New-Object System.Drawing.Size(90, 22)
$form.Controls.Add($speedLabel)

$speedTrackBar = New-Object System.Windows.Forms.TrackBar
$speedTrackBar.Location = New-Object System.Drawing.Point(28, 400)
$speedTrackBar.Size = New-Object System.Drawing.Size(340, 45)
$speedTrackBar.Minimum = 0
$speedTrackBar.Maximum = 100
$speedTrackBar.TickFrequency = 10
$speedTrackBar.Value = 65
$form.Controls.Add($speedTrackBar)

$speedValueLabel = New-Object System.Windows.Forms.Label
$speedValueLabel.Text = "65%"
$speedValueLabel.Location = New-Object System.Drawing.Point(380, 400)
$speedValueLabel.Size = New-Object System.Drawing.Size(50, 22)
$form.Controls.Add($speedValueLabel)

$applySpeedButton = New-Object System.Windows.Forms.Button
$applySpeedButton.Text = "Aplicar velocidade"
$applySpeedButton.Location = New-Object System.Drawing.Point(446, 394)
$applySpeedButton.Size = New-Object System.Drawing.Size(140, 32)
$form.Controls.Add($applySpeedButton)

$effectLabel = New-Object System.Windows.Forms.Label
$effectLabel.Text = "Efeitos"
$effectLabel.Location = New-Object System.Drawing.Point(28, 456)
$effectLabel.Size = New-Object System.Drawing.Size(60, 22)
$form.Controls.Add($effectLabel)

$effectComboBox = New-Object System.Windows.Forms.ComboBox
$effectComboBox.DropDownStyle = "DropDownList"
$effectComboBox.Location = New-Object System.Drawing.Point(28, 486)
$effectComboBox.Size = New-Object System.Drawing.Size(340, 26)
for ($i = 0; $i -lt 23; $i++) {
  [void]$effectComboBox.Items.Add(("Efeito {0} (0x{1})" -f ($i + 1), (0x87 + $i).ToString("X2")))
}
$effectComboBox.SelectedIndex = 0
$form.Controls.Add($effectComboBox)

$applyEffectButton = New-Object System.Windows.Forms.Button
$applyEffectButton.Text = "Aplicar efeito"
$applyEffectButton.Location = New-Object System.Drawing.Point(388, 482)
$applyEffectButton.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($applyEffectButton)

$lastActionLabel = New-Object System.Windows.Forms.Label
$lastActionLabel.Text = "Ultimo comando:"
$lastActionLabel.Location = New-Object System.Drawing.Point(28, 534)
$lastActionLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($lastActionLabel)

$lastActionValueLabel = New-Object System.Windows.Forms.Label
$lastActionValueLabel.Text = "Nenhum"
$lastActionValueLabel.Location = New-Object System.Drawing.Point(150, 534)
$lastActionValueLabel.Size = New-Object System.Drawing.Size(220, 22)
$form.Controls.Add($lastActionValueLabel)

$logTextBox = New-Object System.Windows.Forms.TextBox
$logTextBox.Location = New-Object System.Drawing.Point(28, 570)
$logTextBox.Size = New-Object System.Drawing.Size(688, 96)
$logTextBox.Multiline = $true
$logTextBox.ReadOnly = $true
$logTextBox.ScrollBars = "Vertical"
$logTextBox.BackColor = [System.Drawing.Color]::FromArgb(8, 14, 20)
$logTextBox.ForeColor = [System.Drawing.Color]::LightCyan
$form.Controls.Add($logTextBox)

$colorDialog = New-Object System.Windows.Forms.ColorDialog
$colorDialog.FullOpen = $true
$colorDialog.Color = $script:CurrentColor

function Refresh-DeviceList {
  try {
    $script:DiscoveredDevices = Find-LedDevices -Prefix $devicePrefixTextBox.Text.Trim()
    $deviceComboBox.Items.Clear()

    foreach ($device in $script:DiscoveredDevices) {
      [void]$deviceComboBox.Items.Add($device.Name)
    }

    if ($deviceComboBox.Items.Count -gt 0) {
      $deviceComboBox.SelectedIndex = 0
      Write-Log("Foram encontradas $($deviceComboBox.Items.Count) fitas compativeis.")
    } else {
      Write-Log("Nenhuma fita compativel apareceu. Desligue o Bluetooth do celular e energize a fita novamente.")
    }
  } catch {
    Write-Log("Falha ao buscar fitas: $($_.Exception.Message)")
  }
}

$refreshButton.Add_Click({
  Refresh-DeviceList
})

$connectButton.Add_Click({
  try {
    if ($deviceComboBox.SelectedIndex -lt 0) {
      throw "Busque a fita e selecione um item da lista antes de conectar."
    }

    $device = $script:DiscoveredDevices[$deviceComboBox.SelectedIndex]
    Set-Status -Text "Conectando..." -Color ([System.Drawing.Color]::Khaki)
    Connect-LedDevice -DeviceId $device.Id
    $deviceNameLabel.Text = "Dispositivo atual: $($script:BleDevice.Name)"
    Set-Status -Text "Conectado" -Color ([System.Drawing.Color]::MediumSpringGreen)
    Write-Log("Conectado com $($script:BleDevice.Name).")
  } catch {
    Set-Status -Text "Falha na conexao" -Color ([System.Drawing.Color]::LightSalmon)
    Write-Log("Falha ao conectar: $($_.Exception.Message)")
  }
})

$disconnectButton.Add_Click({
  Disconnect-LedDevice
  $deviceNameLabel.Text = "Dispositivo atual: nenhum"
  Set-Status -Text "Desconectado" -Color ([System.Drawing.Color]::LightSalmon)
  Write-Log("Conexao encerrada.")
})

$powerOnButton.Add_Click({
  try {
    Turn-On
  } catch {
    Write-Log("Falha ao ligar: $($_.Exception.Message)")
  }
})

$powerOffButton.Add_Click({
  try {
    Turn-Off
  } catch {
    Write-Log("Falha ao desligar: $($_.Exception.Message)")
  }
})

$chooseColorButton.Add_Click({
  if ($colorDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    try {
      Apply-Color -Color $colorDialog.Color
    } catch {
      Write-Log("Falha ao aplicar cor: $($_.Exception.Message)")
    }
  }
})

$applyBrightnessButton.Add_Click({
  try {
    Apply-Brightness
  } catch {
    Write-Log("Falha ao ajustar brilho: $($_.Exception.Message)")
  }
})

$applySpeedButton.Add_Click({
  try {
    Apply-Speed
  } catch {
    Write-Log("Falha ao ajustar velocidade: $($_.Exception.Message)")
  }
})

$applyEffectButton.Add_Click({
  try {
    Apply-Effect
  } catch {
    Write-Log("Falha ao aplicar efeito: $($_.Exception.Message)")
  }
})

$brightnessTrackBar.Add_ValueChanged({
  $brightnessValueLabel.Text = "$($brightnessTrackBar.Value)%"
})

$speedTrackBar.Add_ValueChanged({
  $speedValueLabel.Text = "$($speedTrackBar.Value)%"
})

$form.Add_FormClosing({
  Disconnect-LedDevice
})

Write-Log("Pronto. Clique em 'Buscar fitas' para localizar a LEDBLE-01.")
Refresh-DeviceList
[void]$form.ShowDialog()
