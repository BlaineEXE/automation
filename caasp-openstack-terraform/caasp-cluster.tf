variable "image_name" {}
variable "internal_net" {}
variable "external_net" {}
variable "admin_size" {}
variable "master_size" {}
variable "masters" {}
variable "worker_size" {}
variable "workers" {}
variable "dnsdomain" {}
variable "dnsentry" {
  description = "Truthy values reate DNS entries. Falsy values do not create DNS entries."
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
  count = "${var.dnsentry ? 1 : 0}"
  name = "${var.dnsdomain}."
  email = "email@example.com"
  description = "CAASP dns zone"
  ttl = 60
  type = "PRIMARY"
}

resource "openstack_dns_recordset_v2" "admin" {
  count = "${var.dnsentry ? 1 : 0}"
  zone_id = "${openstack_dns_zone_v2.caasp.id}"
  name = "${format("%v.%v.", "${openstack_compute_instance_v2.admin.name}", "${var.dnsdomain}")}"
  description = "admin node A recordset"
  ttl = 5
  type = "A"
  records = ["${openstack_networking_floatingip_v2.admin_ext.address}"]
  depends_on = ["openstack_compute_instance_v2.admin", "openstack_compute_floatingip_associate_v2.admin_ext_ip"]
}

resource "openstack_dns_recordset_v2" "master" {
  count = "${var.dnsentry ? "${var.masters}" : 0}"
  zone_id = "${openstack_dns_zone_v2.caasp.id}"
  name = "${format("%v.%v.", "${element(openstack_compute_instance_v2.master.*.name, count.index)}", "${var.dnsdomain}")}"
  description = "master nodes A recordset"
  ttl = 5
  type = "A"
  records = ["${element(openstack_networking_floatingip_v2.master_ext.*.address, count.index)}"]
  depends_on = ["openstack_compute_instance_v2.master", "openstack_compute_floatingip_associate_v2.master_ext_ip"]
}

data "template_file" "cloud-init" {
  template = "${file("cloud-init.cls")}"

 vars {
    admin_address = "${openstack_compute_instance_v2.admin.access_ip_v4}"
  }
}

resource "openstack_compute_keypair_v2" "keypair" {
  name       = "caasp-ssh"
  public_key = "${file("../misc-files/id_shared.pub")}"
}

resource "openstack_compute_instance_v2" "admin" {
  name       = "caasp-admin"
  image_name = "${var.image_name}"

  connection {
    private_key = "${file("../misc-files/id_shared")}"
  }

  flavor_name = "${var.admin_size}"
  key_pair    = "caasp-ssh"

  network {
    name = "${var.internal_net}"
  }

  security_groups = [
    "${openstack_compute_secgroup_v2.secgroup_base.name}",
    "${openstack_compute_secgroup_v2.secgroup_admin.name}"
  ]

  user_data = "${file("cloud-init.adm")}"
}

resource "openstack_networking_floatingip_v2" "admin_ext" {
  pool = "${var.external_net}"
}

resource "openstack_compute_floatingip_associate_v2" "admin_ext_ip" {
  floating_ip = "${openstack_networking_floatingip_v2.admin_ext.address}"
  instance_id = "${openstack_compute_instance_v2.admin.id}"
}

resource "openstack_compute_instance_v2" "master" {
  count      = "${var.masters}"
  name       = "caasp-master${count.index}"
  image_name = "${var.image_name}"

  connection {
    private_key = "${file("../misc-files/id_shared")}"
  }

  flavor_name = "${var.master_size}"
  key_pair    = "caasp-ssh"

  network {
    name = "${var.internal_net}"
  }

  security_groups = [
    "${openstack_compute_secgroup_v2.secgroup_base.name}",
    "${openstack_compute_secgroup_v2.secgroup_master.name}"
  ]

  user_data = "${data.template_file.cloud-init.rendered}"
}

resource "openstack_networking_floatingip_v2" "master_ext" {
  count = "${var.masters}"
  pool  = "${var.external_net}"
}

resource "openstack_compute_floatingip_associate_v2" "master_ext_ip" {
  count       = "${var.masters}"
  floating_ip = "${element(openstack_networking_floatingip_v2.master_ext.*.address, count.index)}"
  instance_id = "${element(openstack_compute_instance_v2.master.*.id, count.index)}"
}

resource "openstack_compute_instance_v2" "worker" {
  count      = "${var.workers}"
  name       = "caasp-worker${count.index}"
  image_name = "${var.image_name}"

  connection {
    private_key = "${file("../misc-files/id_shared")}"
  }

  flavor_name = "${var.worker_size}"
  key_pair    = "caasp-ssh"

  network {
    name = "${var.internal_net}"
  }

  security_groups = [
    "${openstack_compute_secgroup_v2.secgroup_base.name}",
    "${openstack_compute_secgroup_v2.secgroup_worker.name}"
  ]

  user_data = "${data.template_file.cloud-init.rendered}"
}

resource "openstack_blockstorage_volume_v2" "worker-volumes" {
    depends_on = ["openstack_compute_instance_v2.worker"]
    name       = "${var.cluster_name}-worker-volume-${ count.index / var.additional_volume_count }-${ count.index % var.additional_volume_count }"
    count      = "${ var.workers * var.additional_volume_count }"
    size       = "${var.additional_volume_size}"
}

resource "openstack_compute_volume_attach_v2" "worker-volume-attachments" {
    count       = "${ var.workers * var.additional_volume_count }"
    instance_id = "${element(openstack_compute_instance_v2.worker.*.id, count.index / var.additional_volume_count )}"
    volume_id   = "${element(openstack_blockstorage_volume_v2.worker-volumes.*.id, count.index)}"
}

resource "openstack_networking_floatingip_v2" "worker_ext" {
  count = "${var.workers}"
  pool  = "${var.external_net}"
}

resource "openstack_compute_floatingip_associate_v2" "worker_ext_ip" {
  count       = "${var.workers}"
  floating_ip = "${element(openstack_networking_floatingip_v2.worker_ext.*.address, count.index)}"
  instance_id = "${element(openstack_compute_instance_v2.worker.*.id, count.index)}"
}

resource "openstack_blockstorage_volume_v2" "worker-volumes" {
  name       = "${var.cluster_name}-worker-volume-${ count.index / var.additional_volume_count }-${ count.index % var.additional_volume_count }"
  count      = "${ var.workers * var.additional_volume_count }"
  size       = "${var.additional_volume_size}"
}

resource "openstack_compute_volume_attach_v2" "worker-volume-attachments" {
  depends_on = ["openstack_compute_instance_v2.worker"]
  count       = "${ var.workers * var.additional_volume_count }"
  instance_id = "${element(openstack_compute_instance_v2.worker.*.id, count.index / var.additional_volume_count )}"
  volume_id   = "${element(openstack_blockstorage_volume_v2.worker-volumes.*.id, count.index)}"
}

output "ip_admin_external" {
  value = "${openstack_networking_floatingip_v2.admin_ext.address}"
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
