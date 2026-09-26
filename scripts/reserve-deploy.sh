#!/usr/bin/env bash
#
# Reserve the DenseIO hosts, deploy the stack onto them, then follow it to a
# usable WEKA cluster.
#
# Reserving up front is the only way a production apply cannot fail with "Out of
# host capacity" (TROUBLESHOOTING.md §6). Doing it by hand means creating
# reservations in the Console, copying OCIDs, and hand-editing stack inputs;
# this does all three, then hands off to wait-ready.sh because a SUCCEEDED ORM
# job says nothing about whether WEKA actually came up.
#
# ORM orchestration is NOT reimplemented here — the Makefile already owns
# zip/stack-create/apply/wait-job, and this drives those targets.
#
# Usage:
#   scripts/reserve-deploy.sh deploy   -c <compartment-ocid> -r <region> [flags]
#   scripts/reserve-deploy.sh teardown -c <compartment-ocid> -r <region> --confirm
#
# Needs QUAY_USERNAME / QUAY_PASSWORD in the environment (the Makefile guards on
# them). OCI_PROFILE and SSH_PUBLIC_KEY_FILE are passed through when set.
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

ACTION=deploy
REGION=${REGION:-}
COMPARTMENT_ID=${COMPARTMENT_ID:-}
TIER=""
NODES=""
ADS="1"
STACK_NAME=${STACK_NAME:-weka-oke-test}
DRY_RUN=0
CONFIRM=0
SKIP_READY=0

# Marks the reservations this script owns, so reuse and teardown can find them
# without touching reservations someone else made in the same compartment.
TAG_KEY="oke-weka-reserve"

usage() {
  cat <<'EOF'
Reserve the DenseIO hosts, deploy the stack onto them, then follow it to a
usable WEKA cluster. Reserving up front is the only way a production apply
cannot fail with "Out of host capacity" (TROUBLESHOOTING.md §6).

  scripts/reserve-deploy.sh deploy   -c <compartment-ocid> -r <region> [flags]
  scripts/reserve-deploy.sh teardown -c <compartment-ocid> -r <region> --confirm

QUAY_USERNAME and QUAY_PASSWORD must be set. OCI_PROFILE and
SSH_PUBLIC_KEY_FILE are passed through to make when set.

Flags:
  -c, --compartment-id OCID   Target compartment (required)
  -r, --region NAME           OCI region, e.g. eu-frankfurt-1 (required)
      --tier STRING           production_tier. Defaults to the Makefile's TIER.
      --nodes N               Override the worker count the tier implies.
      --ads N[,N...]          AD numbers to reserve in (default: 1).
      --stack-name NAME       ORM stack display name (default: weka-oke-test).
      --skip-ready            Stop after apply; do not track WEKA readiness.
      --dry-run               Print every oci/make command without running it.
      --confirm               Required by teardown (it destroys and deletes).
  -h, --help                  This help.

Spreading across ADs is a provisioning fallback, not a resilience win — see
TROUBLESHOOTING.md §6. Prefer a single AD when you can get the hosts.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

run() {
  if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; return 0; fi
  "$@"
}

# --- arguments -------------------------------------------------------------

case "${1:-}" in
  deploy|teardown) ACTION=$1; shift ;;
  -h|--help) usage; exit 0 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--compartment-id) COMPARTMENT_ID=$2; shift 2 ;;
    -r|--region)         REGION=$2; shift 2 ;;
    --tier)              TIER=$2; shift 2 ;;
    --nodes)             NODES=$2; shift 2 ;;
    --ads)               ADS=$2; shift 2 ;;
    --stack-name)        STACK_NAME=$2; shift 2 ;;
    --skip-ready)        SKIP_READY=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --confirm)           CONFIRM=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   die "unknown argument: $1 (try --help)" ;;
  esac
done

for dep in oci jq make; do
  command -v "$dep" >/dev/null || die "$dep is required but not on PATH"
done
[ -n "$REGION" ]         || die "--region is required"
[ -n "$COMPARTMENT_ID" ] || die "--compartment-id is required"

OCI_ARGS=(--region "$REGION")
[ -n "${OCI_PROFILE:-}" ] && OCI_ARGS+=(--profile "$OCI_PROFILE")

MAKE_ARGS=(REGION="$REGION" COMPARTMENT_ID="$COMPARTMENT_ID" STACK_NAME="$STACK_NAME")
[ -n "${OCI_PROFILE:-}" ] && MAKE_ARGS+=(OCI_PROFILE="$OCI_PROFILE")
[ -n "${SSH_PUBLIC_KEY_FILE:-}" ] && MAKE_ARGS+=(SSH_PUBLIC_KEY_FILE="$SSH_PUBLIC_KEY_FILE")

# --- sizing ----------------------------------------------------------------

# The tier string already carries the shape and the node count, so parse it
# rather than keeping a second copy of local.tier_specs (main.tf) in bash that
# would silently drift when a tier is added.
parse_tier() {
  local tier=$1
  [[ $tier =~ -\ ([0-9]+)\ x\ ([A-Za-z0-9._]+)\ \( ]] \
    || die "could not read a node count and shape from tier '$tier'
       Expected the shipped format, e.g. '245 TB usable - 8 x BM.DenseIO.E4.128 (8 NVMe)'.
       Reservations only apply to the production flavor; the dev zip has no tier."
  TIER_COUNT=${BASH_REMATCH[1]}
  TIER_SHAPE=${BASH_REMATCH[2]}
}

if [ -z "$TIER" ]; then
  # Ask make rather than scraping the file: it honours the ifeq branches and any
  # override, so the default here cannot drift from the one a bare `make` uses.
  TIER=$(make -s print-TIER)
  [ -n "$TIER" ] || die "no --tier given and the Makefile's TIER default is empty"
fi
parse_tier "$TIER"

NODE_COUNT=${NODES:-$TIER_COUNT}
[[ $NODE_COUNT =~ ^[0-9]+$ ]] && [ "$NODE_COUNT" -gt 0 ] || die "--nodes must be a positive integer"

IFS=',' read -r -a AD_NUMS <<<"$ADS"
POOLS=${#AD_NUMS[@]}
for n in "${AD_NUMS[@]}"; do
  [[ $n =~ ^[0-9]+$ ]] || die "--ads takes AD numbers, e.g. --ads 1,2 (got '$n')"
done
[ "$POOLS" -le "$NODE_COUNT" ] || die "$POOLS ADs requested for only $NODE_COUNT nodes"

# Every reservation holds the LARGEST pool size, not its own share.
#
# capacity.tf spreads nodes unevenly (8 over 3 => 3/3/2) and then pairs a size
# to a reservation by position in reservation_ids_sorted — sorted by OCID, which
# has nothing to do with which AD holds what. So the size-3 pool lands on the
# reservation holding 2 in two of the three possible orderings, and the
# reservation_gate rejects a set that is actually adequate. Reserving the max
# everywhere makes the outcome order-independent, for at most (pools - 1) extra
# reserved hosts.
#
# Workaround, not a fix: capacity.tf should pair sizes to reservations by
# reserved count descending. That changes pool sizes on stacks whose
# capacity_reservation_ids guard.tf has already frozen, so it replaces workers
# and needs its own change.
RESERVE_EACH=$(( (NODE_COUNT + POOLS - 1) / POOLS ))
RESERVE_EXTRA=$(( RESERVE_EACH * POOLS - NODE_COUNT ))

# --- reservations ----------------------------------------------------------

# Both listings are region/compartment-wide and identical for every AD, so they
# are fetched once here rather than per AD inside the loop.
AD_NAMES_JSON='[]'
OWNED_JSON='[]'

load_inventory() {
  local raw
  raw=$(oci iam availability-domain list "${OCI_ARGS[@]}" -c "$COMPARTMENT_ID" \
          --query 'data[].name' 2>/dev/null) || raw=""
  [ -n "$raw" ] && AD_NAMES_JSON=$raw

  # An empty or failed list is "none found", not an error: no reservation is
  # exactly the case the caller then creates.
  raw=$(oci compute capacity-reservation list "${OCI_ARGS[@]}" -c "$COMPARTMENT_ID" --all \
          --query 'data[?"lifecycle-state" == `ACTIVE`]' 2>/dev/null) || raw=""
  [ -n "$raw" ] || raw='[]'

  # `list` does not return instance-reservation-configs — only `get` does. Read
  # the count off the list response and every reservation scores 0, so nothing
  # is ever reused and each run reserves another set of hosts next to the ones
  # already billing. One get per owned reservation, not per reservation in the
  # compartment.
  local id detail
  OWNED_JSON='[]'
  while read -r id; do
    [ -n "$id" ] || continue
    detail=$(oci compute capacity-reservation get "${OCI_ARGS[@]}" \
               --capacity-reservation-id "$id" --query 'data' 2>/dev/null) || continue
    # reserved-count, NOT reserved minus used: once this stack's own nodes launch
    # they become the used count, so a free-host check would pass on create and
    # fail every re-apply. Mirrors local.reservation_details in capacity.tf.
    OWNED_JSON=$(jq -c --argjson acc "$OWNED_JSON" --arg id "$id" --arg shape "$TIER_SHAPE" '
        $acc + [{
          id: $id,
          ad: ."availability-domain",
          reserved: ([ (."instance-reservation-configs" // [])[]
                       | select(."instance-shape" == $shape) | ."reserved-count" ] | add // 0)
        }]' <<<"$detail")
  done < <(jq -r --arg tagk "$TAG_KEY" --arg name "$STACK_NAME" \
             '(. // []) | map(select(."freeform-tags"[$tagk] == $name)) | .[].id' <<<"$raw")
}

# --- OKE's own permission on the reservation -------------------------------
#
# OKE launches managed nodes under the node-pool principal, NOT the deploying
# user, and that principal needs a tenancy-level grant to read the reservation.
# Without it every input is valid and the apply still dies ~7 minutes in, after
# the VCN and control plane are already built:
#
#   Error returned by GetComputeCapacityReservation operation in Compute
#   service.(404, NotAuthorizedOrNotFound)
#
# TROUBLESHOOTING.md §9 has the diagnosis and the fix.
#
# The tenancy OCID is NOT derivable from `oci iam region-subscription list`
# despite what the Makefile's vars-json tries — that response carries only
# region-key / region-name / is-home-region / status, so the query yields empty
# and the Makefile silently falls through to its own config-file fallback. Read
# the config directly, honouring OCI_PROFILE, and hand the result to make so it
# skips that dead round trip.
tenancy_ocid() {
  [ -n "${TENANCY_ID:-}" ] && { printf '%s' "$TENANCY_ID"; return 0; }
  [ -n "${OCI_CLI_TENANCY:-}" ] && { printf '%s' "$OCI_CLI_TENANCY"; return 0; }
  awk -v want="[${OCI_PROFILE:-DEFAULT}]" '
    /^\[/ { inprofile = ($0 == want); next }
    inprofile && /^[[:space:]]*tenancy[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]]/, ""); print; exit
    }' "$HOME/.oci/config" 2>/dev/null
}

# Takes the tenancy rather than resolving it, because the caller reads this
# through $(...) — a global set in here would be set in the subshell and lost.
# Fails only when the policies cannot be READ; "no such grant" is a successful
# read, and the caller tells the two apart by inspecting the output.
tenancy_policy_statements() {
  # An `in tenancy` grant can only live in the ROOT compartment, so one listing
  # is the entire search space — no need to walk sub-compartments.
  oci iam policy list "${OCI_ARGS[@]}" -c "$1" --all \
    --query 'data[].statements[]' 2>/dev/null
}

# Both statements are required and they grant to different principals: the
# service orchestrates, the node-pool principal makes the actual
# GetComputeCapacityReservation call. `allow` is part of the first match on
# purpose — without it a Deny statement would read as a grant.
oke_reservation_grant_in() {
  grep -qiE "allow +service +oke +to +(use|manage) +compute-capacity-reservations" <<<"$1" \
    && grep -qiE "compute-capacity-reservations.*principal\.type *= *'nodepool'" <<<"$1"
}

# The stack reads an AD's number off the last character of its name
# (local.reservation_details), so matching on the -AD-<n> suffix keeps the
# reservations and the pools the stack builds in agreement by construction.
ad_name_for() {
  local num=$1 name
  name=$(jq -r --arg sfx "-AD-$num" 'map(select(endswith($sfx))) | first // empty' <<<"$AD_NAMES_JSON")
  if [ -z "$name" ]; then
    # Dry runs stay usable without credentials; a real run must not guess.
    [ "$DRY_RUN" = 1 ] || die "no availability domain ending in -AD-$num in $REGION"
    name="<AD-$num in $REGION>"
  fi
  printf '%s' "$name"
}

# Emits "<ocid> <reserved-count>" — the count is already known on both paths, so
# the caller never has to re-read the reservation to verify it.
ensure_reservation() {
  local ad_num=$1 want=$2 ad_name existing created
  ad_name=$(ad_name_for "$ad_num")

  existing=$(jq -r --arg ad "$ad_name" --argjson want "$want" \
               'map(select(.ad == $ad and .reserved >= $want)) | first // empty
                | "\(.id) \(.reserved)"' <<<"$OWNED_JSON")
  if [ -n "$existing" ]; then
    echo "  AD-$ad_num ($ad_name): reusing ${existing%% *} (holds ${existing##* })" >&2
    printf '%s' "$existing"
    return 0
  fi

  # No instanceShapeConfig: bare-metal shapes have fixed OCPU/memory and reject
  # it, the same rule capacity.tf applies via regexall("Flex", ...).
  local cmd=(oci compute capacity-reservation create "${OCI_ARGS[@]}"
    -c "$COMPARTMENT_ID"
    --availability-domain "$ad_name"
    --display-name "$STACK_NAME-ad$ad_num"
    --freeform-tags "{\"$TAG_KEY\":\"$STACK_NAME\"}"
    --instance-reservation-configs "[{\"instanceShape\":\"$TIER_SHAPE\",\"reservedCount\":$want}]"
    --wait-for-state ACTIVE)

  echo "  AD-$ad_num ($ad_name): creating a reservation for $want x $TIER_SHAPE" >&2
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] %s\n' "${cmd[*]}" >&2
    printf 'ocid1.capacityreservation.oc1..DRYRUN-ad%s %s' "$ad_num" "$want"
    return 0
  fi

  # --wait-for-state makes this the post-wait object, so it already carries the
  # granted counts; asking for data.id alone would throw them away and force a
  # second call to learn whether OCI filled the request.
  created=$("${cmd[@]}" --query 'data' 2>/dev/null) \
    || die "could not create a reservation in $ad_name — check the 'manage capacity-reservations' permission and your service limits"

  jq -r --arg shape "$TIER_SHAPE" '
      "\(.id) \([ (."instance-reservation-configs" // [])[]
                  | select(."instance-shape" == $shape) | ."reserved-count" ] | add // 0)"' \
    <<<"$created"
}

# --- actions ---------------------------------------------------------------

# Reservations are production-only, so the prod stack id is the right one.
# Asking make keeps the build/ layout the Makefile's business, not ours.
stack_id_file=$(make -s print-STACK_ID_FILE VARIANT=prod)

# One tf-state fetch serves every output the script needs.
TF_STATE=""
read_output() {
  [ -n "$TF_STATE" ] || TF_STATE=$(oci resource-manager stack get-stack-tf-state "${OCI_ARGS[@]}" \
    --stack-id "$(cat "$stack_id_file")" --file - 2>/dev/null) || TF_STATE="{}"
  jq -r --arg k "$1" '.outputs[$k].value // empty' <<<"$TF_STATE"
}

do_deploy() {
  # Everything make's vars-json guards on, checked BEFORE any reservation is
  # created — a guard that fires afterwards leaves billing hosts behind.
  [ -n "${QUAY_USERNAME:-}" ] && [ -n "${QUAY_PASSWORD:-}" ] \
    || die "QUAY_USERNAME and QUAY_PASSWORD must be set (the image pull secret)"
  local ssh_key=${SSH_PUBLIC_KEY_FILE:-$(make -s print-SSH_PUBLIC_KEY_FILE)}
  [ -n "$ssh_key" ] && [ -f "$ssh_key" ] \
    || die "no SSH public key found (looked for ~/.ssh/id_ed25519.pub, ~/.ssh/id_rsa.pub)
       pass SSH_PUBLIC_KEY_FILE=/path/to/key.pub"

  # Same reason as the guards above: this must run before anything is created.
  local statements tenancy
  tenancy=$(tenancy_ocid)
  if [ -z "$tenancy" ] || ! statements=$(tenancy_policy_statements "$tenancy"); then
    echo "  warning: could not read tenancy policies, so OKE's permission on the reservation" >&2
    echo "           was not verified (TROUBLESHOOTING.md §9)." >&2
  elif ! oke_reservation_grant_in "$statements"; then
    # Not fatal in a dry run: --dry-run is documented to work without
    # credentials, and dying here would withhold the plan in exactly the tenancy
    # state the check exists to report.
    local msg="OKE is not allowed to launch nodes into a capacity reservation in this tenancy,
       so the apply would build the VCN and control plane and only then fail with
       'GetComputeCapacityReservation ... (404, NotAuthorizedOrNotFound)'.
       A tenancy admin grants this once — TROUBLESHOOTING.md §9 has the two
       statements and the command (tenancy $tenancy; IAM writes go to the
       home region). Allow 2-5 minutes for propagation."
    if [ "$DRY_RUN" = 1 ]; then
      echo "  warning: $msg" >&2
    else
      die "$msg
       No reservation has been created yet, so nothing is billing."
    fi
  fi

  # The script already resolved the tenancy; handing it over skips the dead
  # region-subscription lookup in the Makefile's vars-json. An `x && y` here
  # would be the failing last command of an unguarded line under `set -e`.
  if [ -n "$tenancy" ]; then MAKE_ARGS+=(TENANCY_ID="$tenancy"); fi

  say "Plan"
  echo "  tier:    $TIER"
  echo "  shape:   $TIER_SHAPE"
  if [ -n "$NODES" ]; then
    echo "  workers: $NODE_COUNT (override; the tier implies $TIER_COUNT, so its advertised capacity no longer holds)"
  else
    echo "  workers: $NODE_COUNT"
  fi
  echo "  reserving: $RESERVE_EACH hosts in each of AD-$(IFS=,; echo "${AD_NUMS[*]}")"
  if [ "$RESERVE_EXTRA" -gt 0 ]; then
    echo "  note: $RESERVE_EXTRA more reserved host(s) than nodes. The stack pairs pool sizes to"
    echo "        reservations by OCID order, so an uneven split needs every reservation to hold"
    echo "        the largest size. A node count divisible by $POOLS avoids the extra."
  fi
  if [ "$POOLS" -gt 1 ]; then
    echo "  note: spreading over $POOLS ADs trades resilience for availability (TROUBLESHOOTING.md §6)"
  fi

  say "Reservations"
  load_inventory
  local ids=() short=()
  for i in "${!AD_NUMS[@]}"; do
    local pair; pair=$(ensure_reservation "${AD_NUMS[i]}" "$RESERVE_EACH")
    ids+=("${pair%% *}")
    # OCI fills a reservation PARTIALLY when it is short. The stack's
    # reservation_gate catches this too, but only after stack-create and a
    # plan — failing here saves that round trip and names the shortfall per AD.
    [ "${pair##* }" -lt "$RESERVE_EACH" ] \
      && short+=("AD-${AD_NUMS[i]} needs $RESERVE_EACH, holds ${pair##* }")
  done

  if [ ${#short[@]} -gt 0 ]; then
    printf '\n'
    die "OCI granted fewer hosts than requested:
       $(printf '%s; ' "${short[@]}")
       Even out the reservations, spread over more ADs (--ads 1,2,3), or pick a
       smaller tier. The reservations already created are tagged $TAG_KEY=$STACK_NAME
       and are billing — 'teardown --confirm' removes them."
  fi

  local joined; joined=$(IFS=,; echo "${ids[*]}")
  say "Deploying stack '$STACK_NAME'"
  echo "  capacity_reservation_ids = $joined"
  local create_args=("${MAKE_ARGS[@]}" TIER="$TIER" RESERVATIONS="$joined")
  [ -n "$NODES" ] && create_args+=(NODES="$NODES")
  run make stack-create "${create_args[@]}"
  run make apply CONFIRM=yes "${MAKE_ARGS[@]}"

  [ "$SKIP_READY" = 1 ] && { say "Done (--skip-ready; WEKA is probably still forming)"; return 0; }
  [ "$DRY_RUN" = 1 ] && { printf '  [dry-run] %s\n' "scripts/wait-ready.sh (EXPECTED_NODES=$NODE_COUNT)"; return 0; }

  say "Writing kubeconfig"
  local cluster_id kubeconfig
  cluster_id=$(read_output cluster_id)
  [ -n "$cluster_id" ] || die "the stack has no cluster_id output — did the apply actually create the cluster?"
  kubeconfig="$REPO_ROOT/build/kubeconfig.$STACK_NAME"
  oci ce cluster create-kubeconfig "${OCI_ARGS[@]}" \
    --cluster-id "$cluster_id" --file "$kubeconfig" \
    --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT >/dev/null
  chmod 600 "$kubeconfig"
  echo "  $kubeconfig"

  say "Tracking WEKA readiness"
  KUBECONFIG="$kubeconfig" EXPECTED_NODES="$NODE_COUNT" \
    OPERATOR_NS="$(read_output operator_namespace)" scripts/wait-ready.sh
}

do_teardown() {
  [ "$CONFIRM" = 1 ] || die "teardown destroys the cluster and deletes the reservations — pass --confirm"

  if [ -f "$stack_id_file" ]; then
    say "Destroying stack"
    run make destroy CONFIRM=yes "${MAKE_ARGS[@]}"
    run make stack-delete "${MAKE_ARGS[@]}"
  else
    echo "no $stack_id_file — skipping stack destroy"
  fi

  say "Deleting reservations tagged $TAG_KEY=$STACK_NAME"
  load_inventory
  local found=0
  while read -r id ad; do
    [ -n "$id" ] || continue
    found=1
    echo "  $id ($ad)"
    run oci compute capacity-reservation delete "${OCI_ARGS[@]}" \
      --capacity-reservation-id "$id" --force --wait-for-state DELETED
  done < <(jq -r '.[] | "\(.id) \(.ad)"' <<<"$OWNED_JSON")
  [ "$found" = 0 ] && echo "  none found"
  say "Done"
}

case "$ACTION" in
  deploy)   do_deploy ;;
  teardown) do_teardown ;;
esac
