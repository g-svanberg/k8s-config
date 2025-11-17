#!/bin/bash
set -euo pipefail

# Purpose: Force removal of specific Longhorn CRDs that may be stuck due to finalizers.
# CRDs targeted: backuptargets.longhorn.io, engineimages.longhorn.io, nodes.longhorn.io
# Safe workflow (backups skipped by user request):
#  1. (Optional) Disable Longhorn components (scale deployments/statefulsets)
#  2. Remove Longhorn webhook configurations to avoid admission validation errors
#  3. List & delete all instances of each CRD (across all namespaces)
#  4. Force-remove finalizers on remaining instances
#  5. Remove CRD finalizers & delete CRDs
#  6. Verify removal

crds=(
  backuptargets.longhorn.io
  engineimages.longhorn.io
  nodes.longhorn.io
)

# FAST mode: if FAST=1 is set in environment, skip enumeration (still may attempt deletion if instances listed previously).
FAST_MODE=${FAST:-0}
# NO_INSTANCES mode: if NO_INSTANCES=1, completely bypass any instance deletion logic.
NO_INSTANCES_MODE=${NO_INSTANCES:-0}

# Use standard kubectl
KUBECTL="kubectl"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required. Install it first." >&2
  exit 1
fi

echo "Skipping CRD backups (disabled)."

echo "Starting removal workflow..."

# Remove Longhorn admission webhooks (they can block deletion when the service is missing)
echo "Removing Longhorn webhook configurations (deep discovery)..."

# Validating webhooks: match by config name containing longhorn OR any webhook name 'validator.longhorn.io' OR service name 'longhorn-admission-webhook'
val_hooks_names=$($KUBECTL get validatingwebhookconfigurations -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name|test("longhorn")) | .metadata.name') || val_hooks_names=""
val_hooks_by_webhookname=$($KUBECTL get validatingwebhookconfigurations -o json 2>/dev/null | jq -r '.items[] | select(.webhooks[]?.name == "validator.longhorn.io") | .metadata.name') || val_hooks_by_webhookname=""
val_hooks_by_service=$($KUBECTL get validatingwebhookconfigurations -o json 2>/dev/null | jq -r '.items[] | select(.webhooks[]?.clientConfig.service.name == "longhorn-admission-webhook") | .metadata.name') || val_hooks_by_service=""
val_hooks=$(echo -e "${val_hooks_names}\n${val_hooks_by_webhookname}\n${val_hooks_by_service}" | sort -u | sed '/^$/d')

# Mutating webhooks: similar matching
mut_hooks_names=$($KUBECTL get mutatingwebhookconfigurations -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name|test("longhorn")) | .metadata.name') || mut_hooks_names=""
mut_hooks_by_service=$($KUBECTL get mutatingwebhookconfigurations -o json 2>/dev/null | jq -r '.items[] | select(.webhooks[]?.clientConfig.service.name == "longhorn-admission-webhook") | .metadata.name') || mut_hooks_by_service=""
mut_hooks=$(echo -e "${mut_hooks_names}\n${mut_hooks_by_service}" | sort -u | sed '/^$/d')

if [[ -z "$val_hooks$mut_hooks" ]]; then
  echo "No Longhorn-related webhook configurations discovered."
else
  echo "$val_hooks" | sed 's/^/  - validating: /'
  echo "$mut_hooks" | sed 's/^/  - mutating: /'
  for h in $val_hooks; do
    $KUBECTL delete validatingwebhookconfiguration "$h" --ignore-not-found || true
  done
  for h in $mut_hooks; do
    $KUBECTL delete mutatingwebhookconfiguration "$h" --ignore-not-found || true
  done
fi
echo "Webhook configuration cleanup done."
for crd in "${crds[@]}"; do
  echo "\n==== Processing $crd ===="
  if ! $KUBECTL get crd "$crd" >/dev/null 2>&1; then
    echo "CRD $crd already gone. Skipping."
    continue
  fi

  # Extract the resource kind (spec.names.plural) to delete instances.
  plural=$($KUBECTL get crd "$crd" -o jsonpath='{.spec.names.plural}') || plural=""
  group=$($KUBECTL get crd "$crd" -o jsonpath='{.spec.group}') || group=""
  full_resource="${plural}.${group}"
  if [[ -n "$plural" && -n "$group" ]]; then
    echo "Listing instances of $full_resource (all namespaces)..."
    if [[ "$NO_INSTANCES_MODE" == "1" ]]; then
      echo "NO_INSTANCES_MODE enabled: bypassing instance handling for $full_resource"
      instances=""
    else
      if [[ "$FAST_MODE" == "1" ]]; then
        echo "FAST_MODE enabled: skipping instance enumeration & deletion for $full_resource"
        instances=""
      else
        instances=$($KUBECTL get "$full_resource" --all-namespaces -o name 2>/dev/null || true)
      fi
    fi
  if [[ -n "$instances" && "$FAST_MODE" != "1" && "$NO_INSTANCES_MODE" != "1" ]]; then
      echo "$instances" | sed 's/^/  - /'
      echo "Deleting all instances (graceful, tolerating webhook failures)..."
      if ! $KUBECTL delete "$full_resource" --all --all-namespaces --ignore-not-found 2>delete_err.log; then
        if grep -q 'failed calling webhook' delete_err.log; then
          echo "Admission webhook error encountered. Retrying with --wait=false and removing finalizers individually."
          # Attempt delete without waiting (may mark for deletion)
          $KUBECTL delete "$full_resource" --all --all-namespaces --ignore-not-found --wait=false || true
        else
          echo "Non-webhook deletion error (see delete_err.log), continuing to forced finalizer removal path."
        fi
      fi
      rm -f delete_err.log
      echo "Waiting briefly for instance deletions..."
      sleep 3

      echo "Scanning for remaining instances to force-remove finalizers..."
      remaining=$($KUBECTL get "$full_resource" --all-namespaces -o name 2>/dev/null || true)
      if [[ -n "$remaining" ]]; then
        echo "$remaining" | sed 's/^/  * forcing: /'
        while read -r res; do
          ns=$(echo "$res" | cut -d/ -f1 | cut -d: -f2)
          name=$(echo "$res" | cut -d/ -f2)
          # Fetch object JSON and strip finalizers
          if $KUBECTL get "$full_resource" -n "$ns" "$name" -o json > obj.json 2>/dev/null; then
            jq '(.metadata.finalizers)=[]' obj.json > obj_clean.json
            $KUBECTL patch "$full_resource" -n "$ns" "$name" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            # Attempt raw finalize endpoint (namespaced path)
            $KUBECTL replace --raw "/apis/$group/v1/namespaces/$ns/$plural/$name/finalize" -f obj_clean.json 2>/dev/null || true
            $KUBECTL delete "$full_resource" -n "$ns" "$name" --ignore-not-found --wait=false || true
          fi
          rm -f obj.json obj_clean.json || true
        done <<< "$remaining"
      else
        echo "No remaining instances detected after graceful delete."
      fi
    else
      echo "No instances found."
    fi
  else
    echo "Could not derive plural/group for $crd (unexpected schema). Continuing."
  fi

  echo "Attempting standard CRD deletion for $crd..."
  if $KUBECTL delete crd "$crd" --ignore-not-found --timeout=30s; then
    echo "CRD $crd deleted via standard method."
    continue
  fi

  echo "CRD $crd appears stuck. Removing finalizers..."
  tmp_json=$(mktemp)
  clean_json=$(mktemp)
  $KUBECTL get crd "$crd" -o json > "$tmp_json"
  jq 'del(.metadata.finalizers)' "$tmp_json" > "$clean_json"

  # Use finalize endpoint to remove finalizers
  $KUBECTL replace --raw "/apis/apiextensions.k8s.io/v1/customresourcedefinitions/$crd/finalize" -f "$clean_json" || echo "Finalize endpoint call failed (may already be finalizing)."

  echo "Retrying CRD deletion for $crd..."
  if $KUBECTL delete crd "$crd" --ignore-not-found --timeout=30s; then
    echo "✅ Finalizers removed and CRD $crd deleted."
  else
  echo "⚠️ Still unable to delete $crd. Manual intervention required."
  echo "Try (manual patch): $KUBECTL patch crd $crd -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge"
  fi

  rm -f "$tmp_json" "$clean_json"
done

echo "\nVerification:"
echo "Remaining Longhorn CRDs (should be empty or only ones you didn't target):"
$KUBECTL get crd | grep -E 'longhorn.io' || echo "(No longhorn.io CRDs found.)"

echo "\nDone. (No backups were created.)"