# 00-infrastructure/terraform/main.tf
terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
    snowflake = {
      source  = "chanzuckerberg/snowflake"
      version = "~> 0.40"
    }
    random = {
      source = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  backend "gcs" {
    bucket = "tf-state-bucket"
    prefix = "trade-pipeline"
  }
}

# GCP Provider
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

# Snowflake Provider
provider "snowflake" {
  account  = var.snowflake_account
  username = var.snowflake_username
  password = var.snowflake_password
  role     = "ACCOUNTADMIN"
}

# Random password for Snowflake users
resource "random_password" "trade_user_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Snowflake Resources
module "snowflake_infrastructure" {
  source = "./modules/snowflake"
  
  database_name   = "TRADE_DB"
  environment     = var.environment
  trade_user_pass = random_password.trade_user_password.result
  
  warehouses = {
    load = {
      size         = "X-SMALL"
      auto_suspend = 300
      scaling_policy = "STANDARD"
    }
    transform = {
      size         = "SMALL"
      auto_suspend = 300
      scaling_policy = "ECONOMY"
    }
    analytics = {
      size         = "MEDIUM"
      auto_suspend = 300
      scaling_policy = "STANDARD"
    }
  }
  
  schemas = ["RAW", "PROCESSED", "ANALYTICS", "AUDIT"]
}

# GCP Pub/Sub
resource "google_pubsub_topic" "trades_topic" {
  name = "trades-topic-${var.environment}"
  
  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }
  
  message_retention_duration = "604800s" # 7 days
  
  schema_settings {
    schema   = "projects/${var.gcp_project_id}/schemas/trade-schema"
    encoding = "JSON"
  }
}

resource "google_pubsub_subscription" "dataflow_subscription" {
  name  = "trades-dataflow-sub-${var.environment}"
  topic = google_pubsub_topic.trades_topic.name
  
  ack_deadline_seconds = 600
  
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
  
  enable_message_ordering = true
  
  expiration_policy {
    ttl = "" # Never expire
  }
  
  dead_letter_policy {
    dead_letter_topic = google_pubsub_topic.dead_letter_topic.id
    max_delivery_attempts = 5
  }
}

# GCS Buckets
resource "google_storage_bucket" "trade_data_bucket" {
  name          = "${var.gcp_project_id}-trade-data-${var.environment}"
  location      = var.gcp_region
  force_destroy = var.environment == "dev"
  
  uniform_bucket_level_access = true
  
  versioning {
    enabled = true
  }
  
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
  
  labels = {
    environment = var.environment
    data-class  = "confidential"
  }
}

# Dataflow Job
resource "google_dataflow_job" "trade_processing" {
  name              = "trade-processing-${var.environment}"
  template_gcs_path = var.dataflow_template_path
  temp_gcs_location = "gs://${google_storage_bucket.trade_data_bucket.name}/temp"
  region            = var.gcp_region
  
  parameters = {
    inputSubscription = google_pubsub_subscription.dataflow_subscription.id
    snowflakeAccount  = var.snowflake_account
    snowflakeUser     = module.snowflake_infrastructure.trade_loader_user
    snowflakePassword = random_password.trade_user_password.result
    snowflakeDatabase = module.snowflake_infrastructure.database_name
    snowflakeSchema   = "PROCESSED"
    outputTable       = "VALID_TRADES"
    environment       = var.environment
  }
  
  on_delete = "cancel"
  
  labels = {
    environment = var.environment
  }
}

# Cloud Composer (Airflow)
resource "google_composer_environment" "trade_orchestration" {
  name   = "trade-orchestration-${var.environment}"
  region = var.gcp_region
  config {
    node_config {
      zone         = "${var.gcp_region}-a"
      machine_type = "n1-standard-4"
      disk_size_gb = 100
      
      service_account = var.service_account_email
      
      ip_allocation_policy {
        cluster_secondary_range_name  = "pods"
        services_secondary_range_name = "services"
      }
    }
    
    software_config {
      image_version = "composer-2-airflow-2"
      
      env_variables = {
        AIRFLOW_VAR_SNOWFLAKE_ACCOUNT  = var.snowflake_account
        AIRFLOW_VAR_SNOWFLAKE_USER     = module.snowflake_infrastructure.trade_loader_user
        AIRFLOW_VAR_SNOWFLAKE_PASSWORD = random_password.trade_user_password.result
        AIRFLOW_VAR_SNOWFLAKE_DATABASE = module.snowflake_infrastructure.database_name
        AIRFLOW_VAR_GCP_PROJECT        = var.gcp_project_id
        AIRFLOW_VAR_ENVIRONMENT        = var.environment
      }
      
      pypi_packages = {
        "apache-airflow-providers-snowflake" = ">=4.0.0"
        "snowflake-connector-python"         = ">=3.0.0"
        "snowflake-sqlalchemy"               = ">=1.4.0"
      }
    }
    
    private_environment_config {
      enable_private_endpoint = true
      cloud_sql_ipv4_cidr_block = "10.0.0.0/16"
    }
  }
  
  labels = {
    environment = var.environment
  }
}

# Monitoring and Alerting
resource "google_monitoring_alert_policy" "dataflow_failure" {
  display_name = "Dataflow Job Failure - ${var.environment}"
  combiner     = "OR"
  
  conditions {
    display_name = "Dataflow Job Failed"
    
    condition_threshold {
      filter     = "resource.type=\"dataflow_job\" AND metric.type=\"dataflow.googleapis.com/job/current_state\" AND resource.labels.environment=\"${var.environment}\""
      comparison = "COMPARISON_LT"
      threshold_value = 3 # Running state
      duration   = "300s"
      
      trigger {
        count = 1
      }
      
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_MEAN"
      }
    }
  }
  
  notification_channels = [var.alert_notification_channel]
  
  documentation {
    content = "The trade processing pipeline has failed. Please check the Dataflow job logs and Snowpipe status."
  }
  
  labels = {
    environment = var.environment
  }
}

# Outputs
output "snowflake_connection_string" {
  value     = "${var.snowflake_account}.snowflakecomputing.com"
  sensitive = false
}

output "snowflake_trade_user" {
  value     = module.snowflake_infrastructure.trade_loader_user
  sensitive = false
}

output "pubsub_topic_id" {
  value = google_pubsub_topic.trades_topic.id
}

output "dataflow_job_id" {
  value = google_dataflow_job.trade_processing.id
}

output "airflow_uri" {
  value = google_composer_environment.trade_orchestration.config.0.airflow_uri
}
