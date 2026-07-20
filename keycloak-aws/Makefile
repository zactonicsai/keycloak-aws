# =============================================================================
# Makefile - shortcuts for common commands
# =============================================================================
# Run `make help` to see everything available.
# `make` reads this file; each target is a named shortcut.
# =============================================================================

ENV ?= dev
DIR := environments/$(ENV)

.PHONY: help bootstrap init plan apply destroy output fmt validate password url logs health

help:  ## Show this help
	@echo "Keycloak on AWS - available commands:"
	@echo ""
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-12s %s\n", $$1, $$2}'
	@echo ""
	@echo "Target a different environment with:  make plan ENV=prod"

bootstrap:  ## Create the S3 state bucket (run once)
	./scripts/bootstrap-state-bucket.sh

init:  ## Initialize Terraform
	cd $(DIR) && terraform init

plan:  ## Preview changes without applying
	cd $(DIR) && terraform plan

apply:  ## Build the infrastructure
	cd $(DIR) && terraform apply

destroy:  ## Tear everything down
	cd $(DIR) && terraform destroy

output:  ## Show all outputs
	cd $(DIR) && terraform output

fmt:  ## Format all .tf files consistently
	terraform fmt -recursive

validate:  ## Check syntax and internal consistency
	cd $(DIR) && terraform validate

password:  ## Print the Keycloak admin password
	@cd $(DIR) && eval "$$(terraform output -raw get_admin_password)"

url:  ## Print the admin console URL
	@cd $(DIR) && terraform output -raw keycloak_admin_console_url

realm:  ## Show which realm definition was used
	@cd $(DIR) && terraform output -raw realm_source

health:  ## Check whether the instance is passing health checks
	@cd $(DIR) && aws elbv2 describe-target-health \
		--target-group-arn $$(terraform output -raw target_group_arn 2>/dev/null) \
		--query 'TargetHealthDescriptions[].TargetHealth.State' --output text

myip:  ## Show your current public IP (compare to terraform.tfvars)
	@echo "Your IP: $$(curl -s ifconfig.me)"
	@cd $(DIR) && echo "Allowed: $$(terraform output -json allowed_admin_ips 2>/dev/null)"
