resource "google_compute_instance" "dc" {
  name         = "dc"
  machine_type = var.win_machine_type
  zone         = var.zone
  depends_on   = [
    google_project_service.enable_serviceusage,
    google_project_service.enable_compute
  ]

  boot_disk {
    initialize_params {
      image = "${local.win_image_project}/${local.win_image_family}"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.lab.id
    network_ip = google_compute_address.dc_ip.address
  }

  # Use default Compute Engine service account

  metadata = {
    windows-startup-script-ps1 = templatefile("${path.module}/../scripts/win/dc-setup.ps1", {
      domain_name           = var.domain_name,
      domain_netbios        = var.domain_netbios,
      domain_admin_password = random_password.domain_admin_password.result,
      bob_password          = random_password.bob_password.result,
      alice_password        = random_password.alice_password.result
    })
  }
}

resource "google_compute_instance" "ca" {
  name         = "ca"
  machine_type = var.win_machine_type
  zone         = var.zone
  depends_on   = [google_compute_instance.dc]

  boot_disk {
    initialize_params {
      image = "${local.win_image_project}/${local.win_image_family}"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.lab.id
    network_ip = google_compute_address.ca_ip.address
  }

  # Use default Compute Engine service account

  metadata = {
    windows-startup-script-ps1 = templatefile("${path.module}/../scripts/win/ca-setup.ps1", {
      domain_name           = var.domain_name,
      domain_netbios        = var.domain_netbios,
      netbios               = var.domain_netbios,
      domain_admin_password = random_password.domain_admin_password.result,
      dc_ip                 = var.dc_ip
    })
  }
}

resource "google_compute_instance" "ws" {
  name         = "wrkst"
  machine_type = var.win_machine_type
  zone         = var.zone
  depends_on   = [google_compute_instance.dc]

  boot_disk {
    initialize_params {
      image = "${local.win_image_project}/${local.win_image_family}"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.lab.id
    network_ip = google_compute_address.ws_ip.address
  }

  # Use default Compute Engine service account

  metadata = {
    windows-startup-script-ps1 = templatefile("${path.module}/../scripts/win/ws-setup.ps1", {
      domain_name           = var.domain_name,
      domain_netbios        = var.domain_netbios,
      domain_admin_password = random_password.domain_admin_password.result,
      dc_ip                 = var.dc_ip
    })
  }
}


