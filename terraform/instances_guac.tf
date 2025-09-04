resource "google_compute_instance" "guacamole" {
  name         = "guacamole"
  machine_type = var.linux_machine_type
  zone         = var.zone
  tags         = ["guac"]
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
    subnetwork = google_compute_subnetwork.mgmt.id
    access_config {}
  }

  # Use default Compute Engine service account

  metadata_startup_script = replace(templatefile("${path.module}/../scripts/linux/guac-setup.sh", {
    dc_ip               = var.dc_ip,
    domain_name         = var.domain_name,
    domain_netbios      = var.domain_netbios,
    guac_db_password    = random_password.guac_db_password.result,
    guac_admin_password = random_password.guac_admin_password.result,
    ubuntu_ip           = var.ubuntu_ip,
    ubuntu_password     = random_password.ubuntu_password.result,
    dc_ip_rdp           = var.dc_ip,
    ca_ip_rdp           = var.ca_ip,
    ws_ip_rdp           = var.ws_ip,
    domain_admin_password = random_password.domain_admin_password.result,
    alice_password        = random_password.alice_password.result,
    bob_password          = random_password.bob_password.result
  }), "\r\n", "\n")
}


