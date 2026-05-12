.PHONY: reconcile status helmreleases failing pods unhealthy events hr-reconcile hr-suspend hr-resume logs helm-logs kustomize-logs top debug logs-minecraft

# === Reconciliation ===

# Reconcile the cluster from git
reconcile:
	flux reconcile source git flux-cluster

# Reconcile a specific HelmRelease: make hr-reconcile NAME=grafana NS=monitoring
hr-reconcile:
	flux reconcile helmrelease $(NAME) -n $(NS)

# Suspend a HelmRelease: make hr-suspend NAME=grafana NS=monitoring
hr-suspend:
	flux suspend helmrelease $(NAME) -n $(NS)

# Resume a HelmRelease: make hr-resume NAME=grafana NS=monitoring
hr-resume:
	flux resume helmrelease $(NAME) -n $(NS)

# === Status ===

# Show overall Flux status (kustomizations, helmreleases, sources)
status:
	@echo "=== Kustomizations ==="
	@flux get kustomizations
	@echo ""
	@echo "=== HelmReleases ==="
	@flux get helmreleases -A
	@echo ""
	@echo "=== Sources ==="
	@flux get sources all

# Show all HelmReleases across all namespaces
helmreleases:
	flux get helmreleases -A

# Show failing HelmReleases only
failing:
	@flux get helmreleases -A | grep -v "True" || echo "All HelmReleases healthy"

# Show all pods
pods:
	kubectl get pods -A

# Show pods that aren't Running/Completed
unhealthy:
	@kubectl get pods -A | grep -v "Running\|Completed\|NAMESPACE" || echo "All pods healthy"

# Show recent events (useful for debugging scheduling/pull issues)
events:
	kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# Show resource usage per pod
top:
	kubectl top pods -A --sort-by=memory

# === Logs ===

# Show logs for a specific app: make logs APP=loki NS=monitoring
logs:
	kubectl logs -n $(NS) -l app.kubernetes.io/name=$(APP) --tail=50

# Show Helm controller logs (why a release failed)
helm-logs:
	kubectl logs -n flux-system -l app=helm-controller --tail=50

# Show kustomize controller logs (why a kustomization failed)
kustomize-logs:
	kubectl logs -n flux-system -l app=kustomize-controller --tail=50

# Minecraft logs
logs-minecraft:
	kubectl logs -n games -l app=minecraft-paper-minecraft -c minecraft-paper-minecraft -f

# === Debug ===

# Full debug view for a namespace: make debug NS=monitoring
debug:
	@echo "=== Pods ==="
	@kubectl get pods -n $(NS)
	@echo ""
	@echo "=== HelmReleases ==="
	@flux get helmreleases -n $(NS)
	@echo ""
	@echo "=== Services ==="
	@kubectl get svc -n $(NS)
	@echo ""
	@echo "=== Events ==="
	@kubectl get events -n $(NS) --sort-by='.lastTimestamp' | tail -15
