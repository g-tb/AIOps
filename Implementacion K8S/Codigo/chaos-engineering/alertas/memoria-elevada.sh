#!/usr/bin/env bash
# Reserva RAM real hasta aproximar 88% de uso del nodo, con un limite explicito.
set -Eeuo pipefail
if [[ ${1:-} == --help ]]; then
    echo 'Uso: bash memoria-elevada.sh [maximo-MiB=1024] | --restore. Mantiene la RAM por 180 segundos.'
    exit 0
fi
[[ $# -le 1 ]] || exit 1
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
[[ $(kubectl config current-context) == minikube ]] || { echo 'Selecciona el contexto minikube.'; exit 1; }
POD=caos-alerta-memoria
limpiar() { kubectl delete pod "$POD" -n pharmago --ignore-not-found --wait=true; }
if [[ ${1:-} == --restore ]]; then limpiar; exit; fi
MAXIMO=${1:-1024}
[[ $MAXIMO =~ ^[1-9][0-9]{0,5}$ ]] || { echo 'Indica un maximo en MiB.'; exit 1; }
[[ -z $(kubectl get pods -n pharmago -l caos=alertas -o name) ]] || { echo 'Termina la otra prueba primero.'; exit 1; }
[[ $(kubectl get nodes -o name | wc -l) == 1 ]] || { echo 'Requiere un unico nodo.'; exit 1; }
trap limpiar EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

kubectl run "$POD" -n pharmago --image=python:3.12-alpine --restart=Never \
    --labels=caos=alertas --overrides='{"spec":{"activeDeadlineSeconds":300,"terminationGracePeriodSeconds":5}}' \
    --command -- python -u -c '
import sys, time

def memoria():
    with open("/proc/meminfo") as archivo:
        return {linea.split()[0].rstrip(":"): int(linea.split()[1]) * 1024
                for linea in archivo if linea.startswith(("MemTotal:", "MemAvailable:"))}

datos = memoria()
necesario = max(0, int(datos["MemAvailable"] - datos["MemTotal"] * 0.12))
maximo = int(sys.argv[1]) * 1024**2
print(f"Necesario para 88%: {necesario // 1024**2} MiB; limite: {sys.argv[1]} MiB", flush=True)
if necesario == 0:
    sys.exit("El nodo ya supera el objetivo; revisa su consumo antes de probar.")
if necesario > maximo:
    sys.exit("No se reserva RAM: supera el limite. Revisa el nodo antes de aumentar el parametro.")

bloques = []
try:
    while necesario > 0:
        if memoria()["MemAvailable"] < datos["MemTotal"] * 0.10:
            sys.exit("Se detiene por reserva de seguridad inferior al 10%.")
        cantidad = min(necesario, 8 * 1024**2)
        bloques.append(bytearray(cantidad))
        necesario -= cantidad
        time.sleep(0.05)
    print("RAM reservada por 180 segundos", flush=True)
    for _ in range(180):
        if memoria()["MemAvailable"] < datos["MemTotal"] * 0.10:
            sys.exit("Se libera la memoria: el nodo bajo del 10% disponible.")
        time.sleep(1)
finally:
    bloques.clear()
' "$MAXIMO"
kubectl logs -n pharmago -f "$POD" --pod-running-timeout=120s
kubectl wait -n pharmago --for=jsonpath='{.status.phase}'=Succeeded "pod/$POD" --timeout=15s
