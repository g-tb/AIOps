#!/usr/bin/env bash
# Reserva RAM real hasta ~88% del limite de memoria del nodo (minikube), con un maximo explicito.
set -Eeuo pipefail
if [[ ${1:-} == --help ]]; then
    echo 'Uso: bash memoria-elevada.sh [maximo-MiB=4096] | --restore. Mantiene la RAM por 180 segundos.'
    exit 0
fi
[[ $# -le 1 ]] || exit 1
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
CONTEXTO=${PHARMAGO_CONTEXT:-minikube}
[[ $(kubectl config current-context) == "$CONTEXTO" ]] || { echo "Selecciona el contexto $CONTEXTO o define PHARMAGO_CONTEXT."; exit 1; }
POD=caos-alerta-memoria
limpiar() { kubectl delete pod "$POD" -n pharmago --ignore-not-found --wait=true; }
if [[ ${1:-} == --restore ]]; then limpiar; exit; fi
MAXIMO=${1:-4096}
[[ $MAXIMO =~ ^[1-9][0-9]{0,5}$ ]] || { echo 'Indica un maximo en MiB.'; exit 1; }
[[ -z $(kubectl get pods -n pharmago -l caos=alertas -o name) ]] || { echo 'Termina la otra prueba primero.'; exit 1; }
[[ $(kubectl get nodes --no-headers | grep -c .) == 1 ]] || { echo 'Requiere un unico nodo.'; exit 1; }
trap limpiar EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# El pod lee el cgroup del nodo (el contenedor de minikube) por /sys en solo lectura: la
# alerta mide contra ese limite, no contra MemTotal, que es la memoria de la VM o del host.
# Sin requests ni limits queda BestEffort: si falta memoria, el kernel lo mata primero.
kubectl run "$POD" -n pharmago --image=python:3.12-alpine --restart=Never \
    --labels=caos=alertas --override-type=strategic \
    --overrides='{"spec":{"activeDeadlineSeconds":300,"terminationGracePeriodSeconds":5,"containers":[{"name":"caos-alerta-memoria","image":"python:3.12-alpine","volumeMounts":[{"name":"sys","mountPath":"/nodo/sys","readOnly":true}]}],"volumes":[{"name":"sys","hostPath":{"path":"/sys"}}]}}' \
    --command -- python -u -c '
import sys, time

MIB = 1024**2
CGROUP = "/nodo/sys/fs/cgroup/"

def leer(nombre):
    try:
        with open(CGROUP + nombre) as archivo:
            return archivo.read().strip()
    except OSError:
        return None

def meminfo():
    with open("/proc/meminfo") as archivo:
        return {l.split()[0].rstrip(":"): int(l.split()[1]) * 1024 for l in archivo}

def estado():
    """Working set y limite del cgroup del nodo, como los calcula la alerta."""
    info = meminfo()
    total = info["MemTotal"]
    if leer("memory.current") is not None:  # cgroup v2
        uso, stat, clave, limite = leer("memory.current"), leer("memory.stat"), "inactive_file", leer("memory.max")
    else:  # cgroup v1
        uso, stat, clave, limite = (leer("memory/memory.usage_in_bytes"), leer("memory/memory.stat"),
                                    "total_inactive_file", leer("memory/memory.limit_in_bytes"))
    if uso is None or stat is None:  # sin cgroup propio (driver de VM): la memoria de la maquina
        return total - info["MemAvailable"], total
    inactiva = next((int(l.split()[1]) for l in stat.splitlines() if l.split()[0] == clave), 0)
    limite = int(limite) if limite and limite.isdigit() and int(limite) < total else total
    return max(0, int(uso) - inactiva), limite

uso, limite = estado()
necesario = int(limite * 0.88) - uso
maximo = int(sys.argv[1]) * MIB
print(f"Nodo: {uso // MIB} de {limite // MIB} MiB ({100 * uso / limite:.0f} %). "
      f"Para llegar a 88 %: {max(0, necesario) // MIB} MiB; maximo del script: {sys.argv[1]} MiB", flush=True)
if necesario <= 0:
    sys.exit("El nodo ya supera el objetivo; revisa su consumo antes de probar.")
if necesario > maximo:
    sys.exit("No se reserva RAM: supera el maximo. Si el nodo tiene margen, pasa uno mayor.")

def seguro():
    return estado()[0] < limite * 0.92

bloques = []
try:
    while necesario > 0:
        if not seguro():
            sys.exit("Se detiene: el nodo supera el 92 % de su limite.")
        cantidad = min(necesario, 8 * MIB)
        bloques.append(bytearray(b"\x01") * cantidad)  # escribe cada pagina: RAM real
        necesario -= cantidad
        time.sleep(0.05)
    print("RAM reservada por 180 segundos", flush=True)
    for _ in range(180):
        if not seguro():
            sys.exit("Se libera la memoria: el nodo supero el 92 % de su limite.")
        time.sleep(1)
finally:
    bloques.clear()
' "$MAXIMO"
kubectl logs -n pharmago -f "$POD" --pod-running-timeout=120s
kubectl wait -n pharmago --for=jsonpath='{.status.phase}'=Succeeded "pod/$POD" --timeout=15s
