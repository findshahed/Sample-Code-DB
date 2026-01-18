# infrastructure/providers.tf
provider "google" {
  project = var.project_id
  region  = var.region
  
  # Use environment variable for credentials
  # export GOOGLE_APPLICATION_CREDENTIALS="path/to/service-account-key.json"
  
  user_project_override = true
  billing_project       = var.project_id
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  
  user_project_override = true
  billing_project       = var.project_id
}

provider "snowflake" {
  account  = var.snowflake_account
  username = var.snowflake_username
  password = var.snowflake_password
  role     = "ACCOUNTADMIN"
  region   = "us-west-2"  # Adjust based on your Snowflake region
  
  # Optional: Use OAuth instead of password
  # oauth_access_token = var.snowflake_oauth_token
}

provider "random" {
  # Random provider for generating passwords
}

provider "time" {
  # Time provider for timestamp-based resources
}

# Optional: External provider for secret generation
provider "external" {
  # Used for external data sources
}

# Optional: TLS provider for certificates
provider "tls" {
  # Used for generating RSA keys
}
