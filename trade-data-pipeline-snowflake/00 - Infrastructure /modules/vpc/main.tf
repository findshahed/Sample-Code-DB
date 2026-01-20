# infrastructure/modules/vpc/main.tf
# VPC scripts to create VPC network, subnet, Firewall rules, Internal firewall rules, Cloud router, Cloud NAT for private instances, Private access for composers
#
#

terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.34.0"
    }
  }
}

# Create VPC network
resource "google_compute_network" "vpc" {
  name                    = "${var.network_name}-${var.environment}"
  auto_create_subnetworks = false
  routing_mode           = "REGIONAL"
  
  delete_default_routes_on_create = false
  
  mtu = 1460
  
  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }
}

# Create subnet
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.subnet_name}-${var.environment}"
  ip_cidr_range = var.subnet_cidr
  region        = var.subnet_region
  network       = google_compute_network.vpc.id
  
  private_ip_google_access = var.enable_private_ip_google_access
  
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
  
  labels = {
    environment = var.environment
    purpose     = "trade-pipeline"
  }
}

# Create firewall rules
resource "google_compute_firewall" "ingress_rules" {
  for_each = toset(var.allowed_ingress_ranges)
  
  name    = "allow-ingress-${replace(each.value, "/", "-")}-${var.environment}"
  network = google_compute_network.vpc.name
  
  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443", "8080"]
  }
  
  source_ranges = [each.value]
  
  direction = "INGRESS"
  
  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
  
  labels = {
    environment = var.environment
    rule-type   = "ingress"
  }
}

resource "google_compute_firewall" "egress_rules" {
  for_each = toset(var.allowed_egress_ranges)
  
  name    = "allow-egress-${replace(each.value, "/", "-")}-${var.environment}"
  network = google_compute_network.vpc.name
  
  allow {
    protocol = "all"
  }
  
  destination_ranges = [each.value]
  
  direction = "EGRESS"
  
  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
  
  labels = {
    environment = var.environment
    rule-type   = "egress"
  }
}

# Internal firewall rules
resource "google_compute_firewall" "internal" {
  name    = "allow-internal-${var.environment}"
  network = google_compute_network.vpc.name
  
  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }
  
  source_ranges = [var.subnet_cidr]
  
  direction = "INGRESS"
  
  labels = {
    environment = var.environment
    rule-type   = "internal"
  }
}

# Create Cloud Router
resource "google_compute_router" "router" {
  name    = "trade-router-${var.environment}"
  region  = var.region
  network = google_compute_network.vpc.id
  
  bgp {
    asn = 64514
  }
  
  labels = {
    environment = var.environment
  }
}

# Create Cloud NAT for private instances
resource "google_compute_router_nat" "nat" {
  name                               = "trade-nat-${var.environment}"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
  
  depends_on = [google_compute_subnetwork.subnet]
}

# Private Service Access for Composer
resource "google_compute_global_address" "private_service_access" {
  count = var.enable_private_service_access ? 1 : 0
  
  name          = "private-service-access-${var.environment}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
  
  labels = {
    environment = var.environment
  }
}

resource "google_service_networking_connection" "private_vpc_connection" {
  count = var.enable_private_service_access ? 1 : 0
  
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_access[0].name]
}

# VPC Peering for Cloud SQL (if needed)
resource "google_compute_network_peering" "cloudsql_peering" {
  count = var.enable_private_service_access ? 1 : 0
  
  name         = "cloudsql-peering-${var.environment}"
  network      = google_compute_network.vpc.id
  peer_network = "projects/${var.project_id}/global/networks/${google_compute_network.vpc.name}"
  
  depends_on = [google_service_networking_connection.private_vpc_connection]
}
