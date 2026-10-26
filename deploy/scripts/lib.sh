#!/usr/bin/env bash
# lib.sh - shared output helpers for the bootstrap scripts.
#
# Sourced, not executed. Keep it free of side effects beyond defining things.

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_ok()    { echo -e "  ${GREEN}ok${NC}    $*"; }
log_fail()  { echo -e "  ${RED}fail${NC}  $*"; }
log_skip()  { echo -e "  ${YELLOW}warn${NC}  $*"; }

die() { log_error "$*"; exit 1; }

# Fails when oc is missing or not logged in, which is the first thing to go
# wrong on a fresh laptop or an expired cluster.
require_cluster() {
  command -v oc >/dev/null 2>&1 || die "oc is not installed"
  oc whoami >/dev/null 2>&1 || die "not logged into a cluster (oc login ...)"
  log_info "cluster: $(oc whoami --show-server) as $(oc whoami)"
}

require_helm() {
  command -v helm >/dev/null 2>&1 || die "helm is not installed (v3)"
}
