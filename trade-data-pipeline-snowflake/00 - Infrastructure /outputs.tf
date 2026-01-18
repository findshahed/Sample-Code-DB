# infrastructure/outputs.tf
# GCP Outputs
output "gcp_project_id" {
  description = "GCP Project ID"
  value       = module.gcp.project_id
  sensitive   = false
}

output "vpc_network" {
  description = "VPC network details"
  value = {
    name    = module.vpc.network_name
    id      = module.vpc.network_id
    subnets = module.vpc.subnets
  }
}

output "pubsub_topic" {
  description = "Pub/Sub topic details"
  value = {
    name = module.gcp.pubsub_topic_name
    id   = module.gcp.pubsub_topic_id
  }
}

output "dataflow_job" {
  description = "Dataflow job details"
  value = {
    name     = module.gcp.dataflow_job_name
    id       = module.gcp.dataflow_job_id
    state    = module.gcp.dataflow_job_state
    template = module.gcp.dataflow_template_path
  }
}

output "composer_environment" {
  description = "Cloud Composer environment details"
  value = {
    name       = module.gcp.composer_name
    id         = module.gcp.composer_environment_id
    airflow_ui = module.gcp.composer_airflow_uri
    dag_gcs_prefix = module.gcp.composer_dag_gcs_prefix
  }
}

output "storage_buckets" {
  description = "Storage bucket details"
  value = {
    for name, bucket in module.gcp.buckets : name => {
      name = bucket.name
      url  = "gs://${bucket.name}"
    }
  }
}

output "service_accounts" {
  description = "Service account details"
  value = {
    dataflow = {
      email = module.gcp.dataflow_service_account_email
      name  = module.gcp.dataflow_service_account_name
    }
    composer = {
      email = module.gcp.composer_service_account_email
      name  = module.gcp.composer_service_account_name
    }
    storage = {
      email = module.gcp.storage_service_account_email
      name  = module.gcp.storage_service_account_name
    }
  }
  sensitive = true
}

# Snowflake Outputs
output "snowflake_database" {
  description = "Snowflake database details"
  value = {
    name     = module.snowflake.database_name
    schemas  = module.snowflake.schema_names
    retention_days = module.snowflake.data_retention_days
  }
}

output "snowflake_warehouses" {
  description = "Snowflake warehouse details"
  value = module.snowflake.warehouse_details
}

output "snowflake_users" {
  description = "Snowflake user details"
  value = module.snowflake.user_details
  sensitive = true
}

output "snowflake_roles" {
  description = "Snowflake role details"
  value = module.snowflake.role_details
}

output "snowflake_storage_integration" {
  description = "Snowflake storage integration details"
  value = {
    name            = module.snowflake.storage_integration_name
    allowed_locations = module.snowflake.storage_allowed_locations
  }
}

output "snowflake_network_policy" {
  description = "Snowflake network policy details"
  value = {
    name    = module.snowflake.network_policy_name
    allowed_ips = module.snowflake.allowed_ip_ranges
  }
}

# Integration Outputs
output "integration_endpoints" {
  description = "Integration endpoints"
  value = {
    pubsub_endpoint = module.gcp.pubsub_topic_id
    snowflake_url   = module.snowflake.account_url
    airflow_ui      = module.gcp.composer_airflow_uri
  }
}

output "monitoring_links" {
  description = "Monitoring dashboard links"
  value = {
    dataflow_monitoring = "https://console.cloud.google.com/dataflow/jobs/${module.gcp.region}/${module.gcp.dataflow_job_id}"
    composer_monitoring = "https://console.cloud.google.com/composer/environments/${module.gcp.region}/${module.gcp.composer_name}/monitoring"
    snowflake_usage     = "https://app.snowflake.com/${module.snowflake.account_url}/#/account/usage"
  }
}

output "secret_references" {
  description = "Secret Manager references"
  value = {
    snowflake_credentials = google_secret_manager_secret.snowflake_credentials.id
    dataflow_service_key = module.gcp.dataflow_service_account_key_id
  }
  sensitive = true
}

output "terraform_state" {
  description = "Terraform state location"
  value = {
    bucket = "tf-state-${var.project_id}"
    prefix = "trade-pipeline/${var.environment}"
  }
}

# Connection strings and URLs
output "connection_strings" {
  description = "Connection strings for various services"
  value = {
    snowflake_jdbc = "jdbc:snowflake://${module.snowflake.account_url}.snowflakecomputing.com/?db=${module.snowflake.database_name}&warehouse=${module.snowflake.warehouse_details.load.name}&role=${module.snowflake.role_details.loader.name}"
    snowflake_odbc = "Driver={Snowflake};Server=${module.snowflake.account_url}.snowflakecomputing.com;Database=${module.snowflake.database_name};Warehouse=${module.snowflake.warehouse_details.load.name}"
    pubsub_topic   = "projects/${var.project_id}/topics/${module.gcp.pubsub_topic_name}"
    bigquery_table = "${var.project_id}:TRADE_DATA.VALID_TRADES"
  }
  sensitive = true
}

# Instructions for next steps
output "setup_instructions" {
  description = "Setup instructions after Terraform apply"
  value = <<-EOT
  ============================================================================
  Trade Pipeline Infrastructure Deployment Complete!
  
  Next Steps:
  
  1. Configure Snowflake:
     - Database: ${module.snowflake.database_name}
     - Loader User: ${module.snowflake.user_details.loader.name}
     - Loader Password: Check Secret Manager
  
  2. Test Dataflow Pipeline:
     - Job: ${module.gcp.dataflow_job_name}
     - Monitoring: ${module.gcp.dataflow_monitoring_link}
  
  3. Access Airflow:
     - UI: ${module.gcp.composer_airflow_uri}
     - DAGs Location: ${module.gcp.composer_dag_gcs_prefix}
  
  4. Set up Monitoring:
     - Dataflow Dashboard: ${module.gcp.dataflow_monitoring_link}
     - Composer Dashboard: ${module.gcp.composer_monitoring_link}
  
  5. Test End-to-End:
     - Publish to Pub/Sub: ${module.gcp.pubsub_topic_id}
     - Check Snowflake Tables
  
  Important Security Notes:
  - Snowflake credentials stored in: ${google_secret_manager_secret.snowflake_credentials.id}
  - Restrict network access in production
  - Enable audit logging
  
  ============================================================================
  EOT
}
