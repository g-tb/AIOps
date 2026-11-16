# Chaos Engineering

Requiere: app en K8s + port-forward activo.

| Script | Uso |
|--------|-----|
| `cpu-spike.sh` | `./cpu-spike.sh [deploy] [seg]` |
| `ram-spike.sh` | `./ram-spike.sh [deploy] [MB] [segundos]` (por defecto 300 MB durante 120 s; se libera sola) |
| `volume-spike.sh` | `./volume-spike.sh [deploy] [MB]` |
| `load-requests.sh` | `./load-requests.sh [N] [url]` |
| `network-chaos.sh` | `bash network-chaos.sh [deploy] [loss\|delay] [segundos]` (por defecto un pod de pharmacy, `loss`, 120 s). Ver abajo |

Default deploy: pharmago-api-gateway

**Ver impacto en Grafana:** Dashboard "PharmaGo - Infra" → paneles "CPU por pod (pharmago)" y "Memoria por pod (pharmago)".

## Interrupción de red: `network-chaos.sh`

Aplica `tc netem` a **un** pod del deployment (por defecto `pharmago-pharmacy-service`), desde un
contenedor efímero (`kubectl debug --profile=netadmin`, imagen `nicolaka/netshoot:v0.13`).

- **`loss`:** 100 % de pérdida de paquetes. El pod queda incomunicado: la readiness lo saca
  del tráfico, la otra réplica atiende y la liveness reinicia el contenedor (la regla sigue,
  porque vive en la red del pod).
- **`delay`:** `DELAY_MS` (300 por defecto) de demora en cada paquete que sale del pod.
- **Limpieza:** al terminar o con Ctrl+C borra la regla con otro contenedor efímero; si no
  puede, borra el pod. Si se cortó a la fuerza: `bash network-chaos.sh --restore <pod>`.
- **Requisitos:** el kernel del nodo tiene que traer `sch_netem` (el de Docker Desktop con
  WSL2 lo trae) y la primera vez se baja la imagen: `minikube image pull nicolaka/netshoot:v0.13`.
- Los contenedores efímeros terminados quedan en el pod hasta que se borre: Kubernetes no
  permite quitarlos.
- **Dónde se ve:** War room → fila "Interrupción de red" ("Red recibida/enviada por pod") y
  "Endpoints listos por Service"; `kubectl get pods -n pharmago -w`.
