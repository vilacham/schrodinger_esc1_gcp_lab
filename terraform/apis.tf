resource "google_project_service" "enable_compute" {
  service = "compute.googleapis.com"
}

resource "google_project_service" "enable_serviceusage" {
  service = "serviceusage.googleapis.com"
}


