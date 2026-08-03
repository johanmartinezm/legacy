<#
.SYNOPSIS
    Manejador del hook UserPromptSubmit para el entorno Legacy.

.DESCRIPTION
    Lee por stdin el JSON que Claude Code entrega en UserPromptSubmit, revisa si
    el prompt es una orden de levantar o bajar el entorno, y en ese caso ejecuta
    levantar.ps1 y bloquea el prompt (para que el modelo no lo haga otra vez).

    Si el prompt no es una de esas ordenes, sale en silencio con codigo 0 y el
    prompt sigue su curso normal.

    Ordenes reconocidas (sin importar mayusculas, tildes ni signos):
      levantar / levanta / subir / sube  [el] legacy
      bajar / baja / detener / apagar / apaga  [el] legacy
#>

$ErrorActionPreference = 'Stop'

# El script vive en <raiz>\.claude\hooks\, asi que la raiz esta dos niveles arriba.
$Raiz    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script  = Join-Path $Raiz 'levantar.ps1'

function Responder ($mensaje) {
    # decision=block evita que el prompt llegue al modelo: la orden ya se ejecuto.
    $salida = [ordered]@{
        decision      = 'block'
        reason        = $mensaje
        systemMessage = $mensaje
    }
    Write-Output ($salida | ConvertTo-Json -Compress)
    exit 0
}

# --- Entrada -----------------------------------------------------------------

$crudo = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($crudo)) { exit 0 }

try {
    $datos = $crudo | ConvertFrom-Json
} catch {
    exit 0
}

$prompt = $datos.prompt
if ([string]::IsNullOrWhiteSpace($prompt)) { exit 0 }

# Normaliza: minusculas, sin signos de puntuacion, espacios colapsados.
$texto = $prompt.ToLowerInvariant()
$texto = $texto -replace '[^\p{L}\p{N}\s]', ''
$texto = ($texto -replace '\s+', ' ').Trim()

# --- Decision ----------------------------------------------------------------

$esLevantar = $texto -match '^(levantar|levanta|subir|sube)( el)? legacy$'
$esBajar    = $texto -match '^(bajar|baja|detener|apagar|apaga)( el)? legacy$'

if (-not $esLevantar -and -not $esBajar) { exit 0 }

if (-not (Test-Path $Script)) {
    Responder "No encontre levantar.ps1 en $Raiz. No se ejecuto nada."
}

# --- Bajar: rapido, se ejecuta aqui mismo y se devuelve la salida real --------

if ($esBajar) {
    try {
        # 6>&1 captura lo que levantar.ps1 escribe con Write-Host.
        $salida = & $Script -Detener 6>&1 | Out-String
    } catch {
        Responder "Fallo al detener el entorno: $($_.Exception.Message)"
    }

    $lineas = $salida -split "`r?`n" | Where-Object { $_ -match '\[OK\]|\[X\]|\[!\]' }
    $detalle = ($lineas | ForEach-Object { $_.Trim() }) -join "`n"

    Responder "Entorno Legacy detenido.`n$detalle"
}

# --- Levantar: lento, se abre en su propia ventana ----------------------------

$argumentos = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $Script)
Start-Process powershell -ArgumentList $argumentos | Out-Null

Responder @"
Levantando el entorno Legacy en una ventana aparte (titulo: Windows PowerShell).
Arranca en orden: Postgres -> backend (8080) -> sitio administrativo (4200).
La primera vez puede tardar varios minutos si falta compilar o instalar dependencias.
"@
