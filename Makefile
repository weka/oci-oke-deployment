# Helper targets for developing and TESTING this stack before cutting a release.
#
# The point of `make stack-create` is to exercise the CURRENT WORKING TREE —
# uncommitted changes included — on a real ORM runner, so a fix can be proven
# before it is committed, tagged, and published by .github/workflows/release.yml.
#
# Quick start (test an uncommitted change end to end):
#
#   make check                              # fmt + validate, no cloud calls
#   make zip                                # build the prod stack zip from the tree
#   make stack-create COMPARTMENT_ID=ocid1.compartment... REGION=eu-frankfurt-1 \
#        QUAY_USERNAME=... QUAY_PASSWORD=...
#   make plan                               # free dry run; validates schema.yaml too
#   make apply CONFIRM=yes                  # spends money on bare metal
#   make destroy CONFIRM=yes stack-delete   # tear it all down
#
# Iterate without recreating the stack: edit, then `make stack-update plan`.
#
# Reuse an existing stack instead of creating one:
#
#   make stack-adopt STACK_ID=ocid1.ormstack...
#   make stack-update plan
#
# NOTE: `make apply` on a FRESH stack is the cleanest way to test a WekaCluster CR
# change — updating the stack behind a HEALTHY cluster patches a live CR in place,
# which is a different and less understood code path. That caveat does not apply to
# a cluster that never formed: there is nothing working to disturb, and reusing its
# stack avoids competing for scarce DenseIO capacity.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Knobs. Override on the command line: make plan REGION=us-phoenix-1
#
# Comments stay ABOVE each assignment on purpose: a trailing `# ...` leaves the
# whitespace before it IN the value, which silently makes "empty" knobs non-empty
# (defeating the guard-% checks) and appends spaces to real values.
# ---------------------------------------------------------------------------

# prod | dev — selects schema.yaml and pins the Terraform flavor default
VARIANT ?= prod
# Required for every ORM call
REGION ?=
# Required to create the stack
COMPARTMENT_ID ?=
# ~/.oci/config profile; empty = pre-authenticated host (Cloud Shell / ORM)
OCI_PROFILE ?=
STACK_NAME ?= weka-oke-test
# What the ORM runner accepts
TF_VERSION ?= 1.5.x
# First existing key wins; override if you keep yours elsewhere. The key is sent
# as CONTENT (ssh_public_key), because the ORM runner has no local files.
SSH_PUBLIC_KEY_FILE ?= $(firstword $(wildcard $(HOME)/.ssh/id_ed25519.pub $(HOME)/.ssh/id_rsa.pub))
QUAY_USERNAME ?=
QUAY_PASSWORD ?=
# Must be "yes" for apply/destroy
CONFIRM ?=

BUILD         := build
STAGE         := $(BUILD)/stage-$(VARIANT)
ZIP           := $(BUILD)/oke-weka-$(VARIANT).zip
STACK_ID_FILE := $(BUILD)/.stack-id.$(VARIANT)
JOB_ID_FILE   := $(BUILD)/.job-id

# Same 3-way auth the stack itself uses: --profile locally, nothing on a
# pre-authenticated host (Cloud Shell / ORM runner).
OCI_ARGS := $(if $(OCI_PROFILE),--profile $(OCI_PROFILE),) $(if $(REGION),--region $(REGION),)

.PHONY: help check fmt fmt-fix validate init zip vars-json stack-create stack-adopt stack-update \
        plan apply destroy stack-delete logs outputs wait-job status \
        local-plan local-apply local-destroy clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  VARIANT=$(VARIANT)  REGION=$(REGION)  STACK_NAME=$(STACK_NAME)"
	@if [ -f $(STACK_ID_FILE) ]; then echo "  stack: $$(cat $(STACK_ID_FILE))"; else echo "  stack: none (run stack-create)"; fi

# ---------------------------------------------------------------------------
# Local checks — no cloud calls, safe to run anytime.
# ---------------------------------------------------------------------------
check: fmt validate ## fmt + validate (no cloud calls)

fmt: ## Check Terraform formatting
	terraform fmt -check -recursive

fmt-fix: ## Rewrite files to canonical formatting
	terraform fmt -recursive

init: ## terraform init without a backend (for validate)
	terraform init -backend=false -input=false

validate: ## terraform validate (inits if needed)
	@test -d .terraform || $(MAKE) --no-print-directory init
	terraform validate

# ---------------------------------------------------------------------------
# Build a stack zip from the WORKING TREE (uncommitted changes included).
#
# Mirrors the release workflow's build step, with one deliberate difference: the
# workflow edits variables.tf in place and restores it with `git checkout --`,
# which would DESTROY uncommitted work locally. We stage a copy instead and edit
# only the copy, so the working tree is never touched.
# ---------------------------------------------------------------------------
zip: ## Build build/oke-weka-$(VARIANT).zip from the current tree
	@case "$(VARIANT)" in prod|dev) ;; *) echo "VARIANT must be prod or dev"; exit 1 ;; esac
	@mkdir -p $(BUILD)
	rm -rf $(STAGE)
	@mkdir -p $(STAGE)
	rsync -a \
	  --exclude '.git/' --exclude '.github/' --exclude '.idea/' --exclude '.vscode/' \
	  --exclude '.terraform/' --exclude '.terraform.lock.hcl' \
	  --exclude '*.tfstate' --exclude '*.tfstate.*' \
	  --exclude 'terraform.tfvars' --exclude '*.auto.tfvars' --exclude 'orm-vars.json' \
	  --exclude '$(BUILD)/' --exclude '.DS_Store' \
	  ./ $(STAGE)/
	# The zip must carry exactly one schema.yaml; the variants are the source of truth.
	cp schema-$(VARIANT).yaml $(STAGE)/schema.yaml
	rm -f $(STAGE)/schema-prod.yaml $(STAGE)/schema-dev.yaml $(STAGE)/Makefile $(STAGE)/TESTING.md
	# Pin the flavor in TERRAFORM, not just the schema: ORM submits no value for a
	# `visible: false` variable, so a schema default never reaches Terraform and a
	# dev zip would fall back to variables.tf's default (production) — building
	# DenseIO nodes for a dev deploy. Rewriting the default is immune to variable
	# precedence because ORM sends nothing to override.
	@if [ "$(VARIANT)" = "dev" ]; then \
	  perl -0pi -e 's/(variable "flavor" \{.*?\n  default     = )"production"/$$1"non-production"/s' $(STAGE)/variables.tf; \
	  grep -q 'default     = "non-production"' $(STAGE)/variables.tf \
	    || { echo "ERROR: failed to pin flavor=non-production"; exit 1; }; \
	  echo "pinned flavor=non-production"; \
	fi
	@rm -f $(abspath $(ZIP))
	cd $(STAGE) && zip -qr $(abspath $(ZIP)) .
	@echo "built $(ZIP) ($$(du -h $(ZIP) | cut -f1)) — $$(unzip -l $(ZIP) | tail -1)"
	@unzip -l $(ZIP) | grep -qE ' schema\.yaml$$' || { echo "ERROR: schema.yaml missing from zip"; exit 1; }
	@unzip -l $(ZIP) | grep -qE 'crds/.*\.yaml$$' || { echo "ERROR: crds/ missing from zip"; exit 1; }

# ---------------------------------------------------------------------------
# ORM lifecycle.
#
# tenancy_ocid / compartment_ocid / region MUST be sent explicitly. They are
# "reserved" variables that Resource Manager auto-populates only for stacks
# created through the CONSOLE (which is what the note on variables.tf:38 means) —
# a stack created via the API/CLI gets no injection, and the apply dies in seconds
# with "No value for required variable" before creating anything.
#
# The names must match variables.tf exactly: tenancy_ocid / compartment_ocid, NOT
# the tenancy_id / compartment_id that README.md still shows.
# ---------------------------------------------------------------------------

# Tenancy OCID. Auto-derived from the OCI CLI when not given.
TENANCY_ID ?=

# production_tier to send. Frozen by guard.tf after the first apply, so changing it
# needs a NEW stack.
#
# Bare-metal testing defaults to E4 instead of letting variables.tf's 8-node E5
# default apply. E5 DenseIO in eu-frankfurt-1 is routinely short: an 8 x E5 apply
# failed with "Out of host capacity" after launching 6 of 8 hosts, and the
# capacity.tf preflight had passed moments earlier because the capacity report
# only exposes a per-AD availability_status, never the host COUNT — so "6 of 8
# available" reads as AVAILABLE. E4 has filled every request so far.
#
# Release builds are unaffected: this only sets a stack INPUT for test stacks, and
# the shipped default in variables.tf is still the 367 TB E5 tier. Pass TIER=
# explicitly for another capacity, or TIER='' to fall back to that default.
ifeq ($(VARIANT),prod)
TIER ?= 245 TB usable - 8 x BM.DenseIO.E4.128 (8 NVMe)
else
TIER ?=
endif

# production_node_count to send — override the worker count the tier implies, so a
# bare-metal change can be tested on fewer hosts than the smallest tier's 8 when
# DenseIO capacity is short (e.g. NODES=6, which derives 3+2+1). The tier still
# fixes the shape and per-node drives, so its advertised capacity no longer holds.
# Ignored for VARIANT=dev, where the count comes from node_count.
NODES ?=

# WEKA operator Helm chart version. Empty = the schema/variables.tf default.
# Unlike TIER this is NOT frozen by guard.tf, so it can be changed on a re-apply.
OPERATOR_VERSION ?=

vars-json: guard-REGION guard-COMPARTMENT_ID guard-QUAY_USERNAME guard-QUAY_PASSWORD ## Write build/vars.json (stack inputs)
	@mkdir -p $(BUILD)
	@test -n "$(SSH_PUBLIC_KEY_FILE)" -a -f "$(SSH_PUBLIC_KEY_FILE)" || { \
	  echo "ERROR: no SSH public key found (looked for ~/.ssh/id_ed25519.pub, ~/.ssh/id_rsa.pub)"; \
	  echo "       pass SSH_PUBLIC_KEY_FILE=/path/to/key.pub"; exit 1; }
	@tenancy='$(TENANCY_ID)'; \
	 if [ -z "$$tenancy" ]; then \
	   tenancy=$$(oci iam region-subscription list $(OCI_ARGS) --query 'data[0]."tenancy-id"' --raw-output 2>/dev/null || true); \
	 fi; \
	 if [ -z "$$tenancy" ]; then \
	   tenancy=$$(awk -F= '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$$2); print $$2; exit}' $$HOME/.oci/config 2>/dev/null || true); \
	 fi; \
	 test -n "$$tenancy" || { echo "ERROR: could not determine the tenancy OCID — pass TENANCY_ID=ocid1.tenancy..."; exit 1; }; \
	 TENANCY="$$tenancy" COMPARTMENT='$(COMPARTMENT_ID)' REGION_V='$(REGION)' TIER='$(TIER)' \
	 OPVER='$(OPERATOR_VERSION)' NODES='$(NODES)' \
	 QUAY_USERNAME='$(QUAY_USERNAME)' QUAY_PASSWORD='$(QUAY_PASSWORD)' \
	 SSH_KEY_FILE='$(SSH_PUBLIC_KEY_FILE)' python3 -c 'import json,os; \
	d={ \
	  "tenancy_ocid":     os.environ["TENANCY"], \
	  "compartment_ocid": os.environ["COMPARTMENT"], \
	  "region":           os.environ["REGION_V"], \
	  "ssh_public_key":   open(os.environ["SSH_KEY_FILE"]).read().strip(), \
	  "quay_username":    os.environ["QUAY_USERNAME"], \
	  "quay_password":    os.environ["QUAY_PASSWORD"]}; \
	d.update({"production_tier": os.environ["TIER"]} if os.environ.get("TIER") else {}); \
	d.update({"production_node_count": os.environ["NODES"]} if os.environ.get("NODES") else {}); \
	d.update({"operator_version": os.environ["OPVER"]} if os.environ.get("OPVER") else {}); \
	print(json.dumps(d))' > $(BUILD)/vars.json; \
	 chmod 600 $(BUILD)/vars.json; \
	 echo "wrote $(BUILD)/vars.json (tenancy $$tenancy$(if $(TIER), / tier: $(TIER),)$(if $(NODES), / nodes: $(NODES),)$(if $(OPERATOR_VERSION), / operator: $(OPERATOR_VERSION),))"

stack-create: zip vars-json ## Create an ORM stack from the current tree
	@id=$$(oci resource-manager stack create $(OCI_ARGS) \
	   --compartment-id $(COMPARTMENT_ID) \
	   --config-source $(ZIP) \
	   --terraform-version $(TF_VERSION) \
	   --variables file://$(abspath $(BUILD)/vars.json) \
	   --display-name '$(STACK_NAME)' \
	   --query 'data.id' --raw-output); \
	 echo "$$id" > $(STACK_ID_FILE); \
	 echo "created stack $$id"; \
	 echo "next: make plan"

stack-adopt: guard-STACK_ID ## Point the Makefile at an EXISTING stack (STACK_ID=ocid1.ormstack...)
	@mkdir -p $(BUILD)
	@case '$(STACK_ID)' in ocid1.ormstack.*) ;; *) echo "ERROR: not an ORM stack OCID: $(STACK_ID)"; exit 1 ;; esac
	@echo '$(STACK_ID)' > $(STACK_ID_FILE)
	@echo "adopted $(STACK_ID)"
	@echo "next: make stack-update plan   # push the working tree, then dry-run"

stack-update: zip vars-json ## Push the current tree AND variables to the existing stack
	@oci resource-manager stack update $(OCI_ARGS) \
	  --stack-id $$(cat $(STACK_ID_FILE)) \
	  --config-source $(ZIP) \
	  --variables file://$(abspath $(BUILD)/vars.json) \
	  --force --query 'data.id' --raw-output >/dev/null
	@echo "stack updated: config from $(ZIP), variables from $(BUILD)/vars.json"

plan: guard-REGION ## Run a plan job (free dry run; also validates schema.yaml)
	@job=$$(oci resource-manager job create-plan-job $(OCI_ARGS) \
	  --stack-id $$(cat $(STACK_ID_FILE)) --query 'data.id' --raw-output); \
	 echo "$$job" > $(JOB_ID_FILE); echo "plan job $$job"
	@$(MAKE) --no-print-directory wait-job

apply: guard-REGION guard-CONFIRM ## Run an apply job (CONFIRM=yes; spends money)
	@job=$$(oci resource-manager job create-apply-job $(OCI_ARGS) \
	  --stack-id $$(cat $(STACK_ID_FILE)) --execution-plan-strategy AUTO_APPROVED \
	  --query 'data.id' --raw-output); \
	 echo "$$job" > $(JOB_ID_FILE); echo "apply job $$job (15-20 min on bare metal)"
	@$(MAKE) --no-print-directory wait-job
	@$(MAKE) --no-print-directory outputs

destroy: guard-REGION guard-CONFIRM ## Run a destroy job (CONFIRM=yes)
	@job=$$(oci resource-manager job create-destroy-job $(OCI_ARGS) \
	  --stack-id $$(cat $(STACK_ID_FILE)) --execution-plan-strategy AUTO_APPROVED \
	  --query 'data.id' --raw-output); \
	 echo "$$job" > $(JOB_ID_FILE); echo "destroy job $$job"
	@$(MAKE) --no-print-directory wait-job

stack-delete: guard-REGION ## Delete the stack (destroy first!)
	@oci resource-manager stack delete $(OCI_ARGS) --stack-id $$(cat $(STACK_ID_FILE)) --force
	@rm -f $(STACK_ID_FILE)
	@echo "stack deleted"

wait-job: ## Poll the last job to a terminal state
	@job=$$(cat $(JOB_ID_FILE)); \
	 while :; do \
	   st=$$(oci resource-manager job get $(OCI_ARGS) --job-id $$job --query 'data."lifecycle-state"' --raw-output); \
	   printf '  %s %s\n' "$$(date +%H:%M:%S)" "$$st"; \
	   case "$$st" in \
	     SUCCEEDED) echo "job SUCCEEDED"; break ;; \
	     FAILED|CANCELED) echo "job $$st — logs follow"; $(MAKE) --no-print-directory logs; exit 1 ;; \
	   esac; \
	   sleep 20; \
	 done

logs: guard-REGION ## Print logs for the last job
	@oci resource-manager job get-job-logs-content $(OCI_ARGS) --job-id $$(cat $(JOB_ID_FILE)) --raw-output

status: guard-REGION ## Show the last job's state
	@oci resource-manager job get $(OCI_ARGS) --job-id $$(cat $(JOB_ID_FILE)) \
	  --query 'data.{state:"lifecycle-state",operation:operation,time:"time-created"}'

outputs: guard-REGION ## Show stack outputs (kubeconfig command, weka_sizing, ...)
	@oci resource-manager stack list-associated-resources $(OCI_ARGS) \
	  --stack-id $$(cat $(STACK_ID_FILE)) --query 'data[*]."resource-type"' 2>/dev/null | head -20 || true
	@oci resource-manager stack get-stack-tf-state $(OCI_ARGS) \
	  --stack-id $$(cat $(STACK_ID_FILE)) --file - 2>/dev/null \
	  | python3 -c 'import json,sys; \
	o=json.load(sys.stdin).get("outputs",{}); \
	[print("%s = %s" % (k, v.get("value"))) for k,v in o.items()]' || echo "(no state yet)"

# ---------------------------------------------------------------------------
# Local Terraform path — faster than ORM, but runs on YOUR auth and needs
# terraform.tfvars (see terraform.tfvars.example).
# ---------------------------------------------------------------------------
local-plan: ## terraform plan against the working tree
	terraform plan

local-apply: guard-CONFIRM ## terraform apply (CONFIRM=yes)
	terraform apply

local-destroy: guard-CONFIRM ## terraform destroy (CONFIRM=yes)
	terraform destroy

clean: ## Remove build artifacts (keeps stack ids)
	rm -rf $(BUILD)/stage-* $(BUILD)/*.zip $(BUILD)/vars.json

guard-%:
	@if [ -z "$($*)" ]; then \
	  echo "ERROR: $* is required — e.g. make $@ $*=<value>"; \
	  [ "$*" = "CONFIRM" ] && echo "       (this target costs money or destroys resources; pass CONFIRM=yes)"; \
	  exit 1; \
	fi
