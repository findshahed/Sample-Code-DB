# infrastructure/main.tf
terraform {
  required_version = ">= 1.0"
  backend "gcs" {
    bucket = "tf-state-${var.project_id}"
    prefix = "trade-pipeline/${var.environment}"
  }
}

module "gcp" {
  source = "./modules/gcp"
  
  project_id      = var.project_id
  region          = var.region
  environment     = var.environment
  billing_account = var.billing_account
  org_id          = var.org_id
  
  dataflow_service_account = var.dataflow_service_account
  composer_service_account = var.composer_service_account
  
  # Networking
  vpc_name     = var.vpc_name
  subnet_name  = var.subnet_name
  subnet_cidr  = var.subnet_cidr
  
  # Pub/Sub
  pubsub_topic_name      = var.pubsub_topic_name
  pubsub_subscription_name = var.pubsub_subscription_name
  
  # Dataflow
  dataflow_job_name     = var.dataflow_job_name
  dataflow_template_path = var.dataflow_template_path
  dataflow_max_workers  = var.dataflow_max_workers
  
  # Composer
  composer_name           = var.composer_name
  composer_node_count     = var.composer_node_count
  composer_machine_type   = var.composer_machine_type
  composer_disk_size_gb   = var.composer_disk_size_gb
  
  # Storage
  bucket_names = var.bucket_names
  
  # Monitoring
  alert_notification_email = var.alert_notification_email
  alert_notification_slack = var.alert_notification_slack
}

module "snowflake" {
  source = "./modules/snowflake"
  
  environment = var.environment
  project_id  = var.project_id
  
  # Database
  database_name = var.snowflake_database_name
  schemas       = var.snowflake_schemas
  data_retention_days = var.snowflake_data_retention_days
  
  # Warehouses
  warehouses = var.snowflake_warehouses
  
  # Users
  users = var.snowflake_users
  
  # Roles
  roles = var.snowflake_roles
  
  # Storage Integration
  gcp_project_id     = var.project_id
  gcp_service_account_email = module.gcp.storage_service_account_email
  storage_allowed_locations = var.snowflake_storage_allowed_locations
  
  # Network Policy
  allowed_ip_ranges = var.snowflake_allowed_ip_ranges
  
  # Secrets (passed from GCP module)
  secrets = {
    dataflow_service_account_key = module.gcp.dataflow_service_account_key
  }
}

module "vpc" {
  source = "./modules/vpc"
  
  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  
  network_name    = var.vpc_name
  subnet_name     = var.subnet_name
  subnet_cidr     = var.subnet_cidr
  subnet_region   = var.region
  
  # Firewall rules
  allowed_ingress_ranges = var.allowed_ingress_ranges
  allowed_egress_ranges  = var.allowed_egress_ranges
  
  # Private service access
  enable_private_service_access = true
  enable_private_ip_google_access = true
}

# Output the service account email for Snowflake integration
resource "google_service_account_key" "snowflake_integration" {
  service_account_id = module.gcp.storage_service_account_name
  
  # Store the key in a secure location
  keepers = {
    environment = var.environment
    timestamp   = timestamp()
  }
}

# Store sensitive outputs in Google Secret Manager
resource "google_secret_manager_secret" "snowflake_credentials" {
  secret_id = "snowflake-credentials-${var.environment}"
  
  replication {
    automatic = true
  }
  
  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }
}

resource "google_secret_manager_secret_version" "snowflake_credentials" {
  secret = google_secret_manager_secret.snowflake_credentials.id
  
  secret_data = jsonencode({
    account   = module.snowflake.account_url
    user      = module.snowflake.trade_loader_user
    password  = module.snowflake.trade_loader_password
    warehouse = module.snowflake.warehouse_names["load"]
    database  = module.snowflake.database_name
    role      = module.snowflake.role_names["loader"]
  })
}

# IAM binding for service accounts to access secrets
resource "google_secret_manager_secret_iam_member" "dataflow_secret_access" {
  secret_id = google_secret_manager_secret.snowflake_credentials.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${module.gcp.dataflow_service_account_email}"
}

resource "google_secret_manager_secret_iam_member" "composer_secret_access" {
  secret_id = google_secret_manager_secret.snowflake_credentials.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${module.gcp.composer_service_account_email}"
}

# Create Cloud Scheduler job for pipeline monitoring
resource "google_cloud_scheduler_job" "pipeline_monitoring" {
  name        = "trade-pipeline-monitoring-${var.environment}"
  description = "Schedule pipeline health checks"
  schedule    = "*/15 * * * *"  # Every 15 minutes
  time_zone   = "UTC"
  
  http_target {
    http_method = "POST"
    uri         = "https://cloudbuild.googleapis.com/v1/projects/${var.project_id}/triggers/${module.gcp.cloud_build_trigger_id}:run"
    
    oauth_token {
      service_account_email = module.gcp.composer_service_account_email
    }
  }
  
  depends_on = [module.gcp]
}
