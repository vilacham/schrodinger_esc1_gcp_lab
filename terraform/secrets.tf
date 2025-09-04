resource "random_password" "guac_db_password" {
  length          = 24
  special         = true
  min_lower       = 1
  min_upper       = 1
  min_numeric     = 1
  min_special     = 1
  override_special = "!%*+=-_.@"
}

resource "random_password" "guac_admin_password" {
  length          = 20
  special         = true
  min_lower       = 1
  min_upper       = 1
  min_numeric     = 1
  min_special     = 1
  override_special = "!%*+=-_.@"
}

resource "random_password" "domain_admin_password" {
  length          = 20
  special         = true
  min_lower       = 1
  min_upper       = 1
  min_numeric     = 1
  min_special     = 1
  override_special = "!%*+=-_.@"
}

resource "random_password" "bob_password" {
  length          = 20
  special         = true
  min_lower       = 1
  min_upper       = 1
  min_numeric     = 1
  min_special     = 1
  override_special = "!%*+=-_.@"
}

resource "random_password" "alice_password" {
  length          = 20
  special         = true
  min_lower       = 1
  min_upper       = 1
  min_numeric     = 1
  min_special     = 1
  override_special = "!%*+=-_.@"
}

resource "random_password" "ubuntu_password" {
  length          = 20
  special         = true
  min_lower       = 1
  min_upper       = 1
  min_numeric     = 1
  min_special     = 1
  override_special = "!%*+=-_.@"
}

output "guacamole_admin_password" {
  value = nonsensitive(random_password.guac_admin_password.result)
}

output "guacamole_db_password" {
  value = nonsensitive(random_password.guac_db_password.result)
}

output "domain_admin_password" {
  value = nonsensitive(random_password.domain_admin_password.result)
}

output "ubuntu_password" {
  value = nonsensitive(random_password.ubuntu_password.result)
}


