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

**Cuatro repositorios git independientes, no submódulos.** Esta carpeta versiona solo la capa de orquestación (`levantar.ps1`, este archivo, las skills compartidas) y excluye las tres subcarpetas en su `.gitignore`; cada módulo tiene su propio historial y su propio remoto:

| Carpeta | Remoto |
|---|---|
| raíz | `github.com/johanmartinezm/legacy` |
| `Backend/` | `github.com/johanmartinezm/legacy-Backend` |
| `App-Movil/` | `github.com/johanmartinezm/legacy-App-Movil` |
| `Sitio-Administrativo/` | `github.com/johanmartinezm/legacy-Sitio-Administrativo` |

Los cuatro son **públicos**. Ningún comando de git en la raíz alcanza a los módulos: para operar sobre uno hay que usar `git -C <carpeta>` o entrar en él. El historial arranca en el commit inicial del 3 de agosto de 2026 — no hay nada anterior, así que sigue verificando antes de sobrescribir cualquier archivo que no esté versionado.

## Levantar el entorno

Hay un script que orquesta todo, es idempotente y no borra datos:

```powershell
.\levantar.ps1                              # base de datos + backend + admin
.\levantar.ps1 -Solo db,backend,admin,movil # todo, incluida la app en Chrome
.\levantar.ps1 -Detener                     # apaga todo
```

Levanta Postgres en Docker (contenedor `legacy_db`, credenciales `dba`/`123`, base `applegacy`), carga el esquema solo si la base está vacía, y abre cada servidor en su propia ventana. Existe también un hook en `.claude/settings.json` que ejecuta el script cuando el usuario escribe "levantar legacy" o "bajar legacy".

## Desplegar

Cada módulo tiene su propia guía en `<módulo>/DESPLIEGUE.md`, con los pasos, las verificaciones y las trampas propias de cada uno. Consúltala antes de tocar nada relacionado con producción.

En el servidor conviven tres contenedores en la red Docker externa `proxy-net`, detrás de un HAProxy con Let's Encrypt que **vive en un proyecto aparte, fuera de este monorepo**: `legacy_frontend` (el panel Angular en la raíz de `https://legacy.intelyclick.com`), `legacy_backend` (la API en `/api/...`) y `legacy_db`. Ni el backend ni el frontend publican puertos en el host.

Ninguno de los dos `Dockerfile` compila: ambos copian artefactos ya construidos (`server_linux` y `dist/legacy-app/browser`). Saltarse el paso de compilación publica la versión anterior sin ningún aviso.

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

Ese último paso es el que más se olvida: `ImageHandler.UploadImage` estuvo escrito y probado durante meses sin que nadie registrara su ruta, así que la carga de imágenes no existía en la práctica (resuelto el 2026-08-11). Cuando agregues un handler, verifica que su ruta aparezca en `main.go`.

Las rutas se agrupan en cuatro bloques: públicas sin auth, públicas con `OptionalAuthMiddleware`, privadas con `AuthMiddleware`, y admin con `AdminOnly`.

**Cifrado en reposo:** `security.CryptoService` (AES-256) cifra datos sensibles de usuarios, mensajes de chat y sinergias. Los servicios que reciben `cryptoService` cifran al escribir y descifran al leer — si añades una consulta que devuelva esos campos sin pasar por el servicio, obtendrás texto cifrado.

**El hub de chat vive en memoria** (`infrastructure/websocket`, arrancado con `go chatHub.Run()`). El backend no se puede escalar horizontalmente sin romper el chat.

**Los avisos push salen de dos sitios.** Las novedades —evento creado, contenido publicado— van al tópico `all` desde `handler/http/avisos.go`; el mensaje de chat va a los dispositivos del destinatario desde `core/services/chat_avisos.go`, con `SendToUser`, que no deja rastro en el historial del panel. Los dos mandan `{type, id}` en el `data` y la app los traduce a una pantalla en `domain/utils/notificacion_destino.dart`: al añadir un tipo nuevo hay que tocar ese archivo o la notificación abrirá la bandeja.

**Base de datos:** esquemas separados `core`, `events`, `community`, `chat` (35 tablas). `scripts/schema.sql` es un dump de `pg_dump` y **no es idempotente** (empieza con `CREATE SCHEMA chat;` sin `IF NOT EXISTS`): solo sirve para una base vacía. Los cambios posteriores van como migraciones fechadas en `scripts/AAAAMMDD_descripcion.sql`, documentando en la cabecera el contexto, los archivos afectados y el error concreto que corrigen — sigue el formato de `20260731_add_synergies_comments_count.sql`.

**Paginación.** Los listados que crecen sin techo paginan con `?limit=` y `?offset=`, y publican el
total en la cabecera `X-Total-Count` —no dentro del cuerpo: la respuesta sigue siendo un array plano
porque hay apps publicadas que lo recorren directamente—. El ayudante común es
`handler/http/paginacion.go`, con **techo de 200** se pida lo que se pida.

Ya paginaban mensajes de chat, publicaciones de foro, sinergias e historial de avisos. El 2026-08-26
se añadió a inscritos de un evento, usuarios y mensajes de contacto —los tres de `AdminOnly`, que es
lo que permitió poner tamaño de página por defecto sin romper ninguna app instalada—.

Dos cosas que conviene saber antes de paginar otro listado:

- **El `ORDER BY` tiene que ser total** (añadir el `id` de desempate). Sin él, dos filas del mismo
  instante pueden intercambiarse entre consultas y una página se salta una fila o repite otra.
- **Lo cifrado no se puede ordenar ni buscar en SQL.** Por eso los inscritos de un evento se ordenan
  por fecha y no por nombre, y por eso la pantalla que los busca pide todas las páginas
  (`getAllEventRegistrants`) en vez de una: buscar en la página visible diría «no está» de alguien que
  sí está, y el total recaudado mostraría una fracción.

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

**La URL de la API se resuelve en tiempo de ejecución, no en el build.** `ConfigService` carga `src/assets/config/config.json` con un `APP_INITIALIZER` (`app.config.ts`) y todos los servicios leen `this.config.apiUrl`; ese archivo ya apunta a producción y se puede cambiar sin recompilar. `src/environments/environment.ts` sigue existiendo con `http://localhost:8080` dentro, pero **ya no lo importa nadie**: `payment.service.ts`, que era el último, pasó a `ConfigService`. Comprobado el 2026-08-18. Si algún servicio nuevo lo importa, apuntará a localhost en producción; el arreglo es usar `ConfigService`, no crear `environment.prod.ts`.

Cuidado con la duplicación: `angular.json` copia `public/**` y `src/assets` al mismo destino, y ambos contienen un `assets/config/config.json`. Hoy son idénticos; si editas uno solo, no está definido cuál gana.

## Convenciones del proyecto

**Bitácora de QA.** Cada módulo tiene un `qa_bitacora.md` donde se registra cada entrega con este formato:

```
### [AAAA-MM-DD]: Título del cambio
- **Alcance:** archivos y rutas tocadas
- **Criterios de QA:** lista numerada de pasos verificables por una persona
```

Los informes puntuales van en `reports/AAAAMMDD_nombre.md`; los planes técnicos previos a implementar, en `App-Movil/docs/` e `App-Movil/implementaciones/`.

**Skills disponibles.** Cada repositorio versiona las suyas en `.claude/skills/`:

| Skill | Dónde | Para qué |
|---|---|---|
| `verificar-contratos-api` | raíz | cruzar las rutas del backend con las que llaman la app y el panel |
| `nuevo-endpoint` | `Backend/` | el corte vertical completo de un endpoint, hasta registrarlo en `main.go` |
| `nuevo-modulo-admin` | `Sitio-Administrativo/` | un módulo CRUD siguiendo el patrón de `features/admin/banners` |
| `preflight-release` | `App-Movil/` | comprobaciones antes de compilar o publicar un release |

Solo la de la raíz se carga al abrir Claude Code aquí; las de los módulos aparecen al trabajar dentro de su carpeta, que es como se usan esos repositorios por separado.

## Desalineaciones conocidas

Al tocar estas zonas, ten presente que ya están rotas:

- El chat es estrictamente 1:1 (`chat.connections` con `requester_id`/`receiver_id`). No existe chat grupal; los "grupos" (`core.custom_groups`) sirven solo para segmentar envíos push. **El chat grupal está fuera de alcance por decisión del cliente** (2026-08-14): no es una tarea pendiente. Si alguna vez se retoma, lo caro no son las pantallas sino tres puntos del modelo —`is_read` es un booleano por mensaje y no modela lectura por participante, `connections` es a la vez la conversación y sus dos miembros, y el bloqueo esconde la conversación entera—.
- Sin `firebase-service-account.json` en `Backend/`, FCM arranca en modo mock y las notificaciones se escriben en consola en lugar de enviarse.
- El botón de **Legacy Test** (`App-Movil/lib/presentation/screens/comunidad/comunidad_screen.dart:94`) no hace nada al tocarlo, y está así en producción. **Se deja a propósito** —decisión del 2026-08-14— hasta que el cliente confirme si esa funcionalidad es necesaria: retirarlo obligaría a rehacerlo si la respuesta es que sí. Es el único `TODO` que queda en los tres repositorios de código; no lo trates como un descuido.

## Seguridad

**Los cuatro repositorios son públicos.** Todo lo que se versione queda expuesto: antes de añadir un archivo con configuración, comprueba que esté cubierto por el `.gitignore` del módulo. Hoy están protegidos `Backend/{config.yaml, config.docker.yaml, .env, *-service-account.json}`, `App-Movil/android/{key.properties, api-key.json, **/*.jks}` y, en la raíz, `reports/` y `docs/`.

`config.yaml` y `config.docker.yaml` contienen secretos reales en texto plano (contraseña de Postgres, credenciales de Credibanco). No propagues esos valores a archivos nuevos ni los incluyas en salidas; si trabajas en configuración, muévelos a variables de entorno. El `.env` ya solo lleva datos de conexión (`SERVER_IP`, `SSH_USER`, `DEPLOY_DIR`): `SSH_PASS` se retiró el 2026-08-10.

**Los dos secretos de producción se rotaron el 2026-08-13.** El `jwt_secret` era el de ejemplo, así que cualquiera podía emitirse un token de `admin`. La `encryption_key` exigió además recifrar la base con `cmd/recifrar`, en una sola transacción: nueve columnas de `core.users`, `chat.messages.content_encrypted` y el contacto de los inscritos, **más recalcular `email_blind_index`** —un HMAC con esa misma clave, del que depende el inicio de sesión por correo—. Si hay que volver a rotarla, el procedimiento y sus trampas están en `Backend/DESPLIEGUE.md`; ninguna de las dos claves se reproduce en este repositorio, que es público.

**`config.docker.yaml` no está versionado y se edita en los dos sitios**, así que la copia local y la del servidor se desincronizan sin que nada avise. Compara los `sha256sum` antes de cualquier `scp`; la copia buena es la del servidor. Ya pasó una vez: `apple.bundle_id` se añadió solo allí y el siguiente despliegue lo habría borrado.

Las consultas SQL están parametrizadas. Sigue sin haber sanitización de HTML ni protección CSRF.

**El CORS ya no está abierto.** `main.go` usa `AllowOriginFunc: origenPermitido`, que acepta
`https://legacy.intelyclick.com` y cualquier `localhost`. Comprobado contra producción el 2026-08-26:
un `OPTIONS` con `Origin: https://sitio-malicioso.com` no recibe cabecera
`Access-Control-Allow-Origin` —el navegador lo bloquea— y el origen legítimo sí, con
`Allow-Credentials: true`. La app móvil no se ve afectada: un cliente nativo no manda `Origin` y CORS
no interviene. Si el panel o la app web se publican en otro dominio, hay que añadirlo a
`origenesDeConfianza` o dejarán de funcionar.
