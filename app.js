const SERVICE_UUID = 0xffe0;
const SERVICE_UUID_FULL = "0000ffe0-0000-1000-8000-00805f9b34fb";
const CHARACTERISTIC_UUID = 0xffe1;
const CHARACTERISTIC_UUID_FULL = "0000ffe1-0000-1000-8000-00805f9b34fb";
const OPTIONAL_SERVICE_UUIDS = [SERVICE_UUID_FULL];
const STORAGE_KEY = "aurable-settings-v1";

const EFFECTS = Array.from({ length: 0x9d - 0x87 + 1 }, (_, index) => {
  const value = 0x87 + index;
  return {
    id: value,
    label: `Efeito ${index + 1} (0x${value.toString(16).toUpperCase()})`,
  };
});

const PRESET_COLORS = [
  { label: "Vermelho", value: "#ff4d4d" },
  { label: "Laranja", value: "#ff8a3d" },
  { label: "Amarelo", value: "#ffd166" },
  { label: "Verde", value: "#2ecc71" },
  { label: "Ciano", value: "#2fe1c5" },
  { label: "Azul", value: "#3a86ff" },
  { label: "Rosa", value: "#ff5aa5" },
  { label: "Branco", value: "#f4f6fb" },
];

const els = {
  applyColorButton: document.querySelector("#applyColorButton"),
  brightnessRange: document.querySelector("#brightnessRange"),
  brightnessStat: document.querySelector("#brightnessStat"),
  brightnessValue: document.querySelector("#brightnessValue"),
  browserSupportMessage: document.querySelector("#browserSupportMessage"),
  clearLogButton: document.querySelector("#clearLogButton"),
  colorInput: document.querySelector("#colorInput"),
  colorPreview: document.querySelector("#colorPreview"),
  connectButton: document.querySelector("#connectButton"),
  connectionBadge: document.querySelector("#connectionBadge"),
  deviceMeta: document.querySelector("#deviceMeta"),
  deviceName: document.querySelector("#deviceName"),
  disconnectButton: document.querySelector("#disconnectButton"),
  effectSelect: document.querySelector("#effectSelect"),
  lastActionPill: document.querySelector("#lastActionPill"),
  lastActionText: document.querySelector("#lastActionText"),
  logOutput: document.querySelector("#logOutput"),
  namePrefixInput: document.querySelector("#namePrefixInput"),
  powerOffButton: document.querySelector("#powerOffButton"),
  powerToggle: document.querySelector("#powerToggle"),
  presetGrid: document.querySelector("#presetGrid"),
  secureContextLabel: document.querySelector("#secureContextLabel"),
  signalChip: document.querySelector("#signalChip"),
  speedRange: document.querySelector("#speedRange"),
  speedStat: document.querySelector("#speedStat"),
  speedValue: document.querySelector("#speedValue"),
};

const state = {
  backendMode: "unknown",
  brightness: 100,
  characteristic: null,
  color: "#ff5a5f",
  connected: false,
  device: null,
  effectId: "",
  isOn: false,
  service: null,
  server: null,
  speed: 65,
  writeQueue: Promise.resolve(),
};

let brightnessTimer = null;
let speedTimer = null;

async function init() {
  populateEffects();
  restoreSettings();
  populatePresets();
  bindEvents();
  updateConnectionUI();
  updateRangeLabels();
  updateColorPreview();
  updatePowerButton();
  await detectBackendMode();
  updateBrowserSupportMessage();
  log("Pronto para conectar.", "system");
}

async function detectBackendMode() {
  const isLocalHost = ["localhost", "127.0.0.1"].includes(window.location.hostname);

  if (!isLocalHost) {
    state.backendMode = navigator.bluetooth ? "web" : "none";
    return;
  }

  try {
    const status = await apiRequest("/api/status", { method: "GET" });
    state.backendMode = "local";
    syncBackendStatus(status);
    log("Backend Windows BLE detectado no localhost.", "success");
  } catch (error) {
    state.backendMode = navigator.bluetooth ? "web" : "none";
    log(
      `Backend local nao respondeu, entao vou usar o modo do navegador: ${formatError(error)}`,
      "error"
    );
  }
}

function bindEvents() {
  els.connectButton.addEventListener("click", handleConnectClick);
  els.disconnectButton.addEventListener("click", disconnectFromDevice);
  els.powerToggle.addEventListener("click", handlePowerToggle);
  els.powerOffButton.addEventListener("click", async () => {
    await turnOff();
  });
  els.applyColorButton.addEventListener("click", async () => {
    await applyColor(els.colorInput.value);
  });
  els.colorInput.addEventListener("input", () => {
    state.color = els.colorInput.value;
    updateColorPreview();
    saveSettings();
  });
  els.colorInput.addEventListener("change", async () => {
    await applyColor(els.colorInput.value);
  });
  els.effectSelect.addEventListener("change", async (event) => {
    if (!event.target.value) {
      state.effectId = "";
      saveSettings();
      return;
    }

    const effectId = Number(event.target.value);
    if (!Number.isNaN(effectId)) {
      await sendEffect(effectId);
    }
  });
  els.brightnessRange.addEventListener("input", (event) => {
    state.brightness = Number(event.target.value);
    updateRangeLabels();
    saveSettings();
    window.clearTimeout(brightnessTimer);
    brightnessTimer = window.setTimeout(() => {
      void sendBrightness(state.brightness);
    }, 120);
  });
  els.speedRange.addEventListener("input", (event) => {
    state.speed = Number(event.target.value);
    updateRangeLabels();
    saveSettings();
    window.clearTimeout(speedTimer);
    speedTimer = window.setTimeout(() => {
      void sendSpeed(state.speed);
    }, 120);
  });
  els.clearLogButton.addEventListener("click", () => {
    els.logOutput.textContent = "[Aura BLE] Log limpo.";
  });
}

function populateEffects() {
  const fragment = document.createDocumentFragment();
  for (const effect of EFFECTS) {
    const option = document.createElement("option");
    option.value = String(effect.id);
    option.textContent = effect.label;
    fragment.appendChild(option);
  }
  els.effectSelect.appendChild(fragment);
}

function populatePresets() {
  const fragment = document.createDocumentFragment();
  for (const preset of PRESET_COLORS) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "preset-button";
    button.textContent = preset.label;
    button.style.background = `linear-gradient(135deg, ${preset.value}, ${lightenColor(
      preset.value,
      18
    )})`;
    button.addEventListener("click", async () => {
      els.colorInput.value = preset.value;
      await applyColor(preset.value);
    });
    fragment.appendChild(button);
  }
  els.presetGrid.appendChild(fragment);
}

function updateBrowserSupportMessage() {
  if (state.backendMode === "local") {
    els.browserSupportMessage.textContent =
      "Modo Windows BLE ativo. O painel conecta direto pela API Bluetooth do Windows, sem pareamento manual e sem a janela de busca do navegador.";
    els.secureContextLabel.textContent =
      "Servidor local ativo em localhost com backend Bluetooth nativo.";
    return;
  }

  const hasBluetooth = Boolean(navigator.bluetooth);
  const secure = window.isSecureContext;
  const isFileMode = window.location.protocol === "file:";

  if (hasBluetooth) {
    els.browserSupportMessage.textContent =
      isFileMode
        ? "O app pode abrir daqui, mas o modo mais confiavel e usar start-aura-ble.bat para rodar em localhost."
        : "Clique em buscar e escolha sua fita na janela do navegador. Se o celular estiver conectado nela, desligue o Bluetooth do celular antes.";
  } else {
    els.browserSupportMessage.textContent =
      "Este navegador nao expoe Web Bluetooth. Use start-aura-ble.bat para abrir o painel no navegador do sistema.";
  }

  els.secureContextLabel.textContent = secure
    ? "Contexto seguro ativo para Web Bluetooth."
    : "O navegador nao marcou esta pagina como contexto seguro.";
}

function updateRangeLabels() {
  els.brightnessValue.value = `${state.brightness}%`;
  els.speedValue.value = `${state.speed}%`;
  els.brightnessValue.textContent = `${state.brightness}%`;
  els.speedValue.textContent = `${state.speed}%`;
  els.brightnessStat.textContent = `${state.brightness}%`;
  els.speedStat.textContent = `${state.speed}%`;
}

function updateColorPreview() {
  const lighter = lightenColor(state.color, 28);
  const darker = darkenColor(state.color, 20);
  els.colorPreview.style.background = `
    radial-gradient(circle at top left, rgba(255, 255, 255, 0.82), transparent 28%),
    linear-gradient(145deg, ${lighter}, ${state.color} 55%, ${darker})
  `;
}

function updateStatus(message, tone = "idle") {
  els.connectionBadge.textContent = message;
  els.connectionBadge.className = `badge badge-${tone}`;
}

function updatePowerButton() {
  els.powerToggle.textContent = state.isOn ? "Fita ligada" : "Ligar fita";
  els.powerToggle.classList.toggle("is-on", state.isOn);
}

function updateConnectionUI() {
  const enabled = state.connected;
  els.disconnectButton.disabled = !enabled;
  els.powerToggle.disabled = !enabled;
  els.powerOffButton.disabled = !enabled;
  els.applyColorButton.disabled = !enabled;
  els.colorInput.disabled = !enabled;
  els.effectSelect.disabled = !enabled;
  els.brightnessRange.disabled = !enabled;
  els.speedRange.disabled = !enabled;
  if (state.backendMode === "local") {
    els.connectButton.textContent = enabled ? "Reconectar fita" : "Conectar agora";
    els.signalChip.textContent = enabled ? "Windows BLE conectado" : "Backend Windows BLE";
  } else {
    els.connectButton.textContent = enabled ? "Trocar fita" : "Buscar e conectar";
    els.signalChip.textContent = enabled ? "Canal FFE1 pronto" : "Pronto para buscar";
  }
  if (state.device) {
    els.deviceMeta.textContent = enabled
      ? "Conexao BLE aberta e pronta para enviar comandos."
      : "Dispositivo lembrado, mas desconectado no momento.";
  }
  document.querySelectorAll(".preset-button").forEach((button) => {
    button.disabled = !enabled;
  });
}

function setActiveDevice(device) {
  state.device = device;
  els.deviceName.textContent = device?.name || "Dispositivo sem nome";
  els.deviceMeta.textContent = state.connected
    ? "Conexao BLE aberta e pronta para enviar comandos."
    : "Dispositivo escolhido, mas ainda nao conectado.";
}

async function handleConnectClick() {
  if (state.backendMode === "local") {
    await connectViaLocalBackend();
    return;
  }

  if (!navigator.bluetooth) {
    updateStatus("Sem suporte Bluetooth", "error");
    log(
      "Este navegador nao suporta Web Bluetooth. Abra o painel usando start-aura-ble.bat.",
      "error"
    );
    return;
  }

  try {
    if (state.connected) {
      await disconnectFromDevice();
    }

    updateStatus("Buscando...", "loading");
    log("Abrindo seletor de dispositivos Bluetooth...", "system");

    const prefix = els.namePrefixInput.value.trim();
    const device = await navigator.bluetooth.requestDevice({
      acceptAllDevices: true,
      optionalServices: OPTIONAL_SERVICE_UUIDS,
    });

    if (prefix && device.name && !device.name.toUpperCase().startsWith(prefix.toUpperCase())) {
      log(
        `Voce escolheu ${device.name}. O esperado era algo com prefixo ${prefix}. Vou tentar mesmo assim.`,
        "system"
      );
    }

    await connectToDevice(device);
  } catch (error) {
    if (error?.name === "NotFoundError") {
      updateStatus("Busca interrompida", "idle");
      log(
        "A janela Bluetooth foi fechada ou a fita nao apareceu. Se o celular ainda estiver conectado na LEDBLE-01, desligue o Bluetooth dele e tente de novo.",
        "system"
      );
      return;
    }

    updateStatus("Falha na conexao", "error");
    log(`Falha ao conectar: ${formatError(error)}`, "error");
  }
}

async function connectViaLocalBackend() {
  try {
    if (state.connected) {
      await disconnectFromDevice();
    }

    updateStatus("Conectando...", "loading");
    log("Tentando conectar com a fita pelo Bluetooth nativo do Windows...", "system");
    const result = await apiRequest("/api/connect", {
      method: "POST",
      body: {
        namePrefix: els.namePrefixInput.value.trim() || "LEDBLE-01",
      },
    });

    state.connected = true;
    state.characteristic = { backend: true };
    setActiveDevice(result.device);
    updateConnectionUI();
    updateStatus("Conectado", "success");
    log(`Conectado com ${result.device.name} pelo backend Windows BLE.`, "success");
  } catch (error) {
    state.connected = false;
    state.characteristic = null;
    updateConnectionUI();
    updateStatus("Falha na conexao", "error");
    log(`Falha ao conectar pelo backend Windows BLE: ${formatError(error)}`, "error");
  }
}

async function connectToDevice(device) {
  if (!device) {
    throw new Error("Nenhum dispositivo informado.");
  }

  detachDisconnectHandler();
  device.addEventListener("gattserverdisconnected", handleUnexpectedDisconnect);
  setActiveDevice(device);

  log(`Conectando com ${device.name || "dispositivo sem nome"}...`, "system");
  const server = await device.gatt.connect();
  const service = await resolveService(server);
  const characteristic = await resolveCharacteristic(service);

  state.server = server;
  state.service = service;
  state.characteristic = characteristic;
  state.connected = true;

  updateConnectionUI();
  setActiveDevice(device);
  updateStatus("Conectado", "success");
  log(`Conectado. Servico ${service.uuid}, caracteristica ${characteristic.uuid}.`, "success");
}

async function resolveService(server) {
  try {
    return await server.getPrimaryService(SERVICE_UUID);
  } catch (directError) {
    const services = await server.getPrimaryServices();
    log(
      `Servicos encontrados: ${services.map((item) => item.uuid).join(", ") || "nenhum"}.`,
      "system"
    );
    const match = services.find(
      (item) => normalizeUuid(item.uuid) === SERVICE_UUID_FULL
    );

    if (match) {
      return match;
    }

    throw directError;
  }
}

async function resolveCharacteristic(service) {
  try {
    return await service.getCharacteristic(CHARACTERISTIC_UUID);
  } catch (directError) {
    const characteristics = await service.getCharacteristics();
    log(
      `Caracteristicas encontradas em ${service.uuid}: ${characteristics
        .map((item) => item.uuid)
        .join(", ") || "nenhuma"}.`,
      "system"
    );
    const match = characteristics.find(
      (item) => normalizeUuid(item.uuid) === CHARACTERISTIC_UUID_FULL
    );

    if (match) {
      return match;
    }

    throw directError;
  }
}

async function disconnectFromDevice() {
  detachDisconnectHandler();
  window.clearTimeout(brightnessTimer);
  window.clearTimeout(speedTimer);

  if (state.backendMode === "local") {
    try {
      await apiRequest("/api/disconnect", { method: "POST" });
    } catch (error) {
      log(`Falha ao encerrar a conexao local: ${formatError(error)}`, "error");
    }
  }

  if (state.device?.gatt?.connected) {
    state.device.gatt.disconnect();
  }

  state.server = null;
  state.service = null;
  state.characteristic = null;
  state.connected = false;
  state.isOn = false;
  updateConnectionUI();
  updatePowerButton();
  updateStatus("Desconectado", "idle");
  log("Dispositivo desconectado.", "system");
}

function handleUnexpectedDisconnect() {
  window.clearTimeout(brightnessTimer);
  window.clearTimeout(speedTimer);
  state.server = null;
  state.service = null;
  state.characteristic = null;
  state.connected = false;
  state.isOn = false;
  updateConnectionUI();
  updatePowerButton();
  updateStatus("Bluetooth caiu", "error");
  log("A conexao Bluetooth foi encerrada pelo dispositivo ou pelo sistema.", "error");
}

function detachDisconnectHandler() {
  if (state.device) {
    state.device.removeEventListener(
      "gattserverdisconnected",
      handleUnexpectedDisconnect
    );
  }
}

async function handlePowerToggle() {
  if (state.isOn) {
    await turnOff();
  } else {
    await turnOn();
  }
}

async function turnOn() {
  await sendPacket([0x7e, 0xff, 0x04, 0x01, 0xff, 0xff, 0xff, 0xff, 0xef], "Ligar");
  state.isOn = true;
  updatePowerButton();
  await sendBrightness(state.brightness);
  await applyColor(state.color, false);
}

async function turnOff() {
  await sendPacket([0x7e, 0xff, 0x04, 0x00, 0xff, 0xff, 0xff, 0xff, 0xef], "Desligar");
  state.isOn = false;
  updatePowerButton();
}

async function applyColor(hexColor, ensureOn = true) {
  state.color = hexColor;
  els.colorInput.value = hexColor;
  state.effectId = "";
  els.effectSelect.value = "";
  updateColorPreview();
  saveSettings();

  if (ensureOn && !state.isOn) {
    await sendPacket(
      [0x7e, 0xff, 0x04, 0x01, 0xff, 0xff, 0xff, 0xff, 0xef],
      "Ligar"
    );
    state.isOn = true;
    updatePowerButton();
  }

  const { r, g, b } = hexToRgb(hexColor);
  await sendPacket([0x7e, 0xff, 0x05, 0x03, r, g, b, 0xff, 0xef], `Cor ${hexColor}`);
}

async function sendBrightness(value) {
  state.brightness = clamp(value, 0, 100);
  updateRangeLabels();
  saveSettings();
  await sendPacket(
    [0x7e, 0xff, 0x01, state.brightness, 0x00, 0xff, 0xff, 0xff, 0xef],
    `Brilho ${state.brightness}%`
  );
}

async function sendSpeed(value) {
  state.speed = clamp(value, 0, 100);
  updateRangeLabels();
  saveSettings();
  await sendPacket(
    [0x7e, 0xff, 0x02, state.speed, 0x00, 0xff, 0xff, 0xff, 0xef],
    `Velocidade ${state.speed}%`
  );
}

async function sendEffect(effectId) {
  state.effectId = String(effectId);
  els.effectSelect.value = state.effectId;
  saveSettings();

  if (!state.isOn) {
    await sendPacket(
      [0x7e, 0xff, 0x04, 0x01, 0xff, 0xff, 0xff, 0xff, 0xef],
      "Ligar"
    );
    state.isOn = true;
    updatePowerButton();
  }

  await sendPacket(
    [0x7e, 0xff, 0x03, effectId, 0x03, 0xff, 0xff, 0xff, 0xef],
    `Efeito 0x${effectId.toString(16).toUpperCase()}`
  );
  await sendSpeed(state.speed);
}

async function sendPacket(bytes, label) {
  if (!state.connected || (!state.characteristic && state.backendMode !== "local")) {
    log(`Tentativa ignorada (${label}): conecte a fita primeiro.`, "error");
    throw new Error("Nao ha uma fita conectada.");
  }

  return enqueueWrite(async () => {
    if (state.backendMode === "local") {
      await apiRequest("/api/send", {
        method: "POST",
        body: {
          bytes,
          label,
        },
      });
    } else {
      const payload = Uint8Array.from(bytes);

      if (state.characteristic.properties?.writeWithoutResponse &&
          typeof state.characteristic.writeValueWithoutResponse === "function") {
        await state.characteristic.writeValueWithoutResponse(payload);
      } else {
        await state.characteristic.writeValue(payload);
      }
    }

    els.lastActionText.textContent = label;
    els.lastActionPill.textContent = label;
    log(`${label} -> ${toHex(bytes)}`, "tx");
  }).catch((error) => {
    updateStatus("Erro ao enviar", "error");
    log(`Falha ao enviar comando ${label}: ${formatError(error)}`, "error");
    throw error;
  });
}

function enqueueWrite(task) {
  const runner = state.writeQueue.catch(() => {}).then(task);
  state.writeQueue = runner;
  return runner;
}

function syncBackendStatus(status) {
  state.connected = Boolean(status.connected);
  if (status.device) {
    state.characteristic = status.connected ? { backend: true } : null;
    setActiveDevice(status.device);
  } else {
    state.characteristic = null;
  }
  updateConnectionUI();
  if (state.connected) {
    updateStatus("Conectado", "success");
  }
}

function restoreSettings() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) {
      syncControlsFromState();
      return;
    }

    const saved = JSON.parse(raw);
    state.color = typeof saved.color === "string" ? saved.color : state.color;
    state.brightness = Number.isFinite(Number(saved.brightness))
      ? clamp(Number(saved.brightness), 0, 100)
      : state.brightness;
    state.speed = Number.isFinite(Number(saved.speed))
      ? clamp(Number(saved.speed), 0, 100)
      : state.speed;
    state.effectId = typeof saved.effectId === "string" ? saved.effectId : "";
    syncControlsFromState();
  } catch (error) {
    syncControlsFromState();
    log(`Nao foi possivel restaurar preferencias: ${formatError(error)}`, "error");
  }
}

function syncControlsFromState() {
  els.colorInput.value = state.color;
  els.brightnessRange.value = String(state.brightness);
  els.speedRange.value = String(state.speed);
  els.effectSelect.value = state.effectId;
}

function saveSettings() {
  const snapshot = {
    brightness: state.brightness,
    color: state.color,
    effectId: state.effectId,
    speed: state.speed,
  };
  localStorage.setItem(STORAGE_KEY, JSON.stringify(snapshot));
}

function log(message, level = "info") {
  const stamp = new Date().toLocaleTimeString("pt-BR", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const prefix = `[${stamp}]`;
  const tag =
    level === "error"
      ? "[erro]"
      : level === "tx"
        ? "[tx]"
        : level === "success"
          ? "[ok]"
          : "[info]";
  const lines = `${els.logOutput.textContent}\n${prefix} ${tag} ${message}`.trim();
  const trimmed = lines.split("\n").slice(-160).join("\n");
  els.logOutput.textContent = trimmed;
  els.logOutput.scrollTop = els.logOutput.scrollHeight;
}

function toHex(bytes) {
  return Array.from(bytes, (value) =>
    value.toString(16).toUpperCase().padStart(2, "0")
  ).join(" ");
}

function formatError(error) {
  if (!error) {
    return "erro desconhecido";
  }

  if (typeof error === "string") {
    return error;
  }

  return error.message || error.name || "erro desconhecido";
}

async function apiRequest(url, options = {}) {
  const requestOptions = {
    method: options.method || "GET",
    headers: {
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
  };

  if (options.body !== undefined) {
    requestOptions.body = JSON.stringify(options.body);
  }

  const response = await fetch(url, requestOptions);
  let data = null;

  try {
    data = await response.json();
  } catch (error) {
    if (!response.ok) {
      throw new Error(`Falha HTTP ${response.status}`);
    }
    return null;
  }

  if (!response.ok || data?.ok === false) {
    throw new Error(data?.error || `Falha HTTP ${response.status}`);
  }

  return data;
}

function hexToRgb(hex) {
  const clean = hex.replace("#", "");
  const value = Number.parseInt(clean, 16);
  return {
    r: (value >> 16) & 255,
    g: (value >> 8) & 255,
    b: value & 255,
  };
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function normalizeUuid(value) {
  return String(value).toLowerCase();
}

function lightenColor(hex, amount) {
  const { r, g, b } = hexToRgb(hex);
  return `rgb(${clamp(r + amount, 0, 255)}, ${clamp(g + amount, 0, 255)}, ${clamp(
    b + amount,
    0,
    255
  )})`;
}

function darkenColor(hex, amount) {
  const { r, g, b } = hexToRgb(hex);
  return `rgb(${clamp(r - amount, 0, 255)}, ${clamp(g - amount, 0, 255)}, ${clamp(
    b - amount,
    0,
    255
  )})`;
}

init().catch((error) => {
  updateStatus("Erro ao iniciar", "error");
  log(`Falha ao iniciar o painel: ${formatError(error)}`, "error");
});
