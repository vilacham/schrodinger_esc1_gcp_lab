resource "google_compute_instance" "ubuntu" {
  name         = "ubuntu"
  machine_type = var.linux_machine_type
  zone         = var.zone
  depends_on   = [
    google_project_service.enable_serviceusage,
    google_project_service.enable_compute
  ]

  boot_disk {
    initialize_params {
      image = "${local.ubuntu_image_project}/${local.ubuntu_image_family}"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.lab.id
    network_ip = google_compute_address.ubuntu_ip.address
  }

  # Use default Compute Engine service account

  metadata_startup_script = templatefile("${path.module}/../scripts/linux/ubuntu-setup.sh", {
    dc_ip           = var.dc_ip,
    domain_name     = var.domain_name,
    ubuntu_password = random_password.ubuntu_password.result,
    add_hosts_entries = var.add_hosts_entries,
    ca_ip           = var.ca_ip,
    ws_ip           = var.ws_ip
  })
}


