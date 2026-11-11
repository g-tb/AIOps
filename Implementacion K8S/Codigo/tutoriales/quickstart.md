# Quickstart K8s - PharmaGo

```bash
# 1. Minikube
minikube start --memory=8192 --cpus=4

# 2. Imágenes (desde Implementacion K8S/Codigo)
cd k8s
./build-images.sh

# 3. Desplegar
./apply-k8s.sh

# 4. Rollout del circuit-breaker (solo si tienen pod desactualizado)
kubectl rollout restart deployment/pharmago-users-service deployment/pharmago-pharmacy-service deployment/pharmago-api-gateway deployment/pharmago-ui -n pharmago

# 4. Port-forward (Windows: usar 127.0.0.1)
./port-forward.sh
```

**URLs:** http://127.0.0.1:4200 | :5000 | :3000 | :5601 | :9090
