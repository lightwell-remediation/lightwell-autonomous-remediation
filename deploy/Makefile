# Cluster bootstrap for Lightwell Autonomous Remediation.
#
# Contract:   ../specs/platform/cluster-bootstrap.spec.md
# Decisions:  ../docs/adr/0006-cluster-bootstrap-topology.md
#
# Fresh cluster:  make deploy-all && make build-image && make validate

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

RELEASE   ?= lightwell-bootstrap
ARGO_NS   ?= openshift-gitops
AGENT_NS  ?= lightwell-agents
CHART     := gitops/bootstrap-infra

# Which cluster shape. cluster-plain installs the platform,
# cluster-rhoai-existing adopts an RHOAI someone else owns. make preflight
# tells you which one matches the cluster you are logged into.
PRESET    ?= values/cluster-plain.yaml
# Optional, gitignored, applied last so it wins.
LOCAL     := values/local.yaml
LOCAL_ARG := $(if $(wildcard $(LOCAL)),-f $(LOCAL),)

HELM_ARGS = -f $(PRESET) $(LOCAL_ARG) $(EXTRA)

.PHONY: help preflight gitops secrets deploy deploy-all build-image logs-build \
        validate smoke status argocd clean-runs lint template undeploy clean

help:
	@echo "Lightwell cluster bootstrap"
	@echo ""
	@echo "Usual order:"
	@echo "  make preflight      Check the cluster before changing it"
	@echo "  make deploy-all     preflight + gitops + secrets + deploy, then wait"
	@echo "  make build-image    Build the agent runtime image (FORCE=1 to rebuild)"
	@echo "  make validate       Prove the cluster can host an agent run"
	@echo ""
	@echo "Pieces:"
	@echo "  make gitops         Install the GitOps operator and configure ArgoCD"
	@echo "  make secrets        Apply credentials from ../secrets/secrets.env"
	@echo "  make deploy         Apply the app-of-apps (PRESET=$(PRESET))"
	@echo "  make smoke          Run the smoke pipeline only"
	@echo "  make status         ArgoCD applications and agent namespace"
	@echo "  make argocd         ArgoCD URL and admin password"
	@echo "  make clean-runs     Delete old PipelineRuns and their PVCs"
	@echo ""
	@echo "No cluster needed:"
	@echo "  make lint           helm lint every chart"
	@echo "  make template       Render both presets"
	@echo ""
	@echo "Teardown:"
	@echo "  make undeploy       Remove the app-of-apps (keeps the operators)"
	@echo "  make clean          undeploy + delete the agent namespace"
	@echo ""
	@echo "Variables: PRESET, AGENT_NS, RELEASE, EXTRA (extra helm args)"

preflight:
	@scripts/preflight.sh

gitops:
	@scripts/install-gitops.sh

secrets:
	@scripts/setup-secrets.sh --namespace $(AGENT_NS)

deploy:
	@echo "==> helm upgrade --install $(RELEASE) ($(PRESET))"
	@helm upgrade --install $(RELEASE) $(CHART) \
		--namespace $(ARGO_NS) --create-namespace $(HELM_ARGS)
	@echo "==> applications"
	@oc get applications.argoproj.io -n $(ARGO_NS) 2>/dev/null || true

# The namespace comes from the agents-workspace Application, but secrets are
# applied before it syncs, so the script creates it when missing. That ordering
# is deliberate: a build that starts without its git credential fails for a
# reason nobody reads.
deploy-all: preflight gitops secrets deploy
	@echo ""
	@echo "==> waiting for the platform to settle (up to 15 minutes)"
	@scripts/wait-platform.sh --namespace $(AGENT_NS)
	@echo ""
	@echo "Next: make validate, once the DataScienceCluster is Ready and the"
	@echo "runtime image has built (both start on their own, ~10 minutes)"

build-image:
	@scripts/build-image.sh --namespace $(AGENT_NS) $(if $(FORCE),--force,)

logs-build:
	@oc logs -f bc/lightwell-agent-runtime -n $(AGENT_NS)

validate:
	@RELEASE=$(RELEASE) scripts/validate.sh --namespace $(AGENT_NS)

smoke:
	@RELEASE=$(RELEASE) scripts/validate.sh --namespace $(AGENT_NS) --no-pipeline >/dev/null || true
	@RELEASE=$(RELEASE) scripts/validate.sh --namespace $(AGENT_NS)

status:
	@oc get applications.argoproj.io -n $(ARGO_NS) 2>/dev/null || echo "no applications"
	@echo ""
	@oc get all,secrets,istag -n $(AGENT_NS) 2>/dev/null | grep -v '^secrets/' || true

argocd:
	@echo "url:      https://$$(oc get route openshift-gitops-server -n $(ARGO_NS) -o jsonpath='{.spec.host}')"
	@echo "user:     admin"
	@echo "password: $$(oc extract secret/openshift-gitops-cluster -n $(ARGO_NS) --to=- --keys=admin.password 2>/dev/null)"

lint:
	@helm lint $(CHART)
	@for c in gitops/deployments/*/*/; do helm lint "$$c" || exit 1; done

template:
	@for p in values/cluster-plain.yaml values/cluster-rhoai-existing.yaml; do \
		echo "==> $$p"; \
		helm template $(RELEASE) $(CHART) -f "$$p" >/dev/null || exit 1; \
	done
	@for c in gitops/deployments/*/*/; do \
		helm template test "$$c" >/dev/null || exit 1; \
	done
	@echo "all charts render"

# Workspace PVCs live as long as the PipelineRun that asked for them, so old
# runs keep storage busy. Fully qualified, see the note in scripts/validate.sh.
clean-runs:
	@oc delete pipelineruns.tekton.dev --all -n $(AGENT_NS) --ignore-not-found
	@oc get pvc -n $(AGENT_NS) 2>/dev/null || true

undeploy:
	@helm uninstall $(RELEASE) --namespace $(ARGO_NS) || true
	@echo "operators are left installed on purpose, removing them breaks other users of the cluster"

clean: undeploy
	@oc delete namespace $(AGENT_NS) --ignore-not-found
