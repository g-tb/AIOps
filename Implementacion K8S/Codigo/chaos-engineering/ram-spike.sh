#!/bin/sh
# Chaos: RAM spike en pod. Uso: ./ram-spike.sh [deployment] [MB] [segundos]
# Retiene MB de memoria en un proceso durante los segundos indicados y la libera al
# terminar. /dev/shm mide 64 MB en los contenedores, por eso no se usa un archivo.
DEPLOY="${1:-pharmago-api-gateway}"
MB="${2:-300}"
SECS="${3:-120}"
POD=$(kubectl get pod -n pharmago -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "Error: no hay pods con app=$DEPLOY en el namespace pharmago."
  exit 1
fi
echo "RAM spike: $POD (${MB}MB durante ${SECS}s)"
kubectl exec -n pharmago "$POD" -- sh -c "(head -c ${MB}M /dev/zero; sleep $SECS) | tail > /dev/null"
echo "Listo: memoria liberada en $POD"
