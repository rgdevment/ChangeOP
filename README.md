# ChangeOP

Cambia con un clic el monitor, el teclado y el mouse entre Windows y Mac.

| Equipo  | Monitor | Teclado y mouse (Easy-Switch) |
|---------|---------|-------------------------------|
| Windows | DisplayPort 2 | Canal 1 |
| Mac     | HDMI 2  | Canal 2 |

Funciona con teclados y mouse Logitech MX conectados por receptor USB (Logi Bolt o Unifying) y con monitores que tengan **DDC/CI** activado en su menú.

## Windows → Mac

No requiere instalar nada.

1. Comprueba que el script lee los monitores. Muestra el código de cada uno y su entrada actual (el compartido debería estar en `0x10`, que es DP2):
   ```powershell
   powershell -ExecutionPolicy Bypass -File windows\switch-to-mac.ps1 -ShowInput
   ```
2. Crea el acceso directo «Cambiar a Mac» en el Escritorio, con la tecla rápida **Ctrl+Alt+M**:
   ```powershell
   powershell -ExecutionPolicy Bypass -File windows\install-shortcut.ps1
   ```
   Para usar otra tecla: `install-shortcut.ps1 -Hotkey "CTRL+ALT+K"`.

## Mac → Windows

Requiere un Mac Apple Silicon con [Homebrew](https://brew.sh) instalado.

1. Copia la carpeta `mac/` al Mac, en un lugar fijo.
2. Instala las dependencias (`m1ddc` y `hidapi`) y crea la app «Cambiar a Windows» en el Escritorio:
   ```bash
   python3 mac/switch_to_windows.py --install
   ```
3. Abre la app con doble clic, desde el Dock o con Spotlight. La primera vez, macOS puede pedirte permiso de **Monitorización de entrada**.

Si mueves la carpeta, vuelve a ejecutar `--install`.

## Si el teclado o el mouse no cambian

En Windows, consulta qué ve el receptor sin cambiar nada:

```powershell
powershell -ExecutionPolicy Bypass -File windows\switch-to-mac.ps1 -Probe
```

Muestra, por cada posición del receptor, el nombre del dispositivo y su canal actual. `error 0x09` significa que esa posición está vacía y `no reply` que el dispositivo no respondió a tiempo.

## Ajustes

Los valores se cambian al inicio de cada script:

- Windows: los parámetros `-MonitorInput`, `-HostChannel` y `-MonitorModel` en `windows/switch-to-mac.ps1`. `-MonitorModel` es el código del monitor compartido con el Mac (lo muestra `-ShowInput`); los demás monitores no se tocan.
- Mac: `MONITOR_INPUT` y `HOST_CHANNEL` en `mac/switch_to_windows.py`.

Códigos de entrada estándar: `0x0F` DP1, `0x10` DP2, `0x11` HDMI1, `0x12` HDMI2. Si tu monitor usa otros, lee el código de la entrada actual con `-ShowInput` en Windows o con `m1ddc get input` en Mac.
