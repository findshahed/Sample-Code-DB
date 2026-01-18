#!/bin/bash
# infrastructure/scripts/setup-gcp-service-accounts.sh
#!/bin/bash
set -e

# Script to set up GCP service accounts and permissions

PROJECT_ID=$1
ENVIRONMENT=$2
REGION=${3:-"us-central1"}

if [ -z "$PROJECT_ID" ] || [ -z "$ENVIRONMENT" ]; then
    echo "Usage: $0 <project_id> <environment> [region]"
    exit 1
fi

echo "Setting up GCP service accounts for project: $PROJECT_ID, environment: $ENVIRONMENT"

# Enable required APIs
echo "Enabling required APIs..."
gcloud services enable \
    compute.googleapis.com \
    dataflow.googleapis.com \
    composer.googleapis.com \
    pubsub.googleapis.com \
    storage.googleapis.com \
    bigquery.googleapis.com \
    iam.googleapis.com \
    cloudresourcemanager.googleapis.com \
    servicenetworking.googleapis.com \
    secretmanager.googleapis.com \
    cloudscheduler.googleapis.com \
    monitoring.googleapis.com \
    logging.googleapis.com \
    cloudbuild.googleapis.com \
    --project=$PROJECT_ID

# Create service accounts
echo "Creating service accounts..."

# Dataflow service account
DATAFLOW_SA="dataflow-sa-$ENVIRONMENT"
gcloud iam service-accounts create $DATAFLOW_SA \
    --display-name="DataFlow Service Account" \
    --project=$PROJECT_ID

# Composer service account
COMPOSER_SA="composer-sa-$ENVIRONMENT"
gcloud iam service-accounts create $COMPOSER_SA \
    --display-name="Composer Service Account" \
    --project=$PROJECT_ID

# Storage service account for Snowflake
STORAGE_SA="storage-sa-$ENVIRONMENT"
gcloud iam service-accounts create $STORAGE_SA \
    --display-name="Storage Service Account for Snowflake" \
    --project=$PROJECT_ID

# Assign IAM roles
echo "Assigning IAM roles..."

# Dataflow roles
DATAFLOW_SA_EMAIL="$DATAFLOW_SA@$PROJECT_ID.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$DATAFLOW_SA_EMAIL" \
    --role="roles/dataflow.admin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$DATAFLOW_SA_EMAIL" \
    --role="roles/dataflow.worker"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$DATAFLOW_SA_EMAIL" \
    --role="roles/pubsub.subscriber"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$DATAFLOW_SA_EMAIL" \
    --role="roles/storage.admin"

# Composer roles
COMPOSER_SA_EMAIL="$COMPOSER_SA@$PROJECT_ID.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$COMPOSER_SA_EMAIL" \
    --role="roles/composer.worker"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$COMPOSER_SA_EMAIL" \
    --role="roles/composer.environmentAndStorageObjectViewer"

# Storage roles for Snowflake
STORAGE_SA_EMAIL="$STORAGE_SA@$PROJECT_ID.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$STORAGE_SA_EMAIL" \
    --role="roles/storage.objectAdmin"

# Create key for storage service account (for Snowflake integration)
echo "Creating service account key for Snowflake integration..."
gcloud iam service-accounts keys create snowflake-key.json \
    --iam-account=$STORAGE_SA_EMAIL

echo "Service account setup complete!"
echo ""
echo "Service account emails:"
echo "Dataflow: $DATAFLOW_SA_EMAIL"
echo "Composer: $COMPOSER_SA_EMAIL"
echo "Storage: $STORAGE_SA_EMAIL"
echo ""
echo "Snowflake integration key saved to: snowflake-key.json"
