resource "google_compute_address" "dc_ip" {
  name         = "dc-ip"
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.lab.id
  address      = var.dc_ip
}

resource "google_compute_address" "ca_ip" {
  name         = "ca-ip"
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.lab.id
  address      = var.ca_ip
}

resource "google_compute_address" "ws_ip" {
  name         = "wrkst-ip"
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.lab.id
  address      = var.ws_ip
}

resource "google_compute_address" "ubuntu_ip" {
  name         = "ubuntu-ip"
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.lab.id
  address      = var.ubuntu_ip
}


