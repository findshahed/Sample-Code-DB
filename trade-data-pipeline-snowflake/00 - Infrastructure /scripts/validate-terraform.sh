#!/bin/bash
# infrastructure/scripts/validate-terraform.sh
#!/bin/bash
set -e

# Script to validate Terraform configuration

ENVIRONMENT=${1:-"dev"}
ACTION=${2:-"plan"}

if [ "$ACTION" != "plan" ] && [ "$ACTION" != "apply" ]; then
    echo "Usage: $0 [environment] [plan|apply]"
    echo "Default: environment=dev, action=plan"
    exit 1
fi

echo "Validating Terraform configuration for environment: $ENVIRONMENT"

# Check for required variables
REQUIRED_VARS=(
    "GOOGLE_APPLICATION_CREDENTIALS"
    "TF_VAR_project_id"
    "TF_VAR_snowflake_account"
    "TF_VAR_snowflake_username"
    "TF_VAR_snowflake_password"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: Environment variable $var is not set"
        exit 1
    fi
done

# Initialize Terraform
echo "Initializing Terraform..."
terraform init -reconfigure \
    -backend-config="bucket=tf-state-$TF_VAR_project_id" \
    -backend-config="prefix=trade-pipeline/$ENVIRONMENT"

# Select workspace
echo "Selecting workspace: $ENVIRONMENT"
terraform workspace select "$ENVIRONMENT" || terraform workspace new "$ENVIRONMENT"

# Validate configuration
echo "Validating Terraform configuration..."
terraform validate

# Format code
echo "Formatting Terraform code..."
terraform fmt -recursive

# Run tflint if available
if command -v tflint &> /dev/null; then
    echo "Running tflint..."
    tflint --recursive
fi

# Run terraform-docs if available
if command -v terraform-docs &> /dev/null; then
    echo "Generating documentation..."
    terraform-docs markdown table --output-file README.md .
fi

# Execute action
echo "Running terraform $ACTION..."
if [ "$ACTION" = "plan" ]; then
    terraform plan \
        -var="environment=$ENVIRONMENT" \
        -out=tfplan-$ENVIRONMENT
elif [ "$ACTION" = "apply" ]; then
    if [ -f "tfplan-$ENVIRONMENT" ]; then
        terraform apply "tfplan-$ENVIRONMENT"
    else
        terraform apply \
            -var="environment=$ENVIRONMENT" \
            -auto-approve
    fi
fi

echo "Terraform $ACTION completed successfully!"
