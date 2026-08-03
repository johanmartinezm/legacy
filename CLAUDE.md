# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Este repositorio y su documentación están en español. Responde y documenta en español; mantén en inglés el código, los nombres de archivo y los comandos.

## Qué es

Monorepo de **Legacy Network**: plataforma de comunidad y membresía con eventos, foros anónimos, chat, contenido y pagos. Tres aplicaciones contra una misma API:

| Carpeta | Stack | Rol |
|---|---|---|
| `Backend/` | Go 1.25 + chi + PostgreSQL (pgx) | API REST + WebSocket, puerto 8080 |
| `Sitio-Administrativo/` | Angular 18 + Material | Back-office, puerto 4200 |
| `App-Movil/` | Flutter (iOS, Android, web) | App de usuario final |

**No hay control de versiones.** Ninguna de las tres carpetas es un repositorio git. No existe historial ni forma de revertir: verifica antes de sobrescribir.

## Levantar el entorno

Hay un script que orquesta todo, es idempotente y no borra datos:

```powershell
.\levantar.ps1                              # base de datos + backend + admin
.\levantar.ps1 -Solo db,backend,admin,movil # todo, incluida la app en Chrome
.\levantar.ps1 -Detener                     # apaga todo
```

Levanta Postgres en Docker (contenedor `legacy_db`, credenciales `dba`/`123`, base `applegacy`), carga el esquema solo si la base está vacía, y abre cada servidor en su propia ventana. Existe también un hook en `.claude/settings.json` que ejecuta el script cuando el usuario escribe "levantar legacy" o "bajar legacy".

## Comandos por módulo

### Backend (Go)

```bash
go run ./cmd/server            # arrancar (o ./run.sh)
go build ./...                 # compilar todo
go vet ./...                   # análisis estático
go test ./...                  # tests
go test ./internal/core/services -run TestNombre -v   # un solo test
./build-linux.sh               # binario estático para el servidor (server_linux)
```

**Ejecuta siempre desde `Backend/`**: `main.go` carga `config.yaml` con ruta relativa y muere al arrancar desde otro directorio.

`internal/adapter/storage/postgres/test_update_test.go` falla siempre: tiene la cadena de conexión escrita a mano con el usuario `postgres` en vez de `dba`. Es un test suelto, no una regresión.

### Sitio Administrativo (Angular)

```bash
npm install
npm start                      # ng serve en :4200
ng build --configuration production
ng test --include='**/nombre.spec.ts'   # un solo spec
```

### App Móvil (Flutter)

```bash
flutter pub get
flutter run -d chrome          # también: -d windows, -d emulator-5554
flutter analyze
flutter test test/providers/chat_provider_test.dart   # un solo test
./compilar_android.sh          # .aab firmado y ofuscado para Play Store
```

En Windows, `flutter analyze` y cualquier build con plugins exigen el **Modo de Desarrollador** activado (`start ms-settings:developers`); sin eso Flutter no puede crear symlinks y falla antes de empezar.

## Arquitectura

### Backend: hexagonal, con un único punto de cableado

```
core/domain      entidades          core/ports    interfaces
core/services    lógica de negocio  handler/http  controladores HTTP
adapter/storage/postgres            infrastructure/  firebase, email, websocket, credibanco
```

`cmd/server/main.go` es el **único** lugar donde se instancian repositorios, servicios y handlers y donde se registran las rutas. Una funcionalidad nueva toca seis archivos en este orden: `domain` → `ports` → `postgres` → `services` → `handler/http` → **registrar la ruta en `main.go`**.

Ese último paso es el que más se olvida. `ImageHandler.UploadImage` está escrito y probado pero nunca se registró, así que la carga de imágenes no existe en la práctica. Cuando agregues un handler, verifica que su ruta aparezca en `main.go`.

Las rutas se agrupan en cuatro bloques: públicas sin auth, públicas con `OptionalAuthMiddleware`, privadas con `AuthMiddleware`, y admin con `AdminOnly`.

**Cifrado en reposo:** `security.CryptoService` (AES-256) cifra datos sensibles de usuarios, mensajes de chat y sinergias. Los servicios que reciben `cryptoService` cifran al escribir y descifran al leer — si añades una consulta que devuelva esos campos sin pasar por el servicio, obtendrás texto cifrado.

**El hub de chat vive en memoria** (`infrastructure/websocket`, arrancado con `go chatHub.Run()`). El backend no se puede escalar horizontalmente sin romper el chat.

**Base de datos:** esquemas separados `core`, `events`, `community`, `chat` (35 tablas). `scripts/schema.sql` es un dump de `pg_dump` y **no es idempotente** (empieza con `CREATE SCHEMA chat;` sin `IF NOT EXISTS`): solo sirve para una base vacía. Los cambios posteriores van como migraciones fechadas en `scripts/AAAAMMDD_descripcion.sql`, documentando en la cabecera el contexto, los archivos afectados y el error concreto que corrigen — sigue el formato de `20260731_add_synergies_comments_count.sql`.

Ningún listado tiene paginación (`LIMIT`/`OFFSET` no aparece en los repositorios).

### App Móvil: capas + Provider + go_router

```
data/         servicios HTTP y configuración
domain/       modelos y providers (ChangeNotifier)
presentation/ pantallas y widgets
```

`main.dart` concentra el bootstrap: `ConfigService.initialize()`, Firebase, el árbol de `MultiProvider` y todas las rutas de `go_router`.

**Configuración por JSON, no por `--dart-define`.** `assets/config/config.json` define las URLs; hay tres variantes en la misma carpeta (`config.json`, `.develop`, `.prod`) y se cambia copiando una sobre otra. El archivo por defecto apunta a **producción** (`https://legacy.intelyclick.com`); para trabajar en local hay que copiar `config.json.develop` encima. `ConfigService` resuelve la URL por plataforma: `10.0.2.2` en Android (emulador), `localhost` en web e iOS.

Además de la API propia, la app consume dos GraphQL externos: `lso.school/graphql` y `legacynetworkco.com/graphql` (WordPress, fuente de las noticias).

Hay estructura duplicada heredada: `lib/ui/screens/forums` (vacío) junto a `lib/presentation/screens/forums`, y `screens/community` (sinergias) junto a `screens/comunidad` (miembros).

### Sitio Administrativo: standalone components por feature

`core/` (interceptor de auth, servicios, modelos, layout) y `features/` (una carpeta por módulo de administración). Rutas en `app.routes.ts`, providers en `app.config.ts`.

**Solo existe `src/environments/environment.ts`** y `angular.json` no define `fileReplacements`, así que el build de producción también apunta a `http://localhost:8080`. Hay que resolverlo antes de desplegar.

## Convenciones del proyecto

**Bitácora de QA.** Cada módulo tiene un `qa_bitacora.md` donde se registra cada entrega con este formato:

```
### [AAAA-MM-DD]: Título del cambio
- **Alcance:** archivos y rutas tocadas
- **Criterios de QA:** lista numerada de pasos verificables por una persona
```

Los informes puntuales van en `reports/AAAAMMDD_nombre.md`; los planes técnicos previos a implementar, en `App-Movil/docs/` e `App-Movil/implementaciones/`.

## Desalineaciones conocidas

Al tocar estas zonas, ten presente que ya están rotas:

- La app llama a `/api/auth/social-login` (`auth_service.dart:97`) y a `/api/resend-verification` (`auth_service.dart:279`); el backend expone `/social-login` y `/resend-verification`. Ambas dan 404.
- El panel administrativo no tiene subida de archivos: los campos de imagen son texto donde se pega una URL.
- Las notificaciones push solo se envían manualmente desde el panel. Ni crear un evento, ni publicar contenido, ni enviar un mensaje de chat disparan una notificación.
- El chat es estrictamente 1:1 (`chat.connections` con `requester_id`/`receiver_id`). No existe chat grupal; los "grupos" (`core.custom_groups`) sirven solo para segmentar envíos push.
- Sin `firebase-service-account.json` en `Backend/`, FCM arranca en modo mock y las notificaciones se escriben en consola en lugar de enviarse.

## Seguridad

`config.yaml`, `config.docker.yaml` y `.env` contienen secretos reales en texto plano (contraseña SSH de root del servidor, credenciales de Credibanco), y la `encryption_key` y el `jwt_secret` siguen con los valores de ejemplo. No propagues esos valores a archivos nuevos ni los incluyas en salidas; si trabajas en configuración, muévelos a variables de entorno.

Las consultas SQL están parametrizadas. No hay sanitización de HTML, ni protección CSRF, y el CORS está en `AllowedOrigins: "*"` con `AllowCredentials: true`.
