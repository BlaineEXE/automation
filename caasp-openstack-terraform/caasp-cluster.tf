variable "image_name" {}
variable "internal_net" {
  description = <<EOF
The internal network on which CaaSP nodes will communicate.
On OpenStack environments where network creation is not permitted, set this to the external network
that is available.
EOF
}
variable "create_internal_net" {
  description = <<EOF
If set to 'true', Terraform will create the internal cluster network. If set to 'false', it will
look for a pre-existing network to use for internal attachments.
EOF
  default     = false
}
variable "external_net" {
  description = "Name of the external network to use."
}
variable "external_net_id" {
  description = "The ID of the external network to use. This must be the ID for the 'external_net' variable"
}
variable "get_floating_ips" {
  description = <<EOF
Set to 'true' to get floating ip addresses for nodes.
On OpenStack environments where floating ip creation is not permitted, set this to 'false'.
EOF
  default     = true
}
variable "admin_size" {}
variable "master_size" {}
variable "masters" {}
variable "worker_size" {}
variable "workers" {}
variable "dnsdomain" {}
variable "dnsentry" {
  description = "Truthy values reate DNS entries. Falsy values do not create DNS entries."
}
variable "identifier" {
  description = "Name to prefix resources to prevent user collisions in shared environments."
  default     = "test"
}
variable "additional_volume_count" {
  description = "Number of additional storage volumes to add to each node"
  default = 0
}
variable "additional_volume_size" {
  description = "Size of additional volumes in Gigabytes"
  default     = 10
}

provider "openstack" {
  insecure = "true"
}

resource "openstack_dns_zone_v2" "caasp" {
  count       = "${var.dnsentry ? 1 : 0}"
  name        = "${var.dnsdomain}."
  email       = "email@example.com"
  description = "CAASP dns zone"
  ttl         = 60
  type        = "PRIMARY"
}

resource "openstack_dns_recordset_v2" "admin" {
  count       = "${var.dnsentry ? 1 : 0}"
  zone_id     = "${openstack_dns_zone_v2.caasp.id}"
  name        = "${format("%v.%v.", "${openstack_compute_instance_v2.admin.name}", "${var.dnsdomain}")}"
  description = "admin node A recordset"
  ttl         = 5
  type        = "A"
  records     = ["${openstack_networking_floatingip_v2.admin_ext.address}"]
  depends_on  = ["openstack_compute_instance_v2.admin", "openstack_compute_floatingip_associate_v2.admin_ext_ip"]
}

resource "openstack_dns_recordset_v2" "master" {
  count       = "${var.dnsentry ? "${var.masters}" : 0}"
  zone_id     = "${openstack_dns_zone_v2.caasp.id}"
  name        = "${format("%v.%v.", "${element(openstack_compute_instance_v2.master.*.name, count.index)}", "${var.dnsdomain}")}"
  description = "master nodes A recordset"
  ttl         = 5
  type        = "A"
  records     = ["${element(openstack_networking_floatingip_v2.master_ext.*.address, count.index)}"]
  depends_on  = ["openstack_compute_instance_v2.master", "openstack_compute_floatingip_associate_v2.master_ext_ip"]
}

data "template_file" "cloud-init" {
  template = "${file("cloud-init.cls")}"

  vars {
    admin_address = "${openstack_compute_instance_v2.admin.access_ip_v4}"
  }
}

resource "openstack_compute_keypair_v2" "keypair" {
  name       = "${var.identifier}-caasp-ssh"
  public_key = "${file("../misc-files/id_shared.pub")}"
}

#
# Admin
#

resource "openstack_compute_instance_v2" "admin" {
  depends_on = ["openstack_networking_subnet_v2.caasp_int_subnet"]
  name       = "${var.identfier}-caasp-admin"
  image_name = "${var.image_name}"

  connection {
    private_key = "${file("../misc-files/id_shared")}"
  }

  flavor_name = "${var.admin_size}"
  key_pair    = "${var.identifier}-caasp-ssh"

  network {
    name = "${var.internal_net}"
  }

  security_groups = [
    "${openstack_compute_secgroup_v2.secgroup_base.name}",
    "${openstack_compute_secgroup_v2.secgroup_admin.name}",
  ]

  user_data = "${file("cloud-init.adm")}"
}

# Admin net connecctions

resource "openstack_networking_floatingip_v2" "admin_ext" {
  count = "${var.get_floating_ips ? 1 : 0}"
  pool  = "${var.external_net}"
}

resource "openstack_compute_floatingip_associate_v2" "admin_ext_ip" {
  depends_on  = ["openstack_networking_router_interface_v2.external_router_interface"]
  count       = "${var.get_floating_ips ? 1 : 0}"
  floating_ip = "${openstack_networking_floatingip_v2.admin_ext.address}"
  instance_id = "${openstack_compute_instance_v2.admin.id}"
}

#
# Masters
#

resource "openstack_compute_instance_v2" "master" {
  depends_on = ["openstack_networking_subnet_v2.caasp_int_subnet"]
  count      = "${var.masters}"
  name       = "${var.identfier}-caasp-master-${count.index}"
  image_name = "${var.image_name}"

  connection {
    private_key = "${file("../misc-files/id_shared")}"
  }

  flavor_name = "${var.master_size}"
  key_pair    = "${var.identifier}-caasp-ssh"

  network {
    name = "${var.internal_net}"
  }

  security_groups = [
    "${openstack_compute_secgroup_v2.secgroup_base.name}",
    "${openstack_compute_secgroup_v2.secgroup_master.name}",
  ]

  user_data = "${data.template_file.cloud-init.rendered}"
}

# Master net connections

resource "openstack_networking_floatingip_v2" "master_ext" {
  count = "${var.get_floating_ips ? var.masters : 0}"
  pool  = "${var.external_net}"
}

resource "openstack_compute_floatingip_associate_v2" "master_ext_ip" {
  depends_on  = ["openstack_networking_router_interface_v2.external_router_interface"]
  count       = "${var.get_floating_ips ? var.masters : 0}"
  floating_ip = "${element(openstack_networking_floatingip_v2.master_ext.*.address, count.index)}"
  instance_id = "${element(openstack_compute_instance_v2.master.*.id, count.index)}"
}

#
# Workers
#

resource "openstack_compute_instance_v2" "worker" {
  depends_on = ["openstack_networking_subnet_v2.caasp_int_subnet"]
  count      = "${var.workers}"
  name       = "${var.identfier}-caasp-worker-${count.index}"
  image_name = "${var.image_name}"

  connection {
    private_key = "${file("../misc-files/id_shared")}"
  }

  flavor_name = "${var.worker_size}"
  key_pair    = "${var.identfier}-caasp-ssh"

  network {
    name = "${var.internal_net}"
  }

  security_groups = [
    "${openstack_compute_secgroup_v2.secgroup_base.name}",
    "${openstack_compute_secgroup_v2.secgroup_worker.name}",
  ]

  user_data = "${data.template_file.cloud-init.rendered}"
}

# Worker net connections

resource "openstack_networking_floatingip_v2" "worker_ext" {
  count = "${var.get_floating_ips ? var.workers : 0}"
  pool  = "${var.external_net}"
}

resource "openstack_compute_floatingip_associate_v2" "worker_ext_ip" {
  depends_on  = ["openstack_networking_router_interface_v2.external_router_interface"]
  count       = "${var.get_floating_ips ? var.workers : 0}"
  floating_ip = "${element(openstack_networking_floatingip_v2.worker_ext.*.address, count.index)}"
  instance_id = "${element(openstack_compute_instance_v2.worker.*.id, count.index)}"
}

resource "openstack_blockstorage_volume_v2" "worker-volumes" {
  name       = "${var.identfier}-worker-volume-${ count.index / var.additional_volume_count }-${ count.index % var.additional_volume_count }"
  count      = "${ var.workers * var.additional_volume_count }"
  size       = "${var.additional_volume_size}"
}

resource "openstack_compute_volume_attach_v2" "worker-volume-attachments" {
  depends_on = ["openstack_compute_instance_v2.worker"]
  count       = "${ var.workers * var.additional_volume_count }"
  instance_id = "${element(openstack_compute_instance_v2.worker.*.id, count.index / var.additional_volume_count )}"
  volume_id   = "${element(openstack_blockstorage_volume_v2.worker-volumes.*.id, count.index)}"
}


#
# Internal network creation
#

resource "openstack_networking_network_v2" "caasp_int_net" {
  count          = "${var.create_internal_net ? 1 : 0}"
  name           = "${var.internal_net}"
  admin_state_up = "true"
}

resource "openstack_networking_subnet_v2" "caasp_int_subnet" {
  count           = "${var.create_internal_net ? 1 : 0}"
  network_id      = "${openstack_networking_network_v2.caasp_int_net.id}"
  cidr            = "172.28.0.0/24"
  ip_version      = 4
  dns_nameservers = ["172.28.0.2"]
}

resource "openstack_networking_router_v2" "external_router" {
  count               = "${var.create_internal_net ? 1 : 0}"
  name                = "${var.internal_net}-external-router"
  admin_state_up      = true
  external_network_id = "${var.external_net_id}"
}

resource "openstack_networking_router_interface_v2" "external_router_interface" {
  count     = "${var.create_internal_net ? 1 : 0}"
  router_id = "${openstack_networking_router_v2.external_router.id}"
  subnet_id = "${openstack_networking_subnet_v2.caasp_int_subnet.id}"
}

#
# Output
#

output "ip_admin_external" {
  value = "${openstack_networking_floatingip_v2.admin_ext.*.address}"
}

output "ip_admin_internal" {
  value = "${openstack_compute_instance_v2.admin.access_ip_v4}"
}

output "hostname_admin" {
  value = "${openstack_dns_recordset_v2.admin.*.name}"
}

output "hostnames_masters" {
  value = "${openstack_dns_recordset_v2.master.*.name}"
}

output "ip_masters" {
  value = ["${openstack_networking_floatingip_v2.master_ext.*.address}"]
}

output "ip_workers" {
  value = ["${openstack_networking_floatingip_v2.worker_ext.*.address}"]
}

output "ip_masters_internal" {
  value = "${openstack_compute_instance_v2.master.*.access_ip_v4}"
}

output "ip_workers_internal" {
  value = "${openstack_compute_instance_v2.worker.*.access_ip_v4}"
}
