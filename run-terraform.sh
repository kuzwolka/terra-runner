#!/bin/bash
# Enhanced run-terraform.sh with validation

set -e

PROJECT_NAME=$1
COMMAND=$2
VARIABLES_JSON=$3
AWS_CREDENTIALS_JSON=$4

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
echo "Target Account: $(echo $AWS_CREDENTIALS_JSON | jq -r '.account_id // "default"')"
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
    dynamodb_table = "$LOCK_TABLE"
    encrypt        = true
  }
}
EOT

# Set up AWS provider configuration with credentials if provided
if [ -n "$AWS_CREDENTIALS_JSON" ] && [ "$AWS_CREDENTIALS_JSON" != "{}" ]; then
    echo "Configuring AWS provider with supplied credentials..."
    
    # Parse credentials from JSON
    ACCESS_KEY=$(echo $AWS_CREDENTIALS_JSON | jq -r '.access_key // empty')
    SECRET_KEY=$(echo $AWS_CREDENTIALS_JSON | jq -r '.secret_key // empty')
    SESSION_TOKEN=$(echo $AWS_CREDENTIALS_JSON | jq -r '.session_token // empty')
    REGION=$(echo $AWS_CREDENTIALS_JSON | jq -r '.region // empty')
    ACCOUNT_ID=$(echo $AWS_CREDENTIALS_JSON | jq -r '.account_id // empty')
    
    # If no region provided, use the default
    if [ -z "$REGION" ]; then
        REGION="$AWS_REGION"
    fi
    
    # Create or modify provider configuration
    if grep -q "provider \"aws\"" *.tf 2>/dev/null; then
        echo "AWS provider found in configuration, creating override..."
        cat > provider_override.tf <<EOT
provider "aws" {
  region     = "$REGION"
  access_key = "$ACCESS_KEY"
  secret_key = "$SECRET_KEY"
$([ -n "$SESSION_TOKEN" ] && echo "  token      = \"$SESSION_TOKEN\"")
}
EOT
    else
        echo "Creating AWS provider configuration..."
        cat > provider.tf <<EOT
provider "aws" {
  region     = "$REGION"
  access_key = "$ACCESS_KEY"
  secret_key = "$SECRET_KEY"
$([ -n "$SESSION_TOKEN" ] && echo "  token      = \"$SESSION_TOKEN\"")
}
EOT
    fi
    
    # Add account info to the logs
    if [ -n "$ACCOUNT_ID" ]; then
        echo "Target AWS Account: $ACCOUNT_ID in $REGION"
    else
        echo "Target AWS Region: $REGION (account ID not provided)"
    fi
else
    echo "Using default AWS credentials from instance profile"
    if ! grep -q "provider \"aws\"" *.tf 2>/dev/null; then
        echo "Creating default AWS provider configuration..."
        cat > provider.tf <<EOT
provider "aws" {
  region = "$AWS_REGION"
}
EOT
    fi
fi

# Initialize Terraform
echo "Initializing Terraform..."
terraform init

# Create terraform.tfvars.json if variables provided
if [ ! -z "$VARIABLES_JSON" ]; then
  echo "Creating variables file..."
  echo "$VARIABLES_JSON" > terraform.tfvars.json
fi

# Run the requested command
echo "Running Terraform $COMMAND..."
case "$COMMAND" in
  "plan")
    terraform plan -out=tfplan
    ;;
  "apply")
    terraform apply -auto-approve
    ;;
  "destroy")
    terraform destroy -auto-approve
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