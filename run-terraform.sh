#!/bin/bash
# Enhanced run-terraform.sh with AWS credentials removed

set -e

PROJECT_NAME=$1
COMMAND=$2

# Load environment variables
source /etc/environment

# Validate project exists in S3 before proceeding
echo "Validating project exists in S3..."
if ! aws s3 ls "s3://$CONFIG_BUCKET/$PROJECT_NAME.zip" --region "$AWS_REGION" > /dev/null 2>&1; then
    echo "ERROR: Project '$PROJECT_NAME' not found in S3 bucket $CONFIG_BUCKET"
    echo "Available projects:"
    aws s3 ls "s3://$CONFIG_BUCKET/" --region "$AWS_REGION" | grep "\.zip$" | awk '{print $4}' | sed 's/\.zip$//'
    exit 1
fi

# Generate unique run ID and state key to prevent conflicts
RUN_ID=$(date +%s)-$(openssl rand -hex 4)
STATE_KEY="$PROJECT_NAME/$RUN_ID/terraform.tfstate"

# Set up logging with enhanced info
LOG_FILE="/home/terraform/logs/terraform-$PROJECT_NAME-$RUN_ID.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==== Terraform Runner (Enhanced) ====="
echo "Run ID: $RUN_ID"
echo "Project: $PROJECT_NAME"
echo "Command: $COMMAND"
echo "State Key: $STATE_KEY"
echo "======================================="

# Create isolated workspace
WORK_DIR="/home/terraform/projects/$PROJECT_NAME-$RUN_ID"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Download with retry logic
echo "Downloading project from S3..."
for i in {1..3}; do
    if aws s3 cp "s3://$CONFIG_BUCKET/$PROJECT_NAME.zip" ./project.zip --region "$AWS_REGION"; then
        break
    elif [ $i -eq 3 ]; then
        echo "ERROR: Failed to download project after 3 attempts"
        exit 1
    else
        echo "Download attempt $i failed, retrying..."
        sleep 5
    fi
done

unzip -o project.zip
rm project.zip

# Use unique state key to prevent conflicts
cat > backend.tf <<EOT
terraform {
  backend "s3" {
    bucket         = "$STATE_BUCKET"
    key            = "$STATE_KEY"
    region         = "$AWS_REGION"
    encrypt        = true
  }
}
EOT

# Initialize Terraform
echo "Initializing Terraform..."
terraform init

# Run the requested command
echo "Running Terraform $COMMAND..."
case "$COMMAND" in
  "plan")
    terraform plan -out=tfplan -var-file="uservar.tfvars.json"
    ;;
  "apply")
    terraform apply -auto-approve -var-file="uservar.tfvars.json"
    ;;
  "destroy")
    terraform destroy -auto-approve -var-file="uservar.tfvars.json"
    ;;
  "output")
    terraform output -json
    ;;
  *)
    echo "Unknown command: $COMMAND"
    exit 1
    ;;
esac

echo "Terraform execution completed successfully!"

# Clean up
echo "Cleaning up workspace..."
cd /home/terraform/projects
rm -rf "$WORK_DIR"

exit 0