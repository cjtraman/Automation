terraform {
  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = "~> 2.8"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}

variable "vsphere_server" { type = string }
variable "vsphere_user" { type = string }
variable "vsphere_password" {
  type      = string
  sensitive = true
}
variable "allow_unverified_ssl" {
  type    = bool
  default = true # lab only
}
variable "datacenter" { type = string }

# Optional: names of VMs you want details for (approach 1)
variable "vm_names" {
  type    = list(string)
  default = []
}

provider "vsphere" {
  vsphere_server       = var.vsphere_server
  user                 = var.vsphere_user
  password             = var.vsphere_password
  allow_unverified_ssl = var.allow_unverified_ssl
}

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

# ---------------------------------------------------------------------------
# Approach 1: the vSphere provider has NO "list all VMs" data source.
# You can only look up VMs by name, one at a time.
# ---------------------------------------------------------------------------
data "vsphere_virtual_machine" "named" {
  for_each      = toset(var.vm_names)
  name          = each.value
  datacenter_id = data.vsphere_datacenter.dc.id
}

output "named_vm_details" {
  value = {
    for name, vm in data.vsphere_virtual_machine.named : name => {
      uuid      = vm.id
      cpus      = vm.num_cpus
      memory_mb = vm.memory
      guest_id  = vm.guest_id
      ips       = vm.default_ip_address
    }
  }
}

# ---------------------------------------------------------------------------
# Approach 2: list ALL VMs by shelling out to govc via the external data source.
# Requires govc and jq on the machine running terraform.
# ---------------------------------------------------------------------------
data "external" "all_vms" {
  program = ["bash", "-c", <<-EOT
    export GOVC_URL="https://${var.vsphere_server}/sdk"
    export GOVC_USERNAME='${var.vsphere_user}'
    export GOVC_PASSWORD='${var.vsphere_password}'
    export GOVC_INSECURE=${var.allow_unverified_ssl ? 1 : 0}
    govc find / -type m | jq -R -s -c '{vms: (split("\n") | map(select(length > 0)) | join(","))}'
  EOT
  ]
}

output "all_vm_paths" {
  value = split(",", data.external.all_vms.result.vms)
}
