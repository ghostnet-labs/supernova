#!/usr/bin/env zsh
# Kubernetes: k8s_switch, kget_notready, kget_labels, kget_taints, knodes,
# and kpods.
# .zshrc sources every file in dotfiles/functions/.

# Switch to a different Kubernetes context and namespace
# (ie k8s-switch)
# toolbox: kubernetes interactive | Select a Kubernetes context and namespace.
# toolbox-example: k8s_switch
k8s_switch() {
  echo "🔍 Select a Kubernetes context:"
  local context=$(kubectl config get-contexts -o name | fzf --prompt="Context > ")
  [[ -z "$context" ]] && echo "❌ No context selected." && return

  kubectl config use-context "$context"

  # A work overlay may set K8S_SWITCH_NAMESPACE to the namespace it uses.
  if [[ -n "${K8S_SWITCH_NAMESPACE:-}" ]]; then
    kubectl config set-context --current --namespace="$K8S_SWITCH_NAMESPACE"
    echo "✅ Switched to context: $context with namespace: $K8S_SWITCH_NAMESPACE"
  else
    echo "✅ Switched to context: $context"
  fi
}

_kget_notready_help() {
  cat <<'EOF'
Usage:
  kget_notready [options]

Description:
  List Kubernetes nodes whose Ready status is not exactly Ready.

Options:
  -h, --help    Show this help menu.
  -w, --watch   Refresh every two seconds.

Examples:
  kget_notready
  kget_notready --watch
  kget_notready | sort
EOF
}

_kget_labels_help() {
  cat <<'EOF'
Usage:
  kget_labels [options] <node-name> [kubectl-args...]

Description:
  Print one Kubernetes node's labels as key=value pairs. Extra arguments are
  passed to kubectl get node before this helper requests JSON output.

Options:
  -h, --help    Show this help menu.
  -w, --watch   Refresh every two seconds.

Examples:
  kget_labels rack1-node1
  kget_labels --watch rack1-node1
  kget_labels rack1-node1 --context prod
EOF
}

_kget_taints_help() {
  cat <<'EOF'
Usage:
  kget_taints [options] <node-name> [kubectl-args...]

Description:
  Print one Kubernetes node's taints as key=value:effect entries. Extra
  arguments are passed to kubectl get node before this helper requests JSON.

Options:
  -h, --help    Show this help menu.
  -w, --watch   Refresh every two seconds.

Examples:
  kget_taints rack1-node1
  kget_taints --watch rack1-node1
  kget_taints rack1-node1 --context prod
EOF
}

_knodes_help() {
  cat <<'EOF'
Usage:
  knodes [options] <rack-name> [rack-name ...]

Description:
  List Kubernetes nodes belonging to one or more racks.

Options:
  -h, --help    Show this help menu.
  -w, --watch   Refresh every two seconds.

Examples:
  knodes rack1
  knodes rack1 rack2
  knodes --watch rack1
EOF
}

_kpods_help() {
  cat <<'EOF'
Usage:
  kpods [options] <node-name>

Description:
  List Pods across all namespaces scheduled on one Kubernetes node.

Options:
  -h, --help    Show this help menu.
  -w, --watch   Refresh every two seconds.

Examples:
  kpods rack1-node1
  kpods --watch rack1-node1
  kpods rack1-node1 | rg -v Running
EOF
}

# toolbox: kubernetes | List Kubernetes nodes that are not Ready.
# toolbox-args: [--watch]
# toolbox-example: kget_notready
# toolbox-example: kget_notready --watch
kget_notready() {
  if (( $# > 1 )); then
    echo "Error: kget_notready does not take positional arguments." >&2
    echo "Run 'kget_notready --help' for usage." >&2
    return 2
  fi

  case "$1" in
    -h|--help)
      _kget_notready_help
      return 0
      ;;
    --watch)
      set -- -w
      ;;
    -w|"")
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      echo "Run 'kget_notready --help' for usage." >&2
      return 2
      ;;
  esac

  if [[ "$1" == "-w" ]]; then
    watch -n2 'kubectl get nodes --no-headers | awk '"'"'$2 != "Ready" {print $1, $2}'"'"
  else
    kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1, $2}'
  fi
}

# toolbox: kubernetes | Show one Kubernetes node's labels.
# toolbox-args: [--watch] NODE [KUBECTL-ARGS...]
# toolbox-example: kget_labels node-1
# toolbox-example: kget_labels --watch node-1
# toolbox-example: kget_labels node-1 --context cluster-name
kget_labels() {
  local do_watch=false
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _kget_labels_help
    return 0
  fi
  if [[ "$1" == "-w" || "$1" == "--watch" ]]; then
    do_watch=true
    shift
  fi
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _kget_labels_help
    return 0
  fi

  if [[ -z "$1" ]]; then
    echo "Error: a node name is required." >&2
    echo "Run 'kget_labels --help' for usage." >&2
    return 2
  fi
  local node="$1"
  shift

  if $do_watch; then
    if command -v jq >/dev/null 2>&1; then
      watch -n2 "kubectl get node $node $* -o json | jq -r '.metadata.labels | to_entries[] | \"\(.key)=\(.value)\"'"
    else
      watch -n2 "kubectl get node $node $* -o jsonpath='{range \$k,\$v := .metadata.labels}{printf \"%s=%s\n\", \$k, \$v}{end}'"
    fi
  else
    if command -v jq >/dev/null 2>&1; then
      kubectl get node "$node" "$@" -o json |
        jq -r '.metadata.labels | to_entries[] | "\(.key)=\(.value)"'
    else
      # Fallback if jq isn't installed
      kubectl get node "$node" "$@" \
        -o jsonpath='{range $k,$v := .metadata.labels}{printf "%s=%s\n", $k, $v}{end}'
    fi
  fi
}

# toolbox: kubernetes | Show one Kubernetes node's taints.
# toolbox-args: [--watch] NODE [KUBECTL-ARGS...]
# toolbox-example: kget_taints node-1
# toolbox-example: kget_taints --watch node-1
# toolbox-example: kget_taints node-1 --context cluster-name
kget_taints() {
  local do_watch=false
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _kget_taints_help
    return 0
  fi
  if [[ "$1" == "-w" || "$1" == "--watch" ]]; then
    do_watch=true
    shift
  fi
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _kget_taints_help
    return 0
  fi

  if [[ -z "$1" ]]; then
    echo "Error: a node name is required." >&2
    echo "Run 'kget_taints --help' for usage." >&2
    return 2
  fi
  local node="$1"
  shift

  if $do_watch; then
    watch -n2 "kubectl get node $node $* -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{\"\\n\"}{end}'"
  else
    kubectl get node "$node" "$@" -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}'
  fi
}

# toolbox: kubernetes | List Kubernetes nodes belonging to racks.
# toolbox-args: [--watch] RACK [RACK ...]
# toolbox-example: knodes rack-1
# toolbox-example: knodes rack-1 rack-2
# toolbox-example: knodes --watch rack-1
knodes() {
  local do_watch=false
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _knodes_help
    return 0
  fi
  if [[ "$1" == "-w" || "$1" == "--watch" ]]; then
    do_watch=true
    shift
  fi
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _knodes_help
    return 0
  fi
  if [[ $# -eq 0 ]]; then
    echo "Error: specify at least one rack name." >&2
    echo "Run 'knodes --help' for usage." >&2
    return 2
  fi

  local condition='NR == 1'
  for rack in "$@"; do
    condition+=" || \$1 ~ /${rack}-/"
  done

  if $do_watch; then
    watch -n2 "kubectl get nodes | awk '${condition}'"
  else
    kubectl get nodes | awk "$condition"
  fi
}

# toolbox: kubernetes | List Pods scheduled on a node.
# toolbox-args: [--watch] NODE
# toolbox-example: kpods node-1
# toolbox-example: kpods --watch node-1
kpods() {
  local do_watch=false
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _kpods_help
    return 0
  fi
  if [[ "$1" == "-w" || "$1" == "--watch" ]]; then
    do_watch=true
    shift
  fi
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _kpods_help
    return 0
  fi

  if [[ -z "$1" ]]; then
    echo "Error: a node name is required." >&2
    echo "Run 'kpods --help' for usage." >&2
    return 2
  fi

  if $do_watch; then
    watch -n2 "kubectl get pods -A --field-selector spec.nodeName=$1"
  else
    kubectl get pods -A --field-selector spec.nodeName="$1"
  fi
}
