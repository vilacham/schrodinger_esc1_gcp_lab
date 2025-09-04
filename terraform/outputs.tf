output "guac_url" {
  value = "https://${google_compute_instance.guacamole.network_interface[0].access_config[0].nat_ip}"
}

output "credentials" {
  value = {
    domain_admin = {
      username = "${var.domain_netbios}\\Administrator"
      password = nonsensitive(random_password.domain_admin_password.result)
    }
    guacamole_admin = {
      username = "guacadmin"
      password = nonsensitive(random_password.guac_admin_password.result)
    }
    guacamole_db = {
      username = "guac"
      password = nonsensitive(random_password.guac_db_password.result)
      database = "guacamole_db"
    }
    users = {
      bob = {
        username = "bob"
        password = nonsensitive(random_password.bob_password.result)
      }
      alice = {
        username = "alice"
        password = nonsensitive(random_password.alice_password.result)
      }
    }
  }
}

output "hosts" {
  value = {
    dc = {
      hostname = google_compute_instance.dc.name
      ip       = google_compute_address.dc_ip.address
      fqdn     = format("%s.%s", google_compute_instance.dc.name, var.domain_name)
    }
    ca = {
      hostname = google_compute_instance.ca.name
      ip       = google_compute_address.ca_ip.address
      fqdn     = format("%s.%s", google_compute_instance.ca.name, var.domain_name)
    }
    wrkst = {
      hostname = google_compute_instance.ws.name
      ip       = google_compute_address.ws_ip.address
      fqdn     = format("%s.%s", google_compute_instance.ws.name, var.domain_name)
    }
    ubuntu = {
      hostname = google_compute_instance.ubuntu.name
      ip       = google_compute_address.ubuntu_ip.address
    }
    guacamole = {
      public_ip = google_compute_instance.guacamole.network_interface[0].access_config[0].nat_ip
      url       = "https://${google_compute_instance.guacamole.network_interface[0].access_config[0].nat_ip}"
    }
  }
}


