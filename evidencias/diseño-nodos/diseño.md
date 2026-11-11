| Módulo | Label de nodo permitido por affinity | Taint dedicado que tolera | Ubicación prevista en multinodo |
|---|---|---|---|
| UsersService | `node-type=users` o `all` | `dedicated=users:NoSchedule` | Nodo Users |
| PharmacyService | `node-type=pharmacy` o `all` | `dedicated=pharmacy:NoSchedule` | Nodo Pharmacy |
| API Gateway | `node-type=gateway` o `all` | `dedicated=gateway:NoSchedule` | Nodo Gateway |
| Frontend | `node-type=frontend` o `all` | `dedicated=frontend:NoSchedule` | Nodo Frontend |
| SQL Server | `node-type=ops` o `all` | `dedicated=ops:NoSchedule` | Nodo Ops |
| Elasticsearch, Kibana | `node-type=ops` o `all` | `dedicated=ops:NoSchedule` | Nodo Ops |
| Prometheus, Grafana | `node-type=ops` o `all` | `dedicated=ops:NoSchedule` | Nodo Ops |
| OTLP Collector, Infra Collector, Jaeger | `node-type=ops` o `all` | `dedicated=ops:NoSchedule` | Nodo Ops |
| Fluent Bit | Sin restricción por grupo | Cualquier taint con clave `dedicated` | Un agente por nodo |
| Node Exporter | Sin restricción por grupo | Cualquier taint | Un agente por nodo |