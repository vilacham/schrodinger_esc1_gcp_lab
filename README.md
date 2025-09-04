# GCP AD CS Lab with Guacamole (ESC1 Testbed)

This Terraform project builds a repeatable, low-cost lab in Google Cloud to test Active Directory Certificate Services (AD CS) scenarios, including ESC1-style certificate template misconfigurations.

## What it creates
- VPC with two subnets:
  - Management subnet (public egress): hosts Guacamole with HTTPS exposed
  - Lab subnet (private only): hosts DC, CA, WRKST, and Ubuntu
- Cloud Router + Cloud NAT for private subnet outbound Internet
- Guacamole VM (Debian) with Dockerized guacd + guacamole and Nginx reverse proxy on 443
- Windows:
  - DC (Windows Server 2022): promotes new forest `my-lab.local`, creates users `alice` and `bob`, sets MaxPasswordAge=0
  - CA (Windows Server 2022): joins domain, installs AD CS (Enterprise Root CA), enables SANs, creates/publishes templates TestCase1–8 with specific ACEs
  - WRKST (Windows Server 2022): joins domain, adds `alice`/`bob` to local Remote Desktop Users, disables Defender
- Ubuntu 22.04: basic tooling (git, python3-pip, python3-venv), SSH enabled with password auth

Guacamole is the only Internet-exposed VM (TCP 443); everything else stays private and reaches the Internet via Cloud NAT.

## Requirements
- Terraform >= 1.6
- Google Cloud project with billing enabled
- Auth for the Google provider (one of):
  - `gcloud auth application-default login` (recommended for local usage)
  - or `GOOGLE_APPLICATION_CREDENTIALS` pointing to a service account key

## Quick start
1. Clone the repo
   ```bash
   git clone <REPO_URL>
   cd <PROJECT_DIR>
   ```
2. Authenticate (ADC) and set project for CLI (optional)
   ```bash
   gcloud auth application-default login
   gcloud auth login
   gcloud config set project YOUR_PROJECT_ID
   ```
3. Initialize and apply
   ```bash
   cd terraform
   terraform init
   terraform apply -auto-approve -var="project_id=YOUR_PROJECT_ID"
   # You can also override region/zone if needed
   # terraform apply -auto-approve \
   #   -var="project_id=YOUR_PROJECT_ID" \
   #   -var="region=us-central1" \
   #   -var="zone=us-central1-a"
   ```
4. Stop/start and destroy (lifecycle)
   ```bash
   # Stop VMs (state persists; disks still billed)
   gcloud compute instances stop dc ca wrkst ubuntu guacamole --zone us-central1-a

   # Start VMs later
   gcloud compute instances start dc ca wrkst ubuntu guacamole --zone us-central1-a

   # Get Guacamole's new ephemeral external IP (after a start)
   gcloud compute instances describe guacamole \
     --zone us-central1-a \
     --format='get(networkInterfaces[0].accessConfigs[0].natIP)'

   # Or list all VMs with IPs
   gcloud compute instances list --filter="name=guacamole" --format="table(name,zone,EXTERNAL_IP)"

   # Destroy the entire lab (removes VMs, disks, network, NAT)
   terraform destroy -auto-approve
   ```
5. After apply, Terraform prints:
   - Guacamole URL
   - Credentials (Domain Admin, Guac admin, Ubuntu SSH, alice/bob)

## Variables (key ones)
- `project_id` (required): your GCP project ID
- `region`, `zone` (defaults: `us-central1`, `us-central1-a`)
- `win_machine_type` (default: `e2-standard-2`), `linux_machine_type` (default: `e2-medium`)
- `domain_name` (default: `my-lab.local`), `domain_netbios` (default: `MYLAB`)
- IPs: `dc_ip`, `ca_ip`, `ws_ip`, `ubuntu_ip` (defaults in `10.10.10.0/24`)

## Outputs
- `guac_url` (public HTTPS endpoint)
- `credentials` (sensitive): Domain Admin, Guacamole admin, Ubuntu SSH, alice and bob
- `hosts`: hostnames, IPs, and FQDNs

## Accessing the lab
- Guacamole: open the `guac_url` output in your browser; login as `guacadmin` with the printed random password
- Create connections in Guac to:
  - RDP to WRKST / DC / CA (internal IPs from `hosts` output)
  - SSH to Ubuntu (user `ubuntu` + printed password)
- Domain credentials:
  - `MYLAB\\Administrator` with the printed random password
  - `alice` and `bob` with printed random passwords

## Behavior and order of operations
- Terraform enforces creation order: DC first, then CA and WRKST (`depends_on`).
- CA/WRKST scripts set DNS to the DC IP and wait (up to ~20 minutes) for DC readiness (DNS, dsgetdc, SYSVOL) before joining/installing.
- DC runs post-promotion config once (marker file), CA template setup runs once (marker), WRKST actions are safe to reapply on boot.

## Access and cost notes
- Guacamole is the only publicly accessible VM. Its HTTPS (443) is open to `0.0.0.0/0` for lab convenience.
- Guacamole uses an ephemeral external IP; it changes each time the VM is started. Fetch it with the gcloud command in Quick start.
- Private VMs (DC/CA/WRKST/Ubuntu) have no public IPs and reach the Internet via Cloud NAT.
- You can stop VMs to save compute costs, but disk storage persists and continues to incur charges until destroyed.

## Troubleshooting
- Check VM serial console logs (Compute Engine → VM → Logs) for startup script progress.
- On Windows, review Event Viewer and `C:\Windows\Temp` marker/task files.
- On Guacamole, `docker ps` and `docker logs` containers in `/opt/guac`.

## License
Licensed under the MIT License. See `LICENSE` for details.
