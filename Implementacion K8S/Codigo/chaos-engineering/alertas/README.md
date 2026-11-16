# Probar e investigar las ocho alertas

Los ocho scripts de esta carpeta corresponden a las reglas de `k8s/alerting/pharmago-alerts.yaml`. No cambian sus consultas, umbrales ni tiempos. Los scripts anteriores de `chaos-engineering/` siguen disponibles, pero cargar un solo pod no garantiza disparar una alerta del nodo completo.

## Cómo ejecutar

Desde Git Bash, ubicado en esta carpeta:

```bash
kubectl config current-context
bash cpu-elevada.sh
```

Requieren contexto `minikube`, namespace `pharmago`, `kubectl`, Bash y acceso a Internet desde el nodo para descargar las imágenes de prueba. CPU, memoria y disco requieren un único nodo. Las imágenes son `python:3.12-alpine` y, para disco, `alpine:3.20` con herramientas ext4. No requieren port-forward para generar el fallo: el tráfico se genera dentro del clúster. Usá tus accesos existentes para ver Grafana, Prometheus y Kibana.

**Ejecutá una sola prueba a la vez**, con la aplicación sin otras cargas de prueba. Mantené abierta la terminal. `Ctrl+C` ejecuta la recuperación; si cerraste la terminal o se interrumpió la conexión, ejecutá el mismo archivo con `--restore`. Los pods temporales tienen un tiempo máximo de vida, pero ese límite no restaura por sí solo un Service ni las réplicas del Collector: para esos casos ejecutá `--restore`.

| Alerta | Archivo | Condición actual | Duración de la prueba |
|---|---|---|---|
| CPU elevada del nodo | `cpu-elevada.sh` | Uso >85% por 1 minuto, con ventana de 2 minutos | 4 minutos |
| Memoria elevada del nodo | `memoria-elevada.sh` | Uso >85% por 1 minuto | 3 minutos después de reservar RAM |
| Poco espacio disponible en disco | `disco-bajo.sh` | Disponible <15% por 1 minuto | 6 minutos desde el montaje |
| Rechazos elevados por rate limiting | `rate-limiting.sh` | Más de 0,1 HTTP 429/s por 30 segundos, ventana de 2 minutos | 4 minutos |
| Collector OTLP inaccesible | `collector-inaccesible.sh` | `1 - up` >0,5 por 30 segundos | 2 minutos con Collector detenido |
| Alta tasa de errores de la API | `errores-api.sh` | Errores >5% por 5 minutos, ventana de 5 minutos | 10 minutos |
| Latencia P95 elevada de la API | `latencia-api.sh` | P95 >1000 ms por 5 minutos, ventana de 5 minutos | 10 minutos |
| Servicio de aplicación inaccesible | `servicio-inaccesible.sh` | `up` <0,5 por 1 minuto | 2 minutos y medio |

Los tiempos no incluyen descarga de imágenes ni preparación. La evaluación de Grafana es cada 10 segundos; el scraping y la exportación OTLP añaden demora. La carga habitual del nodo puede impedir alcanzar un umbral. El script genera la condición; **confirmá en Grafana que la regla llegue a Firing**, no solamente que el script finalice.

## Qué hacer en todas las pruebas

1. Abrí **Grafana → Alerting → Alert rules**. Revisá la regla, sus etiquetas y su valor antes de ejecutar. Debería comenzar en Normal; si ya está Firing, investigá primero la condición existente.
2. Abrí Prometheus en Graph y ejecutá la consulta de la sección correspondiente. Usá un rango de 15–30 minutos y observá cómo cruza el umbral.
3. Ejecutá el script. Verificá la secuencia **Normal → Pending → Firing**. `Pending` significa que se superó el umbral, pero todavía no pasó todo el tiempo requerido. `No Data` o `Error` no prueban el disparo de la condición.
4. En Kibana, abrí **Discover**, data view `pharmago-logs-*`, campo temporal `@timestamp`, lenguaje **KQL**, últimos 15–30 minutos y actualización automática. Filtrá al intervalo exacto del incidente. Los logs pueden llegar con algunos segundos de atraso.
5. Cuando termine, verificá la recuperación en Prometheus y Grafana. Para tasas y percentiles, los datos de la prueba permanecen en la ventana de 2 o 5 minutos. Para errores/latencia conviene generar tráfico sano después; sin peticiones, el resultado puede pasar a `No Data` en vez de a Normal.

Las consultas de Prometheus bajo **Confirmar la alerta** reproducen las reglas actuales. Las de **Investigar** desglosan la causa. `rate()` expresa eventos por segundo y `histogram_quantile()` estima el percentil a partir de los buckets: no es el tiempo de una petición individual. [Referencia de Prometheus](https://prometheus.io/docs/prometheus/latest/querying/functions/).

Los logs reales tienen `kubernetes.labels.app`, `kubernetes.namespace_name` y `log`. Las líneas JSON de .NET también pueden tener `Message`, `LogLevel`, `Category`, `State` y `Scopes`. Las líneas de texto plano no tienen necesariamente esos campos. Por eso se incluyen búsquedas con `Message` y `log`. [Sintaxis KQL](https://www.elastic.co/docs/reference/query-languages/kql).

## 1. CPU elevada del nodo

```bash
bash cpu-elevada.sh
# Recuperación manual si fuera necesaria:
bash cpu-elevada.sh --restore
```

**Qué provoca:** procesos de cálculo en todos los CPU visibles del nodo durante 240 segundos. Se les da menor prioridad para favorecer a los procesos de monitoreo. Se eliminan al finalizar. Puede ralentizar toda tu aplicación y disparar también latencia.

**Gráficas:** CPU del nodo en Node Exporter Full y CPU por pod en PharmaGo - Infra. El 85% es el promedio del nodo, no el porcentaje de un solo contenedor.

**Confirmar la alerta — porcentaje usado:**

```promql
100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{job="node-exporter", mode="idle"}[2m])))
```

**Investigar — CPU consumido por pod, en núcleos:**

```promql
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="pharmago", pod!="", container=""}[2m]))
```

Un valor de `1` equivale aproximadamente a un núcleo ocupado. Identificá el pod que subió al mismo tiempo que el nodo. En tu cAdvisor actual, las series agregadas por pod tienen `pod` y `namespace`, pero no `container`; por eso se usa `container=""` y se evita sumar también los contenedores hijos.

**Kibana — errores que acompañan la saturación:**

```kql
kubernetes.namespace_name: "pharmago" and (LogLevel: (Error or Warning) or log: "timeout" or log: "Exception")
```

**Qué revisar y hacer:** detené la prueba; en un incidente real, buscá qué pod concentra CPU, si aumentó el tráfico y si hay reintentos o procesos costosos. Usá `kubectl top pods -n pharmago` y `kubectl top node` si Metrics Server está disponible. Revisá requests y limits antes de cambiarlos. En un único nodo, agregar réplicas no agrega CPU al equipo. Kibana puede mostrar timeouts, pero los logs no miden el porcentaje de CPU: esa evidencia viene de Prometheus.

## 2. Memoria elevada del nodo

```bash
bash memoria-elevada.sh
bash memoria-elevada.sh --restore
```

**Qué provoca:** calcula cuánta RAM falta para aproximarse a 88% usado y la reserva por 180 segundos. Por defecto permite como máximo **1024 MiB adicionales**. Si no alcanza, informa cuánto se necesita y sale sin reservar. Podés pasar otro máximo, por ejemplo `bash memoria-elevada.sh 1536`, después de revisar la capacidad de tu equipo. No aumentes el máximo a ciegas. El script libera RAM si detecta menos de 10% disponible; Kubernetes también podría expulsar el pod de prueba por presión de memoria.

**Gráficas:** RAM del nodo en Node Exporter Full y memoria por pod en PharmaGo - Infra.

**Confirmar la alerta — porcentaje usado:**

```promql
100 * (1 - node_memory_MemAvailable_bytes{job="node-exporter"} / node_memory_MemTotal_bytes{job="node-exporter"})
```

**Investigar — memoria de trabajo por pod, en bytes:**

```promql
sum by (pod) (container_memory_working_set_bytes{namespace="pharmago", pod!="", container=""})
```

**Kibana — excepciones de memoria o fallos posteriores:**

```kql
kubernetes.namespace_name: "pharmago" and (log: "OutOfMemoryException" or log: "OOM" or LogLevel: Error)
```

**Qué revisar y hacer:** detené el consumidor, identificá qué pod crece y si se mantiene creciendo aun sin tráfico. Revisá `kubectl get pods -n pharmago` y `kubectl describe pod NOMBRE -n pharmago`: buscá `OOMKilled`, reinicios y eventos de expulsión. El kernel puede matar un proceso sin que alcance a escribir un log; por eso una búsqueda vacía en Kibana no descarta falta de memoria. Revisá fugas, cachés, consultas que cargan demasiado y límites del contenedor. Más réplicas en el mismo nodo pueden empeorar el consumo.

## 3. Poco espacio disponible en disco

```bash
bash disco-bajo.sh
bash disco-bajo.sh --restore
```

**Qué provoca:** monta un ext4 temporal de **128 MiB** en `/tmp/caos-alerta-disco/montaje` del nodo y escribe 100 MiB dentro. El espacio disponible de ese filesystem queda por debajo de 15%. Se elimina el archivo de relleno junto con su filesystem al desmontar y eliminar la imagen. No se llena el disco de datos del equipo. En tu configuración se observaron cientos de GiB libres; llenar ese disco no sería una prueba razonable.

El pod temporal necesita privilegios y propagación de montajes. Reinicia solamente el pod de **node-exporter** para que vea el nuevo montaje. Esto produce una interrupción breve de métricas del nodo. Si tu runtime no permite montar loop/ext4 o propagar el montaje, la prueba falla: revisá `kubectl logs caos-alerta-disco -n pharmago` mientras exista y no intentes llenar el disco principal como sustituto.

**Gráficas:** espacio disponible por filesystem en Node Exporter Full. Buscá el montaje temporal; puede no aparecer en un panel que solo muestre `/`.

**Confirmar la alerta — porcentaje disponible:**

```promql
100 * node_filesystem_avail_bytes{job="node-exporter", fstype=~"ext4|xfs|btrfs"}
/ node_filesystem_size_bytes{job="node-exporter", fstype=~"ext4|xfs|btrfs"}
```

**Investigar — aislar el filesystem de prueba:**

```promql
100 * node_filesystem_avail_bytes{job="node-exporter", mountpoint="/tmp/caos-alerta-disco/montaje"}
/ node_filesystem_size_bytes{job="node-exporter", mountpoint="/tmp/caos-alerta-disco/montaje"}
```

**Kibana — errores de escritura en un incidente real:**

```kql
kubernetes.namespace_name: "pharmago" and (log: "No space left on device" or log: "disk" or log: "read-only file system")
```

Para los mensajes de esta prueba:

```kql
kubernetes.pod_name: "caos-alerta-disco"
```

**Qué revisar y hacer:** identificá `device` y `mountpoint` de la instancia de alerta. Revisá `df -h` y `df -i` en el nodo (`minikube ssh`). En un incidente real, localizá crecimiento de logs, imágenes, datos de Elasticsearch o volúmenes; revisá retención y capacidad antes de borrar nada. Varias alertas sobre `/dev/sdd` pueden ser distintos montajes del mismo disco, no varios discos llenos. La prueba no debería causar errores de disco en tus servicios porque solo ocupa el filesystem aislado.

**Recuperación excepcional:** normalmente `--restore` termina el pod con gracia y desmonta. Si se mató a la fuerza el pod o se cayó el nodo y quedó el montaje, verificá primero con `minikube ssh -- "findmnt /tmp/caos-alerta-disco/montaje"`. Cuando ya no exista el pod de prueba, desmontá únicamente esa ruta con `minikube ssh -- "sudo umount /tmp/caos-alerta-disco/montaje"` y eliminá únicamente la imagen temporal con `minikube ssh -- "sudo rm -f /tmp/caos-alerta-disco/prueba.img"`. No elimines una imagen que siga montada. Al desaparecer el filesystem, su serie y su instancia de alerta desaparecen; no esperes que siga mostrando un porcentaje saludable.

## 4. Rechazos elevados por rate limiting

```bash
bash rate-limiting.sh
bash rate-limiting.sh --restore
```

**Qué provoca:** envía GET a `/api/roles/ping` a través del Gateway desde la misma IP de un pod. Tu configuración actual permite 100 solicitudes/minuto por IP; al superarla deberían aparecer HTTP 429. El límite está en memoria en cada réplica, por eso no siempre empieza en el mismo número de peticiones. No se hacen compras ni se crean usuarios.

**Gráficas:** tráfico, errores por código y tasa de errores en Extended Summary. La gráfica de porcentaje de errores y esta alerta pueden subir a la vez porque 429 es un 4xx.

**Confirmar la alerta — rechazos por segundo:**

```promql
sum(rate(pharmago_http_requests_total{job="otlp-collector", exported_job="PharmaGo.ApiGateway", status_code="429"}[2m])) or vector(0)
```

**Investigar — rutas rechazadas:**

```promql
sum by (endpoint) (rate(pharmago_http_requests_total{exported_job="PharmaGo.ApiGateway", status_code="429"}[2m]))
```

**Kibana — mensajes del limitador:**

```kql
kubernetes.labels.app: "pharmago-api-gateway" and (Message: "Rate limit" or log: "Rate limit" or log: "429")
```

**Kibana — respuestas observadas por el generador:**

```kql
kubernetes.pod_name: "caos-alerta-rate-limit" and log: "HTTP 429"
```

**Qué revisar y hacer:** detené el generador; confirmá que vuelven los 200 cuando termina la ventana del limitador. En un incidente real, buscá reintentos de un cliente, bots, un pico legítimo o varias personas compartiendo IP. Revisá las reglas y los headers de IP antes de aumentar límites. `pharmago_http_requests_total` no tiene una etiqueta de IP/usuario: esa investigación requiere logs que efectivamente los registren. En modo IP no está garantizado un log por rechazo al nivel configurado; la métrica y las respuestas del generador siguen siendo evidencia válida.

## 5. Collector OTLP inaccesible

```bash
bash collector-inaccesible.sh
bash collector-inaccesible.sh --restore
```

**Qué provoca:** cambia temporalmente de una réplica a cero el Deployment `otlp-collector`, espera 120 segundos sin Collector y restaura una réplica. Se exige la configuración original de una réplica antes de comenzar. No cambia puertos. La interrupción afecta métricas OTLP y trazas; puede haber pérdida de telemetría y otras gráficas/reglas pueden quedar en `No Data`. Fluent Bit envía los logs a Elasticsearch por separado y debería seguir funcionando.

**Gráficas:** `up` del Collector o estado del target en Prometheus → Status → Targets. Un panel de aplicación vacío durante la caída no significa cero tráfico.

**Confirmar la alerta — 1 significa fallo:**

```promql
1 - up{job="otlp-collector"}
```

**Investigar — comparar los destinos de scraping:**

```promql
up
```

**Kibana — exportadores y Collector:**

```kql
kubernetes.namespace_name: "pharmago" and (kubernetes.labels.app: "otlp-collector" or log: "export" or log: "connection refused")
```

**Qué revisar y hacer:** verificá `kubectl get deploy,pods,svc -n pharmago`, los eventos y `kubectl logs deployment/otlp-collector -n pharmago --tail=100`. Revisá el error del target en Prometheus, el Service, sus EndpointSlices y los puertos configurados antes de asumir que falló la instrumentación. Esta alerta comprueba el endpoint de scraping `8889`: no valida por sí sola todo el protocolo OTLP ni Jaeger. En esta prueba corresponde restaurar la réplica; en un fallo real, corregí la causa indicada por logs/eventos, por ejemplo configuración inválida, OOM o falta de recursos. El Collector detenido no puede producir logs nuevos: mirá los inmediatamente anteriores a su caída.

## 6. Alta tasa de errores de la API

```bash
bash errores-api.sh
bash errores-api.sh --restore
```

**Qué provoca:** envía dos GET por segundo directamente a una ruta inexistente de Users: `/api/caos-alerta-no-existe`. Produce 404 sin pasar por el rate limiter. Mantiene el tráfico 10 minutos para cubrir la ventana y el tiempo pendiente de la regla. Incluye 4xx porque así está definida tu alerta; no es exclusivamente una alerta de errores 500.

**Gráficas:** porcentaje de errores y errores por código de Extended Summary. Un 404 esperado de la prueba cuenta como error para esta regla.

**Confirmar la alerta — porcentaje global de errores de rutas API:**

```promql
(sum(rate(pharmago_http_errors_total{endpoint=~"/api/.*"}[5m])) or vector(0))
/ sum(rate(pharmago_http_requests_total{endpoint=~"/api/.*"}[5m])) * 100
```

**Investigar — servicio, endpoint y código:**

```promql
sum by (exported_job, endpoint, status_code) (
  rate(pharmago_http_requests_total{endpoint=~"/api/.*", status_code=~"4..|5.."}[5m])
)
```

El porcentaje actual agrega Gateway y servicios; una misma operación puede contarse en más de un salto. No lo interpretes como porcentaje de usuarios afectados.

**Kibana — causa técnica del servicio:**

```kql
kubernetes.labels.app: "pharmago-users-service" and (LogLevel: Error or log: "Exception" or log: "failed")
```

**Kibana — verificar los 404 de la prueba:**

```kql
kubernetes.pod_name: "caos-alerta-errores" and log: "HTTP 404"
```

**Qué revisar y hacer:** localizá la ruta y el código antes de reiniciar servicios. Para 404 revisá URL/rutas; para 401/403 autenticación y permisos; para 429 rate limiting; para 5xx excepciones, base de datos y dependencias. Un 404 puede no generar un log de error: el middleware lo cuenta en métricas, pero no escribe automáticamente un log por cada request. En un incidente real correlacioná los logs disponibles por tiempo, pod y `correlation_id` si figura en `Scopes` o en el mensaje.

**Recuperación:** detené la prueba y usá una ruta válida de Users o la aplicación durante al menos cinco minutos. Para evitar que el rate limiter contamine la recuperación, podés consultar una vez por segundo el puerto directo de Users usando el port-forward existente:

```bash
for i in {1..360}; do curl -sS -o /dev/null http://127.0.0.1:5001/api/roles/ping; sleep 1; done
```

Sin tráfico nuevo, la tasa puede acabar sin un porcentaje definido, por lo que `No Data` no demuestra recuperación.

## 7. Latencia P95 elevada de la API

```bash
bash latencia-api.sh
bash latencia-api.sh --restore
```

**Qué provoca:** crea un proxy temporal, lo conecta al Service de Users y añade dos segundos a cada GET `/api/`. El proxy reenvía al IP de un pod real de Users y deja `/metrics` sin demora. Después genera GET a `/api/roles/ping` a través del Gateway durante 10 minutos. El Gateway registra el tiempo real de espera: el P95 que debería superar 1000 ms es **PharmaGo.ApiGateway**, mientras Users procesa rápido la petición una vez que la recibe.

No cambia el código, las réplicas ni los puertos. Durante la prueba, el proxy está preparado para GET y rechaza escrituras con 503: evitá usar las funciones de modificación de Users. Al terminar o hacer Ctrl+C se restaura primero el selector del Service y luego se borra el proxy. Si el pod real de Users elegido se reinicia, la prueba puede fallar; restaurá y repetí con la aplicación estable.

**Gráficas:** P95 por servicio y latencia por endpoint en Extended Summary. El tiempo impreso por el script es el de cada petición de prueba; el P95 representa una ventana de todas las peticiones del servicio.

**Confirmar la alerta — P95 en milisegundos:**

```promql
histogram_quantile(0.95,
  sum by (le, exported_job) (
    rate(pharmago_http_request_duration_milliseconds_bucket{endpoint=~"/api/.*"}[5m])
  )
)
```

**Investigar — P95 por servicio y ruta:**

```promql
histogram_quantile(0.95,
  sum by (le, exported_job, endpoint) (
    rate(pharmago_http_request_duration_milliseconds_bucket{endpoint=~"/api/.*"}[5m])
  )
)
```

**Kibana — timeouts o fallos en los servicios afectados:**

```kql
kubernetes.labels.app: ("pharmago-api-gateway" or "pharmago-users-service") and (log: "timeout" or log: "Timeout" or log: "Exception" or LogLevel: Warning)
```

**Kibana — solicitudes que pasaron por el proxy:**

```kql
kubernetes.pod_name: "caos-alerta-latencia" and log: "GET /api/roles/ping"
```

**Qué revisar y hacer:** separá Gateway de servicio final y encontrá qué endpoint se volvió lento. Compará CPU, RAM, errores y tráfico en el mismo intervalo. Revisá dependencias, SQL, esperas de red, timeouts y reintentos; si necesitás el detalle de una operación usá también sus trazas en Jaeger. No alcanza con aumentar un timeout para solucionar la causa. La app no registra obligatoriamente cada duración en logs; una búsqueda vacía de timeouts es compatible con una petición lenta que termina con 200.

**Recuperación:** restaurá el selector y generá GET sanos por el Gateway (por ejemplo `/api/roles/ping` con tu puerto existente `5000`, una consulta cada 3 segundos para evitar 429). Esperá a que salgan de la ventana las peticiones lentas. Si no hay más tráfico, el P95 puede quedar sin datos en vez de bajar.

## 8. Servicio de aplicación inaccesible

```bash
bash servicio-inaccesible.sh
bash servicio-inaccesible.sh --restore
```

**Qué provoca:** cambia temporalmente el selector del Service de Users a una etiqueta sin pods. Prometheus deja de poder consultar `/metrics` a través de ese Service durante 150 segundos. Conserva las dos réplicas y sus datos; luego restaura exactamente el selector original, que valida antes de comenzar. Es una falla de enrutamiento/disponibilidad del Service, no un crash de .NET.

**Gráficas:** disponibilidad de servicios en Extended Summary y Status → Targets en Prometheus. Esta regla tiene una instancia por target de Service, no por cada réplica.

**Confirmar la alerta — 0 inaccesible, 1 accesible:**

```promql
up{job=~"users-service|pharmacy-service|api-gateway"}
```

**Investigar — tiempo de scraping por servicio:**

```promql
scrape_duration_seconds{job=~"users-service|pharmacy-service|api-gateway"}
```

**Kibana — consecuencias en Gateway o dependencias:**

```kql
kubernetes.labels.app: ("pharmago-api-gateway" or "pharmago-users-service") and (log: "connection refused" or log: "503" or log: "502" or LogLevel: Error)
```

**Qué revisar y hacer:** comprobá el error del target, `kubectl get pods -n pharmago`, `kubectl get svc pharmago-users-service -n pharmago -o yaml` y `kubectl get endpointslices -n pharmago -l kubernetes.io/service-name=pharmago-users-service`. En esta prueba verás pods sanos pero ningún endpoint elegido por el Service. Restaurá el selector. En un incidente real, diferenciá selector incorrecto, pods no Ready, reinicios, puerto equivocado o problema de red. No reinicies un pod sano para intentar corregir un selector incorrecto.

Si no hacés solicitudes mientras el Service está aislado, puede que no haya logs de error nuevos: Prometheus falla al conectarse, antes de llegar a la aplicación. `up=1` tras recuperar solo confirma que `/metrics` responde; probá también una función real de la aplicación.

## Verificación final

Después de cada prueba:

```bash
kubectl get pods -n pharmago -l caos=alertas
kubectl get deployment otlp-collector -n pharmago
kubectl get service pharmago-users-service -n pharmago -o jsonpath='{.spec.selector}'
```

No deberían quedar pods temporales. El Collector debe volver a una réplica y Users al selector `app: pharmago-users-service`. Los scripts no configuran notificaciones: si querés recibir los disparos en Discord, el contact point y la política deben estar configurados en tu Grafana.
