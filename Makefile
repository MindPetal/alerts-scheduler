REGION ?= us-east-1
GH_OWNER ?= MindPetal
STATE_BUCKET ?= alerts-scheduler-tf-state

.PHONY: state-bucket init plan apply destroy

state-bucket:
	cd s3-tf-state && terraform init -input=false
	cd s3-tf-state && \
		if ! terraform state show aws_s3_bucket.tf_state >/dev/null 2>&1 && \
		   aws s3api head-bucket --bucket "$(STATE_BUCKET)" 2>/dev/null; then \
			terraform import -input=false \
				-var="region=$(REGION)" -var="bucket_name=$(STATE_BUCKET)" \
				aws_s3_bucket.tf_state "$(STATE_BUCKET)"; \
		fi
	cd s3-tf-state && terraform apply -auto-approve -input=false \
		-var="region=$(REGION)" -var="bucket_name=$(STATE_BUCKET)"

init: state-bucket
	terraform init -input=false \
		-backend-config="bucket=$(STATE_BUCKET)" \
		-backend-config="region=$(REGION)"

plan: init
	terraform plan -var="region=$(REGION)" -var="gh_owner=$(GH_OWNER)"

apply: init
	terraform apply -var="region=$(REGION)" -var="gh_owner=$(GH_OWNER)"

destroy:
	terraform destroy
