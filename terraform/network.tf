resource "google_compute_network" "lab" {
  name                    = "adcs-lab-vpc"
  auto_create_subnetworks = false
  depends_on = [
    google_project_service.enable_serviceusage,
    google_project_service.enable_compute
  ]
}

resource "google_compute_subnetwork" "mgmt" {
  name                     = "mgmt-subnet"
  ip_cidr_range            = var.mgmt_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.lab.id
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "lab" {
  name                     = "lab-subnet"
  ip_cidr_range            = var.lab_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.lab.id
  private_ip_google_access = true
}

resource "google_compute_router" "cr" {
  name    = "adcs-lab-router"
  region  = var.region
  network = google_compute_network.lab.name
}

resource "google_compute_router_nat" "nat" {
  name                               = "adcs-lab-nat"
  region                             = var.region
  router                             = google_compute_router.cr.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.lab.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal"
  network = google_compute_network.lab.name
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
  source_ranges = ["10.10.0.0/16"]
}

resource "google_compute_firewall" "allow_guac_https" {
  name    = "allow-guac-https"
  network = google_compute_network.lab.name
  direction = "INGRESS"
  priority  = 100
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["guac"]
}



