variable "project_id" { type = string }

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "win_machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "linux_machine_type" {
  type    = string
  default = "e2-medium"
}

variable "domain_name" {
  type    = string
  default = "my-lab.local"
}

variable "domain_netbios" {
  type    = string
  default = "MYLAB"
}
 
variable "lab_subnet_cidr" {
  type    = string
  default = "10.10.10.0/24"
}

variable "mgmt_subnet_cidr" {
  type    = string
  default = "10.10.0.0/24"
}

variable "dc_ip" {
  type    = string
  default = "10.10.10.10"
}

variable "ca_ip" {
  type    = string
  default = "10.10.10.20"
}

variable "ws_ip" {
  type    = string
  default = "10.10.10.50"
}

variable "ubuntu_ip" {
  type    = string
  default = "10.10.10.60"
}

variable "add_hosts_entries" {
  type    = bool
  default = true
}