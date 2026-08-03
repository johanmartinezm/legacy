<#
.SYNOPSIS
    Levanta el entorno de desarrollo local de Legacy Network.

.DESCRIPTION
    Orquesta en orden los modulos del monorepo:
      db       -> Contenedor PostgreSQL 17 + carga del esquema (solo si esta vacio)
      backend  -> API en Go, puerto 8080
      admin    -> Sitio administrativo Angular, puerto 4200
      movil    -> App Flutter en Chrome

    Es idempotente: si algo ya esta corriendo, lo detecta y no lo duplica.
    Nunca borra datos existentes.

.PARAMETER Solo
    Modulos a levantar. Por defecto: db, backend, admin.
    La app movil no se incluye por defecto porque abre un navegador.

.PARAMETER Detener
    Detiene todo lo que este corriendo (contenedor y procesos en 8080/4200).

.PARAMETER MovilContraProd
    Deja la app movil apuntando a produccion en lugar de al backend local.

.EXAMPLE
    .\levantar.ps1
    Levanta base de datos, backend y sitio administrativo.

.EXAMPLE
    .\levantar.ps1 -Solo db,backend,admin,movil
    Levanta todo, incluida la app movil en Chrome.

.EXAMPLE
    .\levantar.ps1 -Detener
    Apaga todo.
#>
[CmdletBinding()]
param(
    [ValidateSet('db', 'backend', 'admin', 'movil')]
    [string[]] $Solo = @('db', 'backend', 'admin'),

    [switch] $Detener,

    [switch] $MovilContraProd
)

$ErrorActionPreference = 'Stop'

# --- Rutas -------------------------------------------------------------------

$Raiz     = $PSScriptRoot
$DirBack  = Join-Path $Raiz 'Backend'
$DirAdmin = Join-Path $Raiz 'Sitio-Administrativo'
$DirMovil = Join-Path $Raiz 'App-Movil'

$Contenedor  = 'legacy_db'
$PuertoApi   = 8080
$PuertoAdmin = 4200

# --- Salida ------------------------------------------------------------------

function Paso  ($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok    ($m) { Write-Host "    [OK] $m"   -ForegroundColor Green }
function Aviso ($m) { Write-Host "    [!]  $m"   -ForegroundColor Yellow }
function Fallo ($m) { Write-Host "    [X]  $m"   -ForegroundColor Red }

function Test-Puerto ($puerto) {
    $c = Get-NetTCPConnection -LocalPort $puerto -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $c)
}

function Get-PidsEnPuerto ($puerto) {
    $c = Get-NetTCPConnection -LocalPort $puerto -State Listen -ErrorAction SilentlyContinue
    if ($null -eq $c) { return @() }
    return @($c | Select-Object -ExpandProperty OwningProcess -Unique)
}

# Abre un comando en una ventana propia para poder ver sus logs.
function Iniciar-Ventana ($titulo, $directorio, $comando) {
    $script = "`$Host.UI.RawUI.WindowTitle = '$titulo'; Set-Location '$directorio'; $comando"
    Start-Process powershell -ArgumentList '-NoExit', '-Command', $script | Out-Null
}

# --- Detener -----------------------------------------------------------------

if ($Detener) {
    Paso 'Deteniendo el entorno'

    foreach ($p in @($PuertoApi, $PuertoAdmin)) {
        $pids = Get-PidsEnPuerto $p
        if ($pids.Count -eq 0) {
            Ok "Puerto $p ya estaba libre"
            continue
        }
        foreach ($procId in $pids) {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($null -ne $proc) {
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                Ok "Detenido $($proc.ProcessName) (PID $procId) en puerto $p"
            }
        }
    }

    $null = docker stop $Contenedor 2>$null
    if ($LASTEXITCODE -eq 0) {
        Ok "Contenedor $Contenedor detenido (los datos se conservan)"
    } else {
        Ok "Contenedor $Contenedor no estaba corriendo"
    }

    Write-Host "`nEntorno detenido.`n" -ForegroundColor Cyan
    return
}

# --- Prerrequisitos ----------------------------------------------------------

Paso 'Verificando herramientas'

$requeridas = @{ 'db' = @('docker'); 'backend' = @('go'); 'admin' = @('npm'); 'movil' = @('flutter') }
$faltantes = @()

foreach ($modulo in $Solo) {
    foreach ($herramienta in $requeridas[$modulo]) {
        if ($null -eq (Get-Command $herramienta -ErrorAction SilentlyContinue)) {
            $faltantes += "$herramienta (necesaria para '$modulo')"
        }
    }
}

if ($faltantes.Count -gt 0) {
    foreach ($f in $faltantes) { Fallo "No encontrada: $f" }
    throw 'Faltan herramientas en el PATH.'
}
Ok "Disponibles para: $($Solo -join ', ')"

# --- 1. Base de datos --------------------------------------------------------

if ($Solo -contains 'db') {
    Paso 'Base de datos (PostgreSQL 17)'

    # El demonio de Docker puede tardar en arrancar tras el login.
    $null = docker info 2>$null
    if ($LASTEXITCODE -ne 0) {
        $exe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
        if (Test-Path $exe) {
            Aviso 'Docker no responde. Iniciando Docker Desktop...'
            Start-Process $exe | Out-Null
        } else {
            throw "Docker no responde y no encontre Docker Desktop en $exe"
        }

        $limite = (Get-Date).AddMinutes(3)
        while ((Get-Date) -lt $limite) {
            Start-Sleep -Seconds 3
            $null = docker info 2>$null
            if ($LASTEXITCODE -eq 0) { break }
        }
        if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop no arranco en 3 minutos.' }
    }
    Ok 'Demonio de Docker activo'

    # Reutiliza el contenedor si ya existe; nunca lo recrea (perderia los datos).
    $existe = docker ps -a --filter "name=^/$Contenedor$" --format '{{.Names}}' 2>$null
    if ($existe -eq $Contenedor) {
        $corriendo = docker ps --filter "name=^/$Contenedor$" --format '{{.Names}}' 2>$null
        if ($corriendo -eq $Contenedor) {
            Ok "Contenedor $Contenedor ya estaba corriendo"
        } else {
            $null = docker start $Contenedor 2>$null
            Ok "Contenedor $Contenedor reiniciado"
        }
    } else {
        Aviso "Creando contenedor $Contenedor por primera vez..."
        $null = docker run --name $Contenedor `
            -e POSTGRES_USER=dba -e POSTGRES_PASSWORD=123 -e POSTGRES_DB=applegacy `
            -p 5432:5432 -d postgres:17-alpine
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo crear el contenedor de Postgres.' }
        Ok 'Contenedor creado'
    }

    # Postgres acepta conexiones unos segundos despues de arrancar.
    $limite = (Get-Date).AddSeconds(60)
    $listo = $false
    while ((Get-Date) -lt $limite) {
        $null = docker exec $Contenedor pg_isready -U dba -d applegacy 2>$null
        if ($LASTEXITCODE -eq 0) { $listo = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $listo) { throw 'Postgres no acepto conexiones en 60 segundos.' }
    Ok 'Postgres acepta conexiones'

    # Carga el esquema solo si la base esta vacia: schema.sql no es idempotente
    # (empieza con CREATE SCHEMA sin IF NOT EXISTS) y volver a correrlo fallaria.
    $consulta = "select count(*) from information_schema.tables where table_schema in ('core','chat','community','events');"
    $tablas = (docker exec $Contenedor psql -U dba -d applegacy -tAc $consulta 2>$null)
    $tablas = [int]($tablas | Select-Object -First 1)

    if ($tablas -gt 0) {
        Ok "Esquema ya cargado ($tablas tablas). No se toca."
    } else {
        Aviso 'Base vacia. Cargando esquema...'

        $schema = Join-Path $DirBack 'scripts\schema.sql'
        $null = docker cp $schema "${Contenedor}:/schema.sql"
        $null = docker exec $Contenedor psql -U dba -d applegacy -v ON_ERROR_STOP=1 -f /schema.sql
        if ($LASTEXITCODE -ne 0) { throw 'Fallo la carga de schema.sql' }
        Ok 'schema.sql cargado'

        # Migraciones posteriores al dump, en orden alfabetico (llevan fecha).
        $migraciones = Get-ChildItem (Join-Path $DirBack 'scripts') -Filter '*.sql' |
                       Where-Object { $_.Name -ne 'schema.sql' } |
                       Sort-Object Name

        foreach ($m in $migraciones) {
            $null = docker cp $m.FullName "${Contenedor}:/$($m.Name)"
            $null = docker exec $Contenedor psql -U dba -d applegacy -v ON_ERROR_STOP=1 -f "/$($m.Name)"
            if ($LASTEXITCODE -ne 0) { throw "Fallo la migracion $($m.Name)" }
            Ok "Migracion aplicada: $($m.Name)"
        }

        Aviso 'Base recien creada: no hay administrador todavia.'
        Aviso 'Crea uno con: cd Backend; go run scripts\create_admin.go'
    }
}

# --- 2. Backend --------------------------------------------------------------

if ($Solo -contains 'backend') {
    Paso "Backend Go (puerto $PuertoApi)"

    if (Test-Puerto $PuertoApi) {
        Ok "Ya hay algo escuchando en $PuertoApi. No se lanza otra instancia."
    } else {
        # config.yaml se carga con ruta relativa, asi que el cwd debe ser Backend\.
        Iniciar-Ventana 'Legacy - Backend' $DirBack 'go run ./cmd/server'
        Aviso 'Compilando (la primera vez puede tardar)...'

        $limite = (Get-Date).AddMinutes(3)
        $arriba = $false
        while ((Get-Date) -lt $limite) {
            Start-Sleep -Seconds 2
            try {
                $r = Invoke-WebRequest "http://localhost:$PuertoApi/health" -UseBasicParsing -TimeoutSec 3
                if ($r.StatusCode -eq 200) { $arriba = $true; break }
            } catch { }
        }

        if ($arriba) {
            Ok "API respondiendo en http://localhost:$PuertoApi/health"
        } else {
            Fallo 'La API no respondio en 3 minutos. Revisa la ventana "Legacy - Backend".'
        }
    }

    if (-not (Test-Path (Join-Path $DirBack 'firebase-service-account.json'))) {
        Aviso 'Sin firebase-service-account.json: las notificaciones push van en modo mock.'
    }
}

# --- 3. Sitio administrativo -------------------------------------------------

if ($Solo -contains 'admin') {
    Paso "Sitio administrativo Angular (puerto $PuertoAdmin)"

    if (Test-Puerto $PuertoAdmin) {
        Ok "Ya hay algo escuchando en $PuertoAdmin. No se lanza otra instancia."
    } else {
        if (-not (Test-Path (Join-Path $DirAdmin 'node_modules'))) {
            Aviso 'Falta node_modules. Instalando dependencias (esto tarda varios minutos)...'
            Push-Location $DirAdmin
            try {
                npm install --no-fund --no-audit
                if ($LASTEXITCODE -ne 0) { throw 'npm install fallo.' }
            } finally {
                Pop-Location
            }
            Ok 'Dependencias instaladas'
        } else {
            Ok 'node_modules presente'
        }

        Iniciar-Ventana 'Legacy - Admin' $DirAdmin 'npm start'
        Ok "Arrancando en http://localhost:$PuertoAdmin (apunta a localhost:$PuertoApi)"
    }
}

# --- 4. App movil ------------------------------------------------------------

if ($Solo -contains 'movil') {
    Paso 'App movil Flutter (Chrome)'

    $config  = Join-Path $DirMovil 'assets\config\config.json'
    $develop = Join-Path $DirMovil 'assets\config\config.json.develop'
    $respaldo = "$config.bak"

    if ($MovilContraProd) {
        Aviso 'Se deja la configuracion tal cual (-MovilContraProd).'
    } else {
        # config.json viene apuntando a produccion; hay que cambiarlo para local.
        $actual = Get-Content $config -Raw
        if ($actual -match 'localhost:8080') {
            Ok 'La app ya apunta al backend local'
        } else {
            if (-not (Test-Path $respaldo)) {
                Copy-Item $config $respaldo
                Ok "Respaldo guardado en config.json.bak"
            }
            Copy-Item $develop $config -Force
            Ok 'Configuracion cambiada a desarrollo (localhost:8080)'
        }
    }

    Push-Location $DirMovil
    try {
        flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get fallo.' }
    } finally {
        Pop-Location
    }
    Ok 'Dependencias de Flutter listas'

    Iniciar-Ventana 'Legacy - Movil' $DirMovil 'flutter run -d chrome'
    Ok 'Arrancando en Chrome (la ventana muestra el hot reload)'
}

# --- Resumen -----------------------------------------------------------------

Write-Host "`n----------------------------------------------------" -ForegroundColor Cyan
Write-Host " Entorno levantado" -ForegroundColor Cyan
Write-Host "----------------------------------------------------" -ForegroundColor Cyan
if ($Solo -contains 'db')      { Write-Host "  Postgres  localhost:5432  (base applegacy)" }
if ($Solo -contains 'backend') { Write-Host "  API       http://localhost:$PuertoApi" }
if ($Solo -contains 'admin')   { Write-Host "  Admin     http://localhost:$PuertoAdmin" }
if ($Solo -contains 'movil')   { Write-Host "  Movil     Chrome (ventana aparte)" }
Write-Host "`n  Para apagar todo:  .\levantar.ps1 -Detener`n" -ForegroundColor DarkGray
