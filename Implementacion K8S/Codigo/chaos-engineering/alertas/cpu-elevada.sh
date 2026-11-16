#!/usr/bin/env bash
# Ocupa los CPU del nodo durante cuatro minutos. No modifica la aplicacion.
# Lanza un proceso por CPU visible: si la VM tiene mas CPU que la cuota de minikube
# (--cpus), igual la satura, que es lo que mide la alerta.
set -Eeuo pipefail
if [[ ${1:-} == --help ]]; then
    echo 'Uso: bash cpu-elevada.sh [--restore]. Carga de CPU por 240 segundos en Minikube.'
    exit 0
fi
[[ $# == 0 || ( $# == 1 && $1 == --restore ) ]] || exit 1
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
CONTEXTO=${PHARMAGO_CONTEXT:-minikube}
[[ $(kubectl config current-context) == "$CONTEXTO" ]] || { echo "Selecciona el contexto $CONTEXTO o define PHARMAGO_CONTEXT."; exit 1; }
POD=caos-alerta-cpu
limpiar() { kubectl delete pod "$POD" -n pharmago --ignore-not-found --wait=true; }
if [[ ${1:-} == --restore ]]; then limpiar; exit; fi
[[ -z $(kubectl get pods -n pharmago -l caos=alertas -o name) ]] || { echo 'Termina la otra prueba primero.'; exit 1; }
[[ $(kubectl get nodes --no-headers | grep -c .) == 1 ]] || { echo 'Requiere un unico nodo.'; exit 1; }
trap limpiar EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

kubectl run "$POD" -n pharmago --image=python:3.12-alpine --restart=Never \
    --labels=caos=alertas --overrides='{"spec":{"activeDeadlineSeconds":360,"terminationGracePeriodSeconds":5}}' \
    --command -- python -u -c '
import multiprocessing as mp
import os, time

def ocupar_cpu():
    os.nice(10)  # Dar preferencia a Prometheus, Grafana y el resto del nodo.
    while True:
        pass

procesos = [mp.Process(target=ocupar_cpu) for _ in range(os.cpu_count())]
try:
    for proceso in procesos:
        proceso.start()
    print("CPU ocupada durante 240 segundos", flush=True)
    time.sleep(240)
finally:
    for proceso in procesos:
        if proceso.pid:
            proceso.terminate()
            proceso.join()
'
kubectl logs -n pharmago -f "$POD" --pod-running-timeout=120s
kubectl wait -n pharmago --for=jsonpath='{.status.phase}'=Succeeded "pod/$POD" --timeout=15s
