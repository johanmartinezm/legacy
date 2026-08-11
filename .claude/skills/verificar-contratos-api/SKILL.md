---
name: verificar-contratos-api
description: Cruza las rutas HTTP que registra el backend Go contra las que realmente llaman la app Flutter y el panel Angular, y detecta handlers implementados pero nunca enrutados. Usar antes de cerrar cualquier cambio que toque endpoints, al revisar un módulo completo, o cuando una función falla con 404 sin causa evidente.
---

# Verificar contratos de API entre backend y clientes

En este proyecto los tres módulos viven en repositorios separados y nada valida que las URLs
coincidan. El compilador de Go, `go vet` y `flutter analyze` no lo detectan: una ruta desalineada
solo se manifiesta como 404 en tiempo de ejecución, y a veces ni siquiera como error visible.

Casos reales que esta verificación detectó. Los resueltos se arreglaron **registrando también la
ruta que ya llamaba el cliente**, no cambiando el cliente: la app y el panel desplegados no se
actualizan a la vez que el servidor, así que quitar la ruta vieja rompería a quien no haya
actualizado. Por eso `main.go` registra hoy varias formas de la misma ruta a propósito.

| Cliente | Llama a | Estado |
|---|---|---|
| Flutter `auth_service.dart:98` | `/api/auth/social-login` | ✅ resuelto — `main.go:181` la registra junto a `/social-login` |
| Flutter `auth_service.dart:316` | `/api/auth/resend-verification` | ✅ resuelto — `main.go:183` |
| Angular `auth.service.ts:58` | `/api/verify-email` | ✅ resuelto — `main.go:187`, añadida por el panel ya desplegado |
| Flutter `forum_thread_screen.dart:90` | `/images/upload` | ❌ **vigente** — el backend no registra nada ahí |
| — | — | ❌ **vigente** — `ImageHandler.UploadImage` implementado y nunca registrado |

Los dos últimos son el mismo fallo visto desde los dos lados: la subida de imágenes de los foros
llama a un endpoint cuyo handler existe, compila y tiene tests, pero no está en `main.go`.

## Procedimiento

### 1. Extraer las rutas que registra el backend

```bash
grep -oE 'r\.(Get|Post|Put|Delete|Patch)\("[^"]+"' Backend/cmd/server/main.go \
  | sed 's/r\.//;s/("/ /;s/"//' | sort -u
```

**Cuidado con las rutas anidadas.** Las de chat se declaran dentro de un `r.Route("/api/chat", ...)`,
así que el grep anterior las devuelve como `/ws`, `/members`, etc. Hay que anteponerles el prefijo
del `Route` que las contiene. Revisa siempre los bloques `r.Route(` antes de concluir.

### 2. Extraer las llamadas de cada cliente

Flutter — combina rutas literales con las constantes de `lib/data/config/api_constants.dart`:

```bash
grep -rhoE "(baseUrl|_baseUrl)[^'\"]*['\"]?(/[a-zA-Z0-9/_{}\$-]+)" App-Movil/lib --include=*.dart \
  | grep -oE "/[a-zA-Z0-9/_{}\$-]+" | sort -u
cat App-Movil/lib/data/config/api_constants.dart
```

Angular — todas las llamadas pasan por `environment.apiUrl`:

```bash
grep -rhoE "apiUrl\}[^\`'\"]*" Sitio-Administrativo/src/app --include=*.ts | sed 's/apiUrl}//' | sort -u
```

### 3. Detectar handlers definidos pero no enrutados

```bash
grep -rhoE "func \(h \*[A-Za-z]+Handler\) [A-Z][A-Za-z]+" Backend/internal/handler/http/*.go \
  | awk '{print $NF}' | sort -u
```

Cada nombre de esa lista debe aparecer en `Backend/cmd/server/main.go`. El que no aparezca es
código muerto: existe, compila, puede tener tests, y es inalcanzable.

### 4. Comparar y reportar

Normaliza los parámetros de ruta antes de comparar: Go usa `{id}`, Flutter interpola `$id` y
Angular usa plantillas. Trata cualquiera de esas formas como equivalente.

Para cada discrepancia informa: archivo y línea del cliente, valor que usa, valor correcto, y qué
funcionalidad queda rota para el usuario final.

## Verifica contra el servidor cuando puedas

Si el entorno está levantado (`.\levantar.ps1`), confirma empíricamente en lugar de deducir:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080<ruta>
```

Un 404 confirma la desalineación. Un 401 o 403 significa que la ruta existe y solo falta
autenticación, así que **no** es una desalineación.

## Trampa conocida

Un 404 no siempre se ve como error. En `App-Movil/lib/domain/providers/auth_provider.dart:266` el
código interpreta el 404 del login social como "usuario no registrado" y deriva a la pantalla de
registro. Mientras la ruta estuvo desalineada, el fallo parecía comportamiento intencional, y por
eso nadie lo reportó durante meses. **Ese `if` sigue en el código**: la ruta ya responde, pero
cualquier 404 futuro de ese endpoint volvería a disfrazarse de "usuario nuevo". Cuando encuentres
una ruta rota, revisa además cómo trata el cliente ese código de estado.
