# Aura BLE

Painel local para controlar fitas LED Bluetooth do tipo `LEDBLE-01` no Windows usando Web Bluetooth.

## Como abrir

1. Execute [start-aura-desktop.bat](./start-aura-desktop.bat).
2. Clique em **Buscar fitas**.
3. Selecione a sua `LEDBLE-01-...`.
4. Clique em **Conectar**.
5. Use os controles de cor, brilho, velocidade e efeitos.

## O que este app faz

- conecta na fita por Bluetooth LE
- envia comandos para ligar e desligar
- troca a cor RGB
- ajusta brilho
- ajusta velocidade dos efeitos
- envia efeitos do controlador `0x87` ate `0x9D`

## Observacoes

- Este projeto foi feito para o controlador mostrado nas imagens do app `LED Lamp`.
- O modo recomendado agora e o controlador nativo do Windows em PowerShell.
- O painel web continua na pasta, mas a rota nativa e mais confiavel para esse dispositivo.
- O app salva suas ultimas preferencias no `localStorage`.
